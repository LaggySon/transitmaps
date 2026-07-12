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
