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

    indexes =
      1..(tuple_size(points) - 2)
      |> Enum.filter(&reversal_at?(points, distances, &1))
      |> suppress_nearby(distances)

    case indexes do
      [] -> [line]
      _found -> line |> split_line_at(indexes) |> Enum.flat_map(&split_at_reversals/1)
    end
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
    local_reversal?(points, i) or windowed_reversal?(points, distances, i)
  end

  # A very short A-B-A spike can sit wholly inside the heading window, making
  # its wider anchors appear to carry straight on. Check the adjacent vectors
  # as well so platform-scale reversals cannot survive as pointed hooks.
  defp local_reversal?(points, i) do
    {ax, ay} = elem(points, i - 1)
    {bx, by} = elem(points, i)
    {cx, cy} = elem(points, i + 1)

    reversal_vectors?({bx - ax, by - ay}, {cx - bx, cy - by})
  end

  defp windowed_reversal?(points, distances, i) do
    incoming = heading(points, distances, i, -1)
    outgoing = heading(points, distances, i, +1)

    reversal_vectors?(incoming, outgoing)
  end

  defp reversal_vectors?({ux, uy}, {vx, vy}) do
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
        [previous | _]
        when elem(distances, index) - elem(distances, previous) <
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

  # A revisit closer than this to an earlier point closes a loop.
  @loop_proximity_km 0.06

  # Path travelled between the two visits must fall in this window: below it
  # is ordinary tight curvature, above it the "loop" is a genuine circular
  # route or city loop that should stay drawn.
  @loop_min_path_km 0.15
  @loop_max_path_km 1.2

  @doc """
  Splices out small loops where a line wanders back over itself.

  Terminal turnbacks and platform tangles in generated shapes circle the
  station area and return to a point the line already passed, painting
  loops that make no sense on a map. When the path comes back within
  `#{@loop_proximity_km}` km of an earlier point after travelling between
  `#{@loop_min_path_km}` and `#{@loop_max_path_km}` km, the detour between
  the two visits is cut out. Genuine circular routes travel far more than
  the window between revisits and are untouched.
  """
  def remove_small_loops([first | _] = line) when length(line) >= 4 do
    scale = km_scale(first)

    line
    |> Enum.reduce([], fn point, kept ->
      projected = project_km(point, scale)

      total =
        case kept do
          [] ->
            0.0

          [{_point, previous, previous_total} | _] ->
            previous_total + step_km(previous, projected)
        end

      case loop_start_index(kept, projected, total) do
        nil ->
          [{point, projected, total} | kept]

        index ->
          [{_point, anchor, anchor_total} | _] = spliced = Enum.drop(kept, index)
          [{point, projected, anchor_total + step_km(anchor, projected)} | spliced]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {point, _projected, _total} -> point end)
    |> Enum.dedup()
  end

  def remove_small_loops(line), do: line

  # Index (in the reversed kept list) of the earliest in-window earlier visit
  # the current point closes a loop with; the earliest match removes the
  # whole tangle in one splice.
  defp loop_start_index(kept, projected, total),
    do: loop_start_index(kept, projected, total, 0, nil)

  defp loop_start_index([], _projected, _total, _index, best), do: best

  defp loop_start_index([{_point, visited, visited_total} | rest], projected, total, index, best) do
    travelled = total - visited_total

    cond do
      travelled > @loop_max_path_km ->
        best

      travelled >= @loop_min_path_km and step_km(visited, projected) <= @loop_proximity_km ->
        loop_start_index(rest, projected, total, index + 1, index)

      true ->
        loop_start_index(rest, projected, total, index + 1, best)
    end
  end

  defp step_km({x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1
    :math.sqrt(dx * dx + dy * dy)
  end

  # Stitched fragments must carry straight on at the join; a genuine
  # reversal (near-180 turn) stays split.
  @stitch_cosine 0.2

  @doc """
  Joins strands that continue one another end-to-end.

  Splitting (long jumps, reversals, loops) can leave a route's geometry as
  a chain of fragments sharing endpoints. Each fragment renders with its
  own caps, so the chain reads as broken dashes instead of one line.
  Fragments whose endpoints coincide within
  `epsilon_km` and whose headings carry straight on are merged back into a
  single strand; joins that double back (genuine reversals) are left split.
  """
  def stitch_lines(lines, _epsilon_km) when length(lines) < 2, do: lines

  def stitch_lines(lines, epsilon_km) do
    case stitch_once(lines, epsilon_km) do
      nil -> lines
      stitched -> stitch_lines(stitched, epsilon_km)
    end
  end

  defp stitch_once(lines, epsilon_km) do
    indexed = Enum.with_index(lines)

    Enum.find_value(indexed, fn {a, i} ->
      Enum.find_value(indexed, fn {b, j} ->
        with true <- i < j,
             joined when is_list(joined) <- join_lines(a, b, epsilon_km) do
          rest = for {line, k} <- indexed, k != i, k != j, do: line
          [joined | rest]
        else
          _ -> nil
        end
      end)
    end)
  end

  defp join_lines([reference | _] = a, b, epsilon_km) do
    scale = km_scale(reference)

    Enum.find_value(
      [
        {a, b},
        {a, Enum.reverse(b)},
        {Enum.reverse(a), b},
        {Enum.reverse(a), Enum.reverse(b)}
      ],
      fn {left, right} -> maybe_join(left, right, scale, epsilon_km) end
    )
  end

  defp maybe_join(left, right, scale, epsilon_km) do
    if km_distance(List.last(left), hd(right), scale) <= epsilon_km and
         straight_continuation?(left, right, scale) do
      Enum.dedup(left ++ right)
    end
  end

  defp straight_continuation?(left, right, scale) do
    with [b, a | _] <- left |> Enum.dedup() |> Enum.reverse(),
         [c, d | _] <- Enum.dedup(right) do
      {ux, uy} = km_vector(a, b, scale)
      {vx, vy} = km_vector(c, d, scale)
      norm = :math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))

      norm > 0.0 and (ux * vx + uy * vy) / norm > @stitch_cosine
    else
      _ -> false
    end
  end

  defp km_vector([lon1, lat1], [lon2, lat2], {kx, ky}) do
    {(lon2 - lon1) * kx, (lat2 - lat1) * ky}
  end

  @doc """
  Grid cells of size `cell_km` that `line` passes through, given a `scale`
  from `km_scale/1`. A coarse corridor fingerprint: two lines sharing a
  stretch of track share a run of cells.
  """
  def covered_cells(line, scale, cell_km) when length(line) >= 2 do
    line
    |> sample_points(scale, cell_km / 2)
    |> MapSet.new(&cell(&1, cell_km))
  end

  def covered_cells(_line, _scale, _cell_km), do: MapSet.new()

  @doc """
  Drops short strands that merely shadow longer kept lines.

  After reversal-splitting and dedupe a route can still hold little
  platform-detour slivers: a few hundred metres that pull out of the shared
  corridor at a station and rejoin it, rendering as stray arcs floating
  beside the line. A strand no longer than `max_len_km` is dropped when the
  whole of it stays within roughly `tolerance_km` of the route's longer
  strands. Genuine short branches head away from the corridor and survive.
  """
  def drop_short_shadows(lines, _max_len_km, _tolerance_km) when length(lines) < 2, do: lines

  def drop_short_shadows([[reference | _] | _] = lines, max_len_km, tolerance_km) do
    scale = km_scale(reference)
    {long, short} = Enum.split_with(lines, &(line_length_km(&1, scale) > max_len_km))

    if long == [] or short == [] do
      lines
    else
      cells =
        long
        |> Enum.flat_map(&sample_points(&1, scale, tolerance_km / 2))
        |> MapSet.new(&cell(&1, tolerance_km))

      shadowed =
        short
        |> Enum.filter(fn line ->
          line
          |> sample_points(scale, tolerance_km / 2)
          |> Enum.all?(&near_covered_cell?(cells, &1, tolerance_km))
        end)
        |> MapSet.new()

      Enum.reject(lines, &MapSet.member?(shadowed, &1))
    end
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
      |> Enum.uniq()
      |> Enum.sort_by(&(-line_length_km(&1, scale)))
      |> Enum.reduce({[], MapSet.new()}, fn line, {kept, cells} ->
        samples = sample_points(line, scale, tolerance_km)

        if kept != [] and Enum.all?(samples, &near_covered_cell?(cells, &1, tolerance_km)) do
          {kept, cells}
        else
          {[line | kept], Enum.into(Enum.map(samples, &cell(&1, tolerance_km)), cells)}
        end
      end)

    Enum.reverse(kept)
  end

  @doc """
  Extracts the unique track sections from overlapping service paths.

  GTFS routes describe services, not a physical network. Several services
  can share a trunk before taking different branches, so dropping only whole
  duplicate lines still paints the shared trunk once per service pattern.
  Longest paths establish the network first; later paths contribute only the
  sections farther than `tolerance_km` from track already kept.

  A fixed-size coverage grid makes the pass linear in the number of shape
  samples. Coverage requires both proximity and an aligned local heading, so
  crossing tracks cannot be mistaken for a shared corridor. Section endpoints
  snap to retained track, making a real branch meet its trunk cleanly instead
  of leaving a platform-sized gap or drawing a short duplicate approach.
  """
  def extract_network_lines(lines, _tolerance_km) when length(lines) < 2, do: lines

  def extract_network_lines([[reference | _] | _] = lines, tolerance_km) do
    scale = km_scale(reference)

    {kept, _coverage} =
      lines
      |> Enum.uniq()
      |> Enum.sort_by(&(-line_length_km(&1, scale)))
      |> Enum.reduce({[], %{}}, fn line, {kept, coverage} ->
        samples = sample_line(line, scale, tolerance_km)

        sections =
          if map_size(coverage) == 0 do
            [line]
          else
            annotated =
              Enum.map(samples, fn {point, projected, heading} ->
                {point, nearest_covered_point(coverage, projected, heading, tolerance_km)}
              end)

            if Enum.all?(annotated, fn {_point, covered_point} -> is_nil(covered_point) end) do
              [line]
            else
              novel_sections(annotated)
            end
          end

        {
          Enum.reverse(sections, kept),
          add_coverage(coverage, samples, tolerance_km)
        }
      end)

    Enum.reverse(kept)
  end

  defp novel_sections(samples) do
    {sections, current, before_anchor} =
      Enum.reduce(samples, {[], [], nil}, fn
        {_point, covered_point}, {sections, [], _before_anchor}
        when not is_nil(covered_point) ->
          {sections, [], covered_point}

        {_point, covered_point}, {sections, current, before_anchor}
        when not is_nil(covered_point) ->
          {finish_section(sections, current, before_anchor, covered_point), [], covered_point}

        {point, nil}, {sections, current, before_anchor} ->
          {sections, [point | current], before_anchor}
      end)

    sections
    |> finish_section(current, before_anchor, nil)
    |> Enum.reverse()
  end

  defp finish_section(sections, [], _before_anchor, _after_anchor), do: sections

  defp finish_section(sections, reversed_points, before_anchor, after_anchor) do
    section =
      [before_anchor | Enum.reverse(reversed_points)]
      |> Kernel.++([after_anchor])
      |> Enum.reject(&is_nil/1)
      |> Enum.dedup()

    if length(section) >= 2, do: [section | sections], else: sections
  end

  defp add_coverage(coverage, samples, cell_km) do
    Enum.reduce(samples, coverage, fn {point, projected, heading}, index ->
      key = cell(projected, cell_km)
      bucket = heading_bucket(heading)
      candidate = {projected, point, heading}

      Map.update(index, key, %{bucket => candidate}, &Map.put_new(&1, bucket, candidate))
    end)
  end

  # Nearby crossing tracks are not shared track. Requiring their undirected
  # headings to agree within about 40 degrees prevents a service branch from
  # being truncated and snapped onto the wrong line at an overpass or station
  # throat.
  @coverage_direction_cosine 0.75

  defp nearest_covered_point(coverage, {x, y} = point, heading, cell_km) do
    {cx, cy} = cell(point, cell_km)
    max_distance_squared = cell_km * cell_km

    for(
      dx <- -1..1,
      dy <- -1..1,
      candidate <- coverage |> Map.get({cx + dx, cy + dy}, %{}) |> Map.values(),
      do: candidate
    )
    |> Enum.filter(fn {{candidate_x, candidate_y}, _coordinate, candidate_heading} ->
      squared_distance =
        (candidate_x - x) * (candidate_x - x) + (candidate_y - y) * (candidate_y - y)

      squared_distance <= max_distance_squared and
        headings_aligned?(heading, candidate_heading)
    end)
    |> Enum.min_by(
      fn {{candidate_x, candidate_y}, _coordinate, _candidate_heading} ->
        (candidate_x - x) * (candidate_x - x) + (candidate_y - y) * (candidate_y - y)
      end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {_projected, coordinate, _candidate_heading} -> coordinate
    end
  end

  defp headings_aligned?({ux, uy}, {vx, vy}) do
    norm = :math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
    norm > 0.0 and abs((ux * vx + uy * vy) / norm) >= @coverage_direction_cosine
  end

  # Direction is undirected for shared-track detection, so eastbound and
  # westbound samples land in the same 15-degree bucket.
  defp heading_bucket({dx, dy}) do
    angle = :math.atan2(dy, dx)
    angle = if angle < 0, do: angle + :math.pi(), else: angle
    angle = if angle >= :math.pi(), do: angle - :math.pi(), else: angle
    min(11, floor(angle / (:math.pi() / 12)))
  end

  @doc """
  Extends branch endpoints a short distance along the trunk they meet.

  Network extraction deliberately keeps a branch only from the point where
  it leaves already-covered track. That endpoint is topologically correct,
  but without an approach vector a later corner pass can only draw a hard Y
  or right-angle join. When an endpoint lies on the interior of another
  strand, this function carries it along the best-aligned side of that trunk
  for up to `radius_km`. The overlap is invisible because both strands belong
  to the same rendered line, while the now-interior junction can be rounded.
  """
  def extend_junctions(lines, _radius_km, _epsilon_km) when length(lines) < 2, do: lines

  def extend_junctions([[reference | _] | _] = lines, radius_km, epsilon_km) do
    scale = km_scale(reference)
    indexed = Enum.with_index(lines)
    junction_index = build_junction_index(indexed, epsilon_km, scale)

    Enum.map(indexed, fn {line, owner_index} ->
      start_anchor = line |> clip_extension(radius_km, scale) |> List.last()
      end_anchor = line |> Enum.reverse() |> clip_extension(radius_km, scale) |> List.last()

      start_extension =
        junction_extension(
          junction_index,
          owner_index,
          hd(line),
          start_anchor,
          :start,
          radius_km,
          epsilon_km,
          scale
        )

      end_extension =
        junction_extension(
          junction_index,
          owner_index,
          List.last(line),
          end_anchor,
          :end,
          radius_km,
          epsilon_km,
          scale
        )

      prefix = if start_extension, do: start_extension |> tl() |> Enum.reverse(), else: []
      suffix = if end_extension, do: tl(end_extension), else: []

      Enum.dedup(prefix ++ line ++ suffix)
    end)
  end

  defp build_junction_index(indexed, cell_km, scale) do
    Enum.reduce(indexed, %{}, fn {line, owner_index}, index ->
      line
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.drop(-1)
      |> Enum.reduce(index, fn {point, point_index}, current ->
        key = point |> project_km(scale) |> cell(cell_km)
        candidate = {owner_index, line, point_index, point}
        Map.update(current, key, [candidate], &[candidate | &1])
      end)
    end)
  end

  defp junction_extension(
         junction_index,
         owner_index,
         junction,
         adjacent,
         side,
         radius_km,
         epsilon_km,
         scale
       ) do
    {cx, cy} = junction |> project_km(scale) |> cell(epsilon_km)

    for(
      dx <- -1..1,
      dy <- -1..1,
      candidate <- Map.get(junction_index, {cx + dx, cy + dy}, []),
      do: candidate
    )
    |> Enum.sort_by(fn {candidate_owner, _line, point_index, _point} ->
      {candidate_owner, point_index}
    end)
    |> Enum.flat_map(fn {candidate_owner, other, point_index, point} ->
      if candidate_owner != owner_index and
           km_distance(junction, point, scale) <= epsilon_km do
        before = other |> Enum.take(point_index + 1) |> Enum.reverse()
        following = Enum.drop(other, point_index)

        [
          extension_candidate([junction | tl(before)], radius_km, scale),
          extension_candidate([junction | tl(following)], radius_km, scale)
        ]
      else
        []
      end
    end)
    |> Enum.filter(fn {extension, _available_points} -> length(extension) >= 2 end)
    |> choose_junction_extension(side, adjacent, scale)
  end

  @junction_straight_turn :math.pi() / 3
  @junction_max_turn 2 * :math.pi() / 3

  defp extension_candidate(path, radius_km, scale) do
    {clip_extension(path, radius_km, scale), length(path)}
  end

  defp choose_junction_extension([], _side, _adjacent, _scale), do: nil

  defp choose_junction_extension(candidates, side, adjacent, scale) do
    scored =
      Enum.map(candidates, fn {[junction | _] = extension, available_points} ->
        extension_anchor = List.last(extension)

        turn =
          case side do
            :start -> turn_angle(extension_anchor, junction, adjacent, scale)
            :end -> turn_angle(adjacent, junction, extension_anchor, scale)
          end

        {extension, available_points, turn}
      end)

    viable =
      Enum.filter(scored, fn {_extension, _available_points, turn} ->
        turn <= @junction_max_turn
      end)

    straight =
      Enum.filter(viable, fn {_extension, _available_points, turn} ->
        turn <= @junction_straight_turn
      end)

    chosen =
      cond do
        straight != [] ->
          Enum.min_by(straight, fn {_extension, _available_points, turn} -> turn end)

        viable != [] ->
          # A hard join in an already-cleaned preview snapshot may be a legacy
          # false snap. Following the longer side of the trunk usually restores
          # the lost through-route; fresh raw imports use the direction-aware
          # extractor above and normally take the straight-path branch instead.
          Enum.max_by(viable, fn {_extension, available_points, turn} ->
            {available_points, -turn}
          end)

        true ->
          nil
      end

    case chosen do
      {extension, _available_points, _turn} -> extension
      nil -> nil
    end
  end

  defp clip_extension([junction | rest], radius_km, scale) do
    {reversed, _distance, _previous} =
      Enum.reduce_while(rest, {[junction], 0.0, junction}, fn point, {kept, distance, previous} ->
        step = km_distance(previous, point, scale)

        cond do
          step == 0.0 ->
            {:cont, {kept, distance, point}}

          distance + step <= radius_km ->
            {:cont, {[point | kept], distance + step, point}}

          true ->
            amount = (radius_km - distance) / step
            clipped = interpolate(previous, point, amount)
            {:halt, {[clipped | kept], radius_km, clipped}}
        end
      end)

    Enum.reverse(reversed)
  end

  defp turn_angle(previous, corner, next, scale) do
    {ux, uy} = km_vector(previous, corner, scale)
    {vx, vy} = km_vector(corner, next, scale)
    norm = :math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))

    if norm == 0.0, do: :math.pi(), else: :math.acos(clamp((ux * vx + uy * vy) / norm))
  end

  # Corners gentler than this are already smooth; sharper than the reversal
  # threshold is a hairpin for `split_at_reversals/1`, not a corner. Keep a
  # narrow safety band for malformed near-reversals that the splitter cannot
  # resolve, but round every ordinary bend below it.
  @corner_min_turn 0.12
  @corner_reversal_cosine -0.985

  # Arc sampling: no vertex in the output turns more than this, so a rendered
  # route follows a clean curve instead of pinching through one sharp vertex.
  @corner_step 0.15

  @doc """
  Rounds interior corners into short arcs.

  A corner held in a single vertex forces the renderer through one sharp
  join. Each corner turning more than about 7
  degrees is replaced by a quadratic arc with `radius_km`-scaled tangent
  approaches (capped well under half of each adjacent segment so neighbouring
  corners never overlap), sampled finely enough to render as a clean arc.
  Near-reversals are left alone for `split_at_reversals/1`.
  """
  def round_corners(line, radius_km)

  def round_corners([first | _] = line, radius_km) when length(line) >= 3 do
    scale = km_scale(first)

    middle =
      line
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.flat_map(fn [previous, corner, next] ->
        rounded_corner(previous, corner, next, radius_km, scale)
      end)

    Enum.dedup([hd(line) | middle] ++ [List.last(line)])
  end

  def round_corners(line, _radius_km), do: line

  defp rounded_corner(previous, corner, next, radius_km, scale) do
    {ux, uy} = km_vector(previous, corner, scale)
    {vx, vy} = km_vector(corner, next, scale)
    incoming = :math.sqrt(ux * ux + uy * uy)
    outgoing = :math.sqrt(vx * vx + vy * vy)

    if incoming == 0.0 or outgoing == 0.0 do
      [corner]
    else
      cosine = clamp((ux * vx + uy * vy) / (incoming * outgoing))
      turn = :math.acos(cosine)

      if turn < @corner_min_turn or cosine < @corner_reversal_cosine do
        [corner]
      else
        # A fixed cut makes sharp bends look much tighter than gentle ones.
        # Scaling by tan(turn / 2) is the tangent length of a circular fillet,
        # giving a 120-degree turn the broad approach it needs without moving
        # a shallow bend unnecessarily.
        tangent = radius_km * :math.tan(turn / 2)
        cut = Enum.min([tangent, incoming * 0.45, outgoing * 0.45])
        entry = interpolate(corner, previous, cut / incoming)
        exit = interpolate(corner, next, cut / outgoing)
        steps = max(2, ceil(turn / @corner_step))

        for step <- 0..steps do
          bezier(entry, corner, exit, step / steps)
        end
      end
    end
  end

  defp clamp(value), do: min(1.0, max(-1.0, value))

  defp interpolate([x1, y1], [x2, y2], amount) do
    [x1 + (x2 - x1) * amount, y1 + (y2 - y1) * amount]
  end

  defp bezier([ex, ey], [cx, cy], [xx, xy], t) do
    r = 1.0 - t
    [r * r * ex + 2 * r * t * cx + t * t * xx, r * r * ey + 2 * r * t * cy + t * t * xy]
  end

  @doc "Kilometres per degree of longitude/latitude around a reference point."
  def km_scale([lon, lat]) when is_number(lon) and is_number(lat) do
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

  # Densifies a line while retaining its geographic coordinates and local
  # heading. Original vertices stay in the result, so extracting unique
  # sections does not coarsen curves from the source shape.
  defp sample_line(line, scale, step_km) do
    samples =
      line
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [[lon1, lat1], [lon2, lat2]] ->
        {x1, y1} = project_km([lon1, lat1], scale)
        {x2, y2} = project_km([lon2, lat2], scale)
        dx = x2 - x1
        dy = y2 - y1
        steps = max(1, ceil(:math.sqrt(dx * dx + dy * dy) / step_km))

        for i <- 0..(steps - 1) do
          amount = i / steps
          coordinate = [lon1 + (lon2 - lon1) * amount, lat1 + (lat2 - lat1) * amount]
          {coordinate, {x1 + dx * amount, y1 + dy * amount}}
        end
      end)
      |> Kernel.++([{List.last(line), project_km(List.last(line), scale)}])

    points = List.to_tuple(samples)
    last_index = tuple_size(points) - 1

    0..last_index
    |> Enum.map(fn index ->
      {coordinate, projected} = elem(points, index)
      {_previous_coordinate, {previous_x, previous_y}} = elem(points, max(0, index - 1))
      {_next_coordinate, {next_x, next_y}} = elem(points, min(last_index, index + 1))
      {coordinate, projected, {next_x - previous_x, next_y - previous_y}}
    end)
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
