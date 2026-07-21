defmodule Transitmaps.Display.Bundles do
  @moduledoc """
  Places corridor-sharing lines side by side by offsetting their geometry.

  Where several lines run along the same track they must render as a
  bundle of adjacent parallel lines — never overlapping — the way Apple
  Maps and OpenRailwayMap draw shared corridors. The bundle is packed
  *locally*: at every point along a line, only the lines actually present
  on that stretch of corridor occupy slots, centred on the corridor. When
  a line leaves mid-bundle the remaining lines collapse smoothly into the
  space it vacated instead of leaving a gap, and a line joining fans the
  bundle open. Offsets are baked into the served geometry, so the client
  draws plain lines and no renderer offset math can distort the result.

  How it works:

    1. Every strand is densified (so ramps and curves stay smooth) and
       fingerprinted into ~#{trunc(1000 * 0.4)} m cells with a travel
       direction per cell.
    2. Strands sharing a run of cells are oriented the same way along the
       corridor (flipping whole strands where needed), giving every
       corridor a consistent left and right.
    3. At each vertex, the lines present in that cell *running the same
       way* (crossings don't count) form the local bundle; members are
       ordered by their stable line rank and packed symmetrically around
       the bundle's mean centreline — not each line's own — so source
       shapes lying a track's width apart still come out evenly spaced.
    4. The resulting per-vertex slot and centreline correction are
       smoothed along the line so membership changes become gradual
       tapers, then each vertex is pushed sideways along its
       (miter-clamped) normal by slot × #{trunc(1000 * 0.03)} m plus the
       correction.
  """

  alias Transitmaps.Geometry

  # Corridor fingerprint cells. Coarse enough that parallel tracks a
  # platform's width apart land together, fine enough that nearby separate
  # corridors stay distinct.
  @cell_km 0.4

  # Strands must share about this many cells before direction alignment
  # couples them, so crossings and station throats don't flip strands.
  @min_shared_cells 4

  # Lines only bundle where they run the same way; a line crossing (or an
  # alignment conflict running opposite) keeps its own centreline.
  @parallel_cosine 0.7

  # Ground distance between neighbouring lines of a bundle. Bundles merge
  # into one ribbon at country zooms and open into adjacent parallel lines
  # as the map approaches street level.
  @slot_spacing_km 0.03

  # Vertices are capped this far apart before slotting, so slot tapers and
  # curved corridors bend smoothly instead of in long straight jumps.
  @densify_km 0.15

  # Slot values are averaged over this much path either side of a vertex:
  # membership changes taper over roughly a kilometre of line.
  @smooth_km 0.45

  # Offset points may sit at most this factor beyond the nominal distance
  # at a corner, which keeps bundles tight through bends that corner
  # rounding left slightly angular.
  @miter_limit 1.6

  # Offset strands are re-simplified before serving (~4 m tolerance):
  # densification is needed for smooth ramps but straight runs collapse
  # back to sparse vertices, keeping payloads close to the input size.
  @output_tolerance 0.00004

  # Cap on the shared-axis correction, so one badly georeferenced shape
  # cannot drag its bundle sideways off the track.
  @max_correction_km 0.06

  @doc """
  Returns `lines` with corridor-sharing geometry offset into bundles.
  Line order, count, and every non-geometry field are preserved; output
  is stable for identical input.
  """
  def arrange(lines) do
    strands =
      for {line, line_index} <- Enum.with_index(lines),
          {strand, strand_index} <- Enum.with_index(strand_list(line.geometry)),
          match?([_, _ | _], strand) do
        {{line_index, strand_index}, strand}
      end

    case strands do
      [] ->
        lines

      [{_id, [reference | _]} | _] ->
        scale = Geometry.km_scale(reference)

        projected =
          Map.new(strands, fn {id, strand} ->
            {id, densify(Enum.map(strand, &project(&1, scale)))}
          end)

        fingerprints = Map.new(projected, fn {id, points} -> {id, fingerprint(points)} end)
        flipped = flips(Map.keys(projected), fingerprints)

        aligned =
          Map.new(projected, fn {id, points} ->
            {id, if(MapSet.member?(flipped, id), do: Enum.reverse(points), else: points)}
          end)

        line_data = line_cell_data(aligned)
        occupancy = cell_occupancy(line_data)

        offset_strands =
          Map.new(aligned, fn {{line_index, _strand_index} = id, points} ->
            {id, offset_strand(points, line_index, line_data, occupancy)}
          end)

        rebuild(lines, offset_strands, scale)
    end
  end

  # -- projection & densification ---------------------------------------------

  defp project([lon, lat], {kx, ky}), do: {lon * kx, lat * ky}

  defp unproject({x, y}, {kx, ky}), do: [x / kx, y / ky]

  defp densify([first | rest]) do
    rest
    |> Enum.reduce([first], fn point, [previous | _] = acc ->
      distance = distance(previous, point)
      steps = max(1, ceil(distance / @densify_km))

      Enum.reduce(1..steps, acc, fn step, inner ->
        [interpolate(previous, point, step / steps) | inner]
      end)
    end)
    |> Enum.reverse()
  end

  defp interpolate({x1, y1}, {x2, y2}, t), do: {x1 + (x2 - x1) * t, y1 + (y2 - y1) * t}

  defp distance({x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1
    :math.sqrt(dx * dx + dy * dy)
  end

  # -- corridor fingerprints ---------------------------------------------------

  # Cell -> {summed unit travel direction, summed position, sample count}
  # for one strand. Directions align and detect crossings; positions give
  # each cell a mean centreline so bundles can share one axis.
  defp fingerprint(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn [a, b], cells ->
      length = distance(a, b)

      if length == 0.0 do
        cells
      else
        {ax, ay} = a
        {bx, by} = b
        direction = {(bx - ax) / length, (by - ay) / length}

        cells
        |> add_sample(cell(a), direction, a)
        |> add_sample(cell(b), direction, b)
      end
    end)
  end

  defp cell({x, y}), do: {floor(x / @cell_km), floor(y / @cell_km)}

  defp add_sample(cells, cell, {dx, dy}, {px, py}) do
    Map.update(cells, cell, {{dx, dy}, {px, py}, 1}, fn {{sx, sy}, {qx, qy}, count} ->
      {{sx + dx, sy + dy}, {qx + px, qy + py}, count + 1}
    end)
  end

  defp sample_direction({direction, _position, _count}), do: direction

  defp sample_mean({_direction, {qx, qy}, count}), do: {qx / count, qy / count}

  defp dot({ax, ay}, {bx, by}), do: ax * bx + ay * by

  defp normalize({x, y}) do
    length = :math.sqrt(x * x + y * y)
    if length == 0.0, do: nil, else: {x / length, y / length}
  end

  # -- direction alignment -----------------------------------------------------

  # Pairwise alignment scores between strands sharing enough cells, then a
  # greedy pass in stable order: the first strand of each corridor
  # component keeps its direction and later strands flip when their summed
  # agreement with already-oriented neighbours is negative.
  defp flips(ids, fingerprints) do
    neighbours =
      ids
      |> pair_scores(fingerprints)
      |> Enum.reduce(%{}, fn {{a, b}, {shared, score}}, acc ->
        if shared >= @min_shared_cells and score != 0.0 do
          acc
          |> Map.update(a, [{b, score}], &[{b, score} | &1])
          |> Map.update(b, [{a, score}], &[{a, score} | &1])
        else
          acc
        end
      end)

    ids
    |> Enum.sort()
    |> Enum.reduce(%{}, fn id, orientation ->
      agreement =
        neighbours
        |> Map.get(id, [])
        |> Enum.reduce(0.0, fn {neighbour, score}, sum ->
          sum + score * Map.get(orientation, neighbour, 0)
        end)

      Map.put(orientation, id, if(agreement < 0.0, do: -1, else: 1))
    end)
    |> Enum.filter(fn {_id, orient} -> orient == -1 end)
    |> MapSet.new(fn {id, _orient} -> id end)
  end

  defp pair_scores(ids, fingerprints) do
    ids
    |> Enum.reduce(%{}, fn id, cell_index ->
      fingerprints[id]
      |> Map.keys()
      |> Enum.reduce(cell_index, fn cell, acc -> Map.update(acc, cell, [id], &[id | &1]) end)
    end)
    |> Enum.reduce(%{}, fn {cell, cell_ids}, scores ->
      for a <- cell_ids, b <- cell_ids, a < b, reduce: scores do
        acc ->
          contribution =
            dot(sample_direction(fingerprints[a][cell]), sample_direction(fingerprints[b][cell]))

          Map.update(acc, {a, b}, {1, contribution}, fn {shared, score} ->
            {shared + 1, score + contribution}
          end)
      end
    end)
  end

  # -- local bundle membership -------------------------------------------------

  # line_index -> cell -> merged fingerprint across the line's aligned strands.
  defp line_cell_data(aligned) do
    Enum.reduce(aligned, %{}, fn {{line_index, _strand_index}, points}, acc ->
      Map.update(acc, line_index, fingerprint(points), fn existing ->
        Map.merge(existing, fingerprint(points), fn _cell,
                                                    {{ax, ay}, {apx, apy}, an},
                                                    {{bx, by}, {bpx, bpy}, bn} ->
          {{ax + bx, ay + by}, {apx + bpx, apy + bpy}, an + bn}
        end)
      end)
    end)
  end

  # cell -> [{line_index, unit direction, mean position}] for bundle lookups.
  defp cell_occupancy(line_data) do
    Enum.reduce(line_data, %{}, fn {line_index, cells}, acc ->
      Enum.reduce(cells, acc, fn {cell, sample}, inner ->
        case normalize(sample_direction(sample)) do
          nil ->
            inner

          direction ->
            entry = {line_index, direction, sample_mean(sample)}
            Map.update(inner, cell, [entry], &[entry | &1])
        end
      end)
    end)
  end

  # -- slotting & offsetting ---------------------------------------------------

  defp offset_strand(points, line_index, line_data, occupancy) do
    normals = vertex_normals(points)
    {raw_slots, raw_corrections} = raw_placement(points, normals, line_index, line_data, occupancy)
    slots = smooth_values(points, raw_slots)
    corrections = smooth_values(points, raw_corrections)
    offset_points(points, slots, corrections, normals)
  end

  # At each vertex: the lines running the same way through this cell,
  # ordered by rank, packed symmetrically around the bundle's mean
  # centreline. A line always finds itself, so an isolated line sits in
  # slot 0 with no correction — the overlapping-centreline baseline.
  defp raw_placement(points, normals, line_index, line_data, occupancy) do
    [points, normals]
    |> Enum.zip_with(fn [point, normal] ->
      cell = cell(point)
      sample = Map.get(line_data[line_index], cell)

      case sample && normalize(sample_direction(sample)) do
        nil ->
          {0.0, 0.0}

        own_direction ->
          members =
            occupancy
            |> Map.get(cell, [])
            |> Enum.filter(fn {_other, direction, _mean} ->
              dot(own_direction, direction) >= @parallel_cosine
            end)
            |> Enum.sort_by(fn {other, _direction, _mean} -> other end)
            |> Enum.uniq_by(fn {other, _direction, _mean} -> other end)

          case Enum.find_index(members, fn {other, _direction, _mean} -> other == line_index end) do
            nil ->
              {0.0, 0.0}

            index ->
              slot = index - (length(members) - 1) / 2
              {slot, correction(members, sample_mean(sample), normal)}
          end
      end
    end)
    |> Enum.unzip()
  end

  # Lateral distance from this line's local centreline to the bundle's
  # mean centreline: added to the slot offset it packs members onto one
  # shared axis even when their source shapes lie a track's width apart.
  defp correction([_only], _own_mean, _normal), do: 0.0

  defp correction(members, {ox, oy}, normal) do
    count = length(members)

    {sx, sy} =
      Enum.reduce(members, {0.0, 0.0}, fn {_other, _direction, {mx, my}}, {ax, ay} ->
        {ax + mx, ay + my}
      end)

    lateral = dot({sx / count - ox, sy / count - oy}, normal)
    lateral |> min(@max_correction_km) |> max(-@max_correction_km)
  end

  # Distance-weighted moving average: membership changes become tapers
  # instead of sideways jumps, and cell-boundary noise averages away.
  defp smooth_values(points, raw) do
    distances = cumulative_distances(points)
    slots = List.to_tuple(raw)
    positions = List.to_tuple(distances)
    count = tuple_size(slots)

    for index <- 0..(count - 1) do
      position = elem(positions, index)
      window_average(slots, positions, count, index, position)
    end
  end

  defp window_average(slots, positions, count, index, position) do
    {sum, total} =
      accumulate(slots, positions, count, index, position, -1, accumulate(slots, positions, count, index, position, 1, {elem(slots, index), 1}))

    sum / total
  end

  defp accumulate(slots, positions, count, index, position, step, acc) do
    next = index + step

    if next < 0 or next >= count or abs(elem(positions, next) - position) > @smooth_km do
      acc
    else
      {sum, total} = acc
      accumulate(slots, positions, count, next, position, step, {sum + elem(slots, next), total + 1})
    end
  end

  defp cumulative_distances([first | rest]) do
    {reversed, _last, _total} =
      Enum.reduce(rest, {[0.0], first, 0.0}, fn point, {acc, previous, total} ->
        next_total = total + distance(previous, point)
        {[next_total | acc], point, next_total}
      end)

    Enum.reverse(reversed)
  end

  # Push each vertex sideways along its miter-clamped normal. Positive
  # slots go to the left of travel; alignment made "left" consistent for
  # the whole corridor.
  defp offset_points(points, slots, corrections, normals) do
    Enum.zip_with([points, slots, corrections, normals], fn [{x, y}, slot, correction, {nx, ny}] ->
      distance = slot * @slot_spacing_km + correction
      {x + nx * distance, y + ny * distance}
    end)
  end

  defp vertex_normals(points) do
    segment_normals =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        case normalize({elem(b, 0) - elem(a, 0), elem(b, 1) - elem(a, 1)}) do
          nil -> {0.0, 0.0}
          {dx, dy} -> {-dy, dx}
        end
      end)

    first = List.first(segment_normals) || {0.0, 0.0}
    last = List.last(segment_normals) || {0.0, 0.0}

    interior =
      segment_normals
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [before, after_] -> joint_normal(before, after_) end)

    [first | interior] ++ [last]
  end

  defp joint_normal({ax, ay} = before, after_) do
    {bx, by} = after_

    case normalize({ax + bx, ay + by}) do
      nil ->
        before

      {jx, jy} = joint ->
        cosine = max(dot(joint, before), 1.0 / @miter_limit)
        {jx / cosine, jy / cosine}
    end
  end

  # -- output ------------------------------------------------------------------

  defp rebuild(lines, offset_strands, scale) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, line_index} ->
      strands =
        line.geometry
        |> strand_list()
        |> Enum.with_index()
        |> Enum.map(fn {strand, strand_index} ->
          case Map.get(offset_strands, {line_index, strand_index}) do
            nil -> strand
            points -> points |> Enum.map(&unproject(&1, scale)) |> Geometry.simplify(@output_tolerance)
          end
        end)

      %{line | geometry: %{type: "MultiLineString", coordinates: strands}}
    end)
  end

  defp strand_list(%{"type" => "MultiLineString", "coordinates" => strands}), do: strands
  defp strand_list(%{type: "MultiLineString", coordinates: strands}), do: strands
  defp strand_list(_geometry), do: []
end
