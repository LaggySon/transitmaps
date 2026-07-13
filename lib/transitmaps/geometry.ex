defmodule Transitmaps.Geometry do
  @moduledoc """
  Small geometry helpers for working with `[lon, lat]` coordinate lists.
  """

  @doc """
  Simplifies a polyline with the Douglas-Peucker algorithm.

  `tolerance` is expressed in degrees (0.0001 is roughly 10 m at UK
  latitudes), which is accurate enough for map display purposes.
  Implemented iteratively so pathological inputs cannot blow the stack.
  """
  def simplify(coords, _tolerance) when length(coords) <= 2, do: coords

  def simplify(coords, tolerance) do
    points = List.to_tuple(coords)
    last_index = tuple_size(points) - 1

    kept_indexes =
      keep_significant_points(points, [{0, last_index}], MapSet.new([0, last_index]), tolerance)

    kept_indexes
    |> Enum.sort()
    |> Enum.map(&elem(points, &1))
  end

  @doc """
  Splits a polyline at implausibly long jumps.

  This prevents malformed or stop-sequence fallback shapes from drawing
  cross-country connector vectors. `max_km` is the maximum direct distance
  allowed between adjacent geometry points.
  """
  def split_long_segments(coords, max_km) do
    {lines, current} =
      Enum.reduce(coords, {[], []}, fn point, {lines, current} ->
        case current do
          [] ->
            {lines, [point]}

          [previous | _] ->
            if haversine_km(previous, point) > max_km do
              {[Enum.reverse(current) | lines], [point]}
            else
              {lines, [point | current]}
            end
        end
      end)

    [Enum.reverse(current) | lines]
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.reverse()
  end

  @doc """
  Splits a polyline wherever it reverses back onto itself.

  Shapes for services that change direction mid-route (a train reversing at
  a station it calls at) double back over the track just travelled. Drawn
  as one line, the hairpin paints loops and blobs around the station; split
  at the reversal point, each leg is a clean strand and a leg that merely
  re-traces another can be dropped with `drop_redundant_lines/2`.
  """
  def split_at_reversals([first | _] = line) when length(line) >= 3 do
    scale = km_scale(first)
    projected = Enum.map(line, &project_km(&1, scale))
    points = List.to_tuple(projected)
    distances = projected |> cumulative_distances() |> List.to_tuple()

    1..(tuple_size(points) - 2)
    |> Enum.filter(&reversal_at?(points, distances, &1))
    |> suppress_nearby(distances)
    |> then(&split_line_at(line, &1))
  end

  def split_at_reversals(line), do: [line]

  # Headings are measured between anchors this far along the path on either
  # side of a vertex, so a reversal still registers when the return track sits
  # a platform's width to the side (two 90-degree corners, no 180 vertex).
  @heading_window_km 0.2

  # A reversal is a near-180-degree heading change; genuine track and road
  # corners stay well under this.
  @reversal_cosine -0.9

  defp reversal_at?(points, distances, i) do
    {ux, uy} = heading(points, distances, i, -1)
    {vx, vy} = heading(points, distances, i, +1)
    norm = :math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))

    norm > 0.0 and (ux * vx + uy * vy) / norm < @reversal_cosine
  end

  defp heading(points, distances, i, direction) do
    anchor = anchor_index(distances, i, direction, tuple_size(points))
    {xi, yi} = elem(points, i)
    {xa, ya} = elem(points, anchor)

    if direction == -1, do: {xi - xa, yi - ya}, else: {xa - xi, ya - yi}
  end

  defp anchor_index(distances, i, direction, size) do
    di = elem(distances, i)
    last = if direction == -1, do: 0, else: size - 1

    Stream.iterate(i + direction, &(&1 + direction))
    |> Enum.find(fn j -> j == last or abs(elem(distances, j) - di) >= @heading_window_km end)
  end

  # Both corners of a sidestep hairpin register; one split at the apex is
  # enough.
  defp suppress_nearby(indexes, distances) do
    indexes
    |> Enum.reduce([], fn index, accepted ->
      case accepted do
        [previous | _] when elem(distances, index) - elem(distances, previous) <
                              @heading_window_km ->
          accepted

        _ ->
          [index | accepted]
      end
    end)
    |> Enum.reverse()
  end

  defp split_line_at(line, []), do: [line]

  defp split_line_at(line, indexes) do
    boundaries = MapSet.new(indexes)

    {parts, current} =
      line
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {point, i}, {parts, current} ->
        if MapSet.member?(boundaries, i) do
          {[Enum.reverse([point | current]) | parts], [point]}
        else
          {parts, [point | current]}
        end
      end)

    Enum.reverse([Enum.reverse(current) | parts])
  end

  @doc """
  Drops lines that only re-trace other lines in the list.

  A route's service-pattern strands mostly follow the same track, differing
  by platform choice or a short terminal approach, so drawn together they
  weave a tangle around stations. Longest strands win; a line is dropped
  when its whole path stays near the kept geometry. The distance test is
  grid-approximate: within `tolerance_km` always counts as near, beyond
  about three times that never does. Genuine branches deviate by far more
  and survive.
  """
  def drop_redundant_lines(lines, _tolerance_km) when length(lines) < 2, do: lines

  def drop_redundant_lines([[reference | _] | _] = lines, tolerance_km) do
    scale = km_scale(reference)

    {kept, _cells} =
      lines
      |> Enum.sort_by(&(-line_length_km(&1, scale)))
      |> Enum.reduce({[], MapSet.new()}, fn line, {kept, cells} ->
        samples = sample_points(line, scale, tolerance_km / 2)

        if kept != [] and Enum.all?(samples, &near_covered_cell?(cells, &1, tolerance_km)) do
          {kept, cells}
        else
          {[line | kept], Enum.into(Enum.map(samples, &cell(&1, tolerance_km)), cells)}
        end
      end)

    Enum.reverse(kept)
  end

  defp km_scale([lon, lat]) when is_number(lon) and is_number(lat) do
    {111.320 * :math.cos(lat * :math.pi() / 180), 110.574}
  end

  defp project_km([lon, lat], {kx, ky}), do: {lon * kx, lat * ky}

  defp cumulative_distances([{x0, y0} | rest]) do
    {reversed, _last} =
      Enum.reduce(rest, {[0.0], {x0, y0}}, fn {x, y}, {[total | _] = acc, {px, py}} ->
        dx = x - px
        dy = y - py
        {[total + :math.sqrt(dx * dx + dy * dy) | acc], {x, y}}
      end)

    Enum.reverse(reversed)
  end

  defp line_length_km(line, scale) do
    line
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc -> acc + km_distance(a, b, scale) end)
  end

  defp km_distance([lon1, lat1], [lon2, lat2], {kx, ky}) do
    dx = (lon2 - lon1) * kx
    dy = (lat2 - lat1) * ky
    :math.sqrt(dx * dx + dy * dy)
  end

  # Points along the line every `step_km`, so straight stretches with sparse
  # vertices are still covered densely enough for the grid test.
  defp sample_points(line, scale, step_km) do
    projected = Enum.map(line, &project_km(&1, scale))

    projected
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{x1, y1} = start, {x2, y2}] ->
      dx = x2 - x1
      dy = y2 - y1
      steps = max(1, ceil(:math.sqrt(dx * dx + dy * dy) / step_km))

      [start | for(i <- 1..(steps - 1)//1, do: {x1 + dx * i / steps, y1 + dy * i / steps})]
    end)
    |> Kernel.++([List.last(projected)])
  end

  defp cell({x, y}, cell_km), do: {floor(x / cell_km), floor(y / cell_km)}

  defp near_covered_cell?(cells, point, cell_km) do
    {cx, cy} = cell(point, cell_km)

    Enum.any?(
      for(dx <- -1..1, dy <- -1..1, do: {cx + dx, cy + dy}),
      &MapSet.member?(cells, &1)
    )
  end

  defp haversine_km([lon1, lat1], [lon2, lat2]) do
    lat1 = lat1 * :math.pi() / 180
    lat2 = lat2 * :math.pi() / 180
    delta_lat = lat2 - lat1
    delta_lon = (lon2 - lon1) * :math.pi() / 180

    a =
      :math.pow(:math.sin(delta_lat / 2), 2) +
        :math.cos(lat1) * :math.cos(lat2) * :math.pow(:math.sin(delta_lon / 2), 2)

    6_371 * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  defp keep_significant_points(_points, [], kept, _tolerance), do: kept

  defp keep_significant_points(points, [{first, last} | rest], kept, tolerance) do
    case farthest_point_from_segment(points, first, last) do
      {index, distance} when distance > tolerance ->
        segments = [{first, index}, {index, last} | rest]
        keep_significant_points(points, segments, MapSet.put(kept, index), tolerance)

      _ ->
        keep_significant_points(points, rest, kept, tolerance)
    end
  end

  defp farthest_point_from_segment(_points, first, last) when last - first < 2, do: {first, 0.0}

  defp farthest_point_from_segment(points, first, last) do
    segment_start = elem(points, first)
    segment_end = elem(points, last)

    Enum.reduce((first + 1)..(last - 1), {first, 0.0}, fn index, {best_index, best_distance} ->
      distance = perpendicular_distance(elem(points, index), segment_start, segment_end)

      if distance > best_distance, do: {index, distance}, else: {best_index, best_distance}
    end)
  end

  defp perpendicular_distance([px, py], [ax, ay], [bx, by]) do
    {dx, dy} = {bx - ax, by - ay}
    segment_length_squared = dx * dx + dy * dy

    if segment_length_squared == 0.0 do
      distance([px, py], [ax, ay])
    else
      t = ((px - ax) * dx + (py - ay) * dy) / segment_length_squared
      t = min(max(t, 0.0), 1.0)
      distance([px, py], [ax + t * dx, ay + t * dy])
    end
  end

  defp distance([x1, y1], [x2, y2]) do
    :math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2))
  end
end
