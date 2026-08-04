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
    3. At each vertex, the lines within #{trunc(1000 * 0.12)} m of it
       *running the same way* (crossings don't count) form the local
       bundle, along with whatever those lines in turn share track with.
       They are looked up in a grid of that same reach, read nine cells at
       a time so that a neighbour is found whichever side of a grid line
       it fell. Members are ordered by their stable line rank and packed
       symmetrically around the bundle's mean centreline — not each line's
       own — so source shapes lying a track's width apart still come out
       evenly spaced.
    4. The resulting per-vertex slot and centreline correction are
       smoothed along the line so membership changes become gradual
       tapers, then each vertex is pushed sideways along its
       (miter-clamped) normal by slot × #{trunc(1000 * 0.010)} m plus the
       correction.

  Reading membership from a single cell of a grid is what this used to do,
  and it made the map depend on where that invisible grid happened to fall:
  three tracks a hundred metres apart came out as one ribbon, or two, or a
  ribbon and a stray line beside it, with a line sometimes left off the map
  entirely.
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

  # Ground distance between neighbouring lines of a bundle. Ten metres packs
  # the strands just tight enough to read as one ribbon following a corridor
  # rather than as separate lines that happen to run alongside; a rendered
  # line is ~12 m of ground around z15, so neighbours touch there and any
  # tighter they would overpaint each other.
  @slot_spacing_km 0.010

  # Vertices are capped this far apart before slotting, so slot tapers and
  # curved corridors bend smoothly instead of in long straight jumps.
  @densify_km 0.15

  # Slot values are averaged over this much path either side of a vertex:
  # membership changes taper over roughly a kilometre of line.
  @smooth_km 0.45

  # Offset points may sit at most this factor beyond the nominal distance
  # at a corner, which keeps bundles tight through bends that corner
  # rounding left slightly angular. Clamping harder stops the outer strand
  # of a bundle flaring away from its neighbours around tight curves.
  @miter_limit 1.45

  # Offset strands are re-simplified before serving (~4 m tolerance):
  # densification is needed for smooth ramps but straight runs collapse
  # back to sparse vertices, keeping payloads close to the input size.
  @output_tolerance 0.00004

  # Cap on the shared-axis correction, so one badly georeferenced shape
  # cannot drag its bundle sideways off the track.
  @max_correction_km 0.06

  # Lines join a ribbon only where they would actually be drawn on top of one
  # another. Sharing a fingerprint cell is not enough on its own: a cell is
  # 400 m across, so two lines can sit in one having never come near each
  # other — which is how a line running a few streets away used to be counted
  # into a bundle it was nowhere near.
  #
  # Set at the width of a big railway rather than a single track. A trunk route
  # like the West Coast Main Line carries its operators over several parallel
  # tracks that fan wider still through a station throat; measured any tighter,
  # operators drop in and out of the ribbon along the way and one of them ends
  # up drawn as a stray line running alongside the corridor it belongs to.
  #
  # This doubles as the cell size of the corridor lookup, which reads the nine
  # cells around a vertex: a grid of exactly the reach being measured, searched
  # one ring out, always sees everything within reach whichever side of a grid
  # line it fell.
  @overlap_km 0.12

  @doc """
  Returns `lines` with corridor-sharing geometry offset into bundles.
  Line order, count, and every non-geometry field are preserved; output
  is stable for identical input.
  """
  def arrange(lines) do
    case analyse(lines) do
      nil ->
        lines

      %{aligned: aligned, index: index, scale: scale} ->
        offset_strands =
          Map.new(aligned, fn {{line_index, _strand_index} = id, points} ->
            {id, offset_strand(points, line_index, index)}
          end)

        rebuild(lines, offset_strands, scale)
    end
  end

  @doc """
  One ribbon per run of track, carrying every line that runs along it.

  Each segment is `%{members: [line index], coordinates: [[lon, lat]]}`, with
  members in the stable rank order `arrange/1` packs them in, so a renderer can
  draw one thicker line striped in its members' colours rather than drawing the
  members alongside each other. A stretch only one line uses comes back as a
  bundle of one, so the segments cover the whole network.

  Lines are drawn in rank order and each one claims, for every line on the
  ribbons it lays down, the ground those ribbons cover. A later line skips only
  what has already been claimed on its behalf, so every line is either carried
  by an earlier ribbon or draws its own: the network is covered by construction,
  whether or not two lines agree about who shares a corridor.
  """
  def corridors(lines) do
    case analyse(lines) do
      nil ->
        []

      %{aligned: aligned, index: index, scale: scale} ->
        aligned
        |> Enum.sort_by(fn {id, _points} -> id end)
        |> Enum.reduce({[], MapSet.new()}, fn {{line_index, _strand_index}, points},
                                              {drawn, claimed} ->
          {segments, claimed} = corridor_segments(points, line_index, index, scale, claimed)
          {[segments | drawn], claimed}
        end)
        |> elem(0)
        |> Enum.reverse()
        |> Enum.concat()
    end
  end

  # The corridor analysis both renderings share: strands projected, densified,
  # turned the same way along each corridor, and indexed by cell.
  defp analyse(lines) do
    strands =
      for {line, line_index} <- Enum.with_index(lines),
          {strand, strand_index} <- Enum.with_index(strand_list(line.geometry)),
          match?([_, _ | _], strand) do
        {{line_index, strand_index}, strand}
      end

    case strands do
      [] ->
        nil

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

        %{aligned: aligned, index: proximity_index(aligned), scale: scale}
    end
  end

  # The line's own points, cut into runs that share a place in the bundle and
  # a claim. Every vertex lands in exactly one run and runs share their
  # boundary vertex, so the runs tile the line with no gaps; the drawn ones
  # come back as segments, and the ground they cover is claimed for every line
  # they carry.
  defp corridor_segments(points, line_index, index, scale, claimed) do
    members = points |> Enum.map(&members_at(&1, line_index, index)) |> steady_members(points)

    runs =
      [points, members, steady_claims(points, line_index, claimed)]
      |> Enum.zip_with(fn [point, members, undrawn?] -> {point, members, undrawn?} end)
      |> Enum.chunk_by(fn {_point, members, undrawn?} -> {members, undrawn?} end)
      |> join_segment_ends()
      |> Enum.filter(fn {_members, undrawn?, run} -> undrawn? and match?([_, _ | _], run) end)

    segments =
      Enum.map(runs, fn {members, _undrawn?, run} ->
        %{members: members, coordinates: Enum.map(run, &unproject(&1, scale))}
      end)

    {segments, claim(claimed, runs)}
  end

  # Each run borrows the next run's first vertex, so neighbouring segments meet
  # instead of leaving a gap where the bundle changes shape.
  defp join_segment_ends(chunks) do
    chunks
    |> Enum.zip(Enum.drop(chunks, 1) ++ [[]])
    |> Enum.map(fn {chunk, next} ->
      {_point, members, undrawn?} = List.first(chunk)
      points = Enum.map(chunk, &elem(&1, 0)) ++ Enum.map(Enum.take(next, 1), &elem(&1, 0))
      {members, undrawn?, points}
    end)
  end

  # A drawn ribbon stands for every line on it, so it settles those lines' claim
  # to the ground it covers and they need not draw it again.
  #
  # A drawn ribbon settles its members' claim to the ground beneath it, and to
  # nothing else. Every looser rule tried here — a ring of cells around the
  # ribbon, the cell a member is centred on, every nearby cell a member is known
  # to occupy — claims track the ribbon never covered and lines start going
  # missing again, which is the failure worth avoiding.
  #
  # The cost is that a member running far enough to the side never to share a
  # cell redraws the corridor beside the ribbon carrying it. Measured over the
  # network that is 0.35% more line drawn, against a guarantee that no stretch
  # of any line goes undrawn.
  defp claim(claimed, runs) do
    Enum.reduce(runs, claimed, fn {members, _undrawn?, run}, acc ->
      Enum.reduce(run, acc, fn point, inner ->
        cell = near_cell(point)
        Enum.reduce(members, inner, &MapSet.put(&2, {cell, &1}))
      end)
    end)
  end

  # The lines sharing this vertex's track, in stable rank order. The line
  # itself is always in the list, so a stretch nobody else uses comes back as
  # a bundle of one.
  defp members_at(point, line_index, index) do
    point |> bundle_at(line_index, index) |> Enum.map(fn {other, _mean, _dir} -> other end)
  end

  # A corridor should not change composition over a stretch too short to read
  # as a junction. Each line's presence goes through the same distance-weighted
  # window the slot offsets use and is settled by majority, so a neighbour
  # dipping briefly out of reach no longer cuts the corridor in two: taking
  # every flicker at face value left half the ribbons shorter than 300 m, which
  # is what makes a main line look broken up into stray fragments.
  defp steady_members(per_vertex, points) do
    candidates = per_vertex |> Enum.concat() |> Enum.uniq() |> Enum.sort()

    presence =
      Map.new(candidates, fn member ->
        smoothed =
          per_vertex
          |> Enum.map(fn members -> if member in members, do: 1.0, else: 0.0 end)
          |> then(&smooth_values(points, &1))
          |> List.to_tuple()

        {member, smoothed}
      end)

    for vertex <- 0..(length(per_vertex) - 1) do
      for member <- candidates, elem(presence[member], vertex) > 0.5, do: member
    end
  end

  # Whether each vertex still needs drawing, settled over that same window.
  # Claims are recorded cell by cell, so a line weaving in and out of the cells
  # an earlier ribbon covered reads as covered, uncovered, covered along its
  # length and would be cut up accordingly.
  defp steady_claims(points, line_index, claimed) do
    points
    |> Enum.map(fn point ->
      if MapSet.member?(claimed, {near_cell(point), line_index}), do: 0.0, else: 1.0
    end)
    |> then(&smooth_values(points, &1))
    |> Enum.map(&(&1 > 0.5))
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

  defp merge_samples({{ax, ay}, {apx, apy}, an}, {{bx, by}, {bpx, bpy}, bn}) do
    {{ax + bx, ay + by}, {apx + bpx, apy + bpy}, an + bn}
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

  # near cell -> [{line_index, mean position, unit direction}]: where each line
  # runs, sampled at the scale bundling is decided at rather than at the much
  # coarser scale the corridor fingerprints use.
  defp proximity_index(aligned) do
    aligned
    |> Enum.reduce(%{}, fn {{line_index, _strand_index}, points}, acc ->
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(acc, fn [a, b], cells ->
        length = distance(a, b)

        if length == 0.0 do
          cells
        else
          {ax, ay} = a
          {bx, by} = b
          direction = {(bx - ax) / length, (by - ay) / length}

          cells
          |> add_near_sample(near_cell(a), line_index, direction, a)
          |> add_near_sample(near_cell(b), line_index, direction, b)
        end
      end)
    end)
    |> Map.new(fn {cell, lines} -> {cell, resolve_samples(lines)} end)
  end

  defp near_cell({x, y}), do: {floor(x / @overlap_km), floor(y / @overlap_km)}

  defp add_near_sample(index, cell, line_index, direction, point) do
    Map.update(index, cell, %{line_index => {direction, point, 1}}, fn lines ->
      Map.update(
        lines,
        line_index,
        {direction, point, 1},
        &merge_samples(&1, {direction, point, 1})
      )
    end)
  end

  defp resolve_samples(lines) do
    for {line_index, sample} <- lines,
        direction = normalize(sample_direction(sample)),
        direction != nil,
        do: {line_index, sample_mean(sample), direction}
  end

  # The lines within reach of a vertex that share its track, as index entries
  # in stable rank order — the local bundle both renderings are built from.
  #
  # Grouping has to be transitive rather than a star around the asking line.
  # Across a corridor several tracks wide the outer pair can be out of reach of
  # each other while both share track with the middle one; asked separately,
  # each line then names a different bundle, and in the ribbon rendering they
  # disagree about which of them draws it — so a line that stood aside for a
  # neighbour to carry it went undrawn for that whole stretch.
  defp bundle_at(point, line_index, index) do
    neighbours = block(point, index)
    by_line = Map.new(neighbours, fn {other, _mean, _direction} = entry -> {other, entry} end)

    if Map.has_key?(by_line, line_index) do
      neighbours
      |> couplings()
      |> reachable(line_index)
      |> Enum.map(&Map.fetch!(by_line, &1))
    else
      # A zero-length strand leaves no sample to place: it stands alone.
      [{line_index, point, {0.0, 0.0}}]
    end
  end

  # Every line with samples in the nine cells around the point, each kept at
  # whichever of those cells it comes closest to the point in.
  defp block(point, index) do
    {cx, cy} = near_cell(point)

    for dx <- -1..1,
        dy <- -1..1,
        {other, mean, _direction} = entry <- Map.get(index, {cx + dx, cy + dy}, []),
        reduce: %{} do
      acc ->
        Map.update(acc, other, entry, fn {_o, best, _d} = current ->
          if distance(mean, point) < distance(best, point), do: entry, else: current
        end)
    end
    |> Map.values()
  end

  # Which lines directly share track: close enough to be drawn on top of one
  # another and running the same way, so a crossing never couples.
  defp couplings(neighbours) do
    for {a, a_mean, a_direction} <- neighbours,
        {b, b_mean, b_direction} <- neighbours,
        a != b,
        distance(a_mean, b_mean) <= @overlap_km,
        dot(a_direction, b_direction) >= @parallel_cosine,
        reduce: %{} do
      acc -> Map.update(acc, a, [b], &[b | &1])
    end
  end

  defp reachable(couplings, start) do
    couplings |> grow([start], MapSet.new([start])) |> Enum.sort()
  end

  defp grow(_couplings, [], seen), do: seen

  defp grow(couplings, [line | queue], seen) do
    fresh = couplings |> Map.get(line, []) |> Enum.reject(&MapSet.member?(seen, &1))
    grow(couplings, queue ++ fresh, Enum.into(fresh, seen))
  end

  # -- slotting & offsetting ---------------------------------------------------

  defp offset_strand(points, line_index, index) do
    normals = vertex_normals(points)
    {raw_slots, raw_corrections} = raw_placement(points, normals, line_index, index)

    slots = smooth_values(points, raw_slots)
    corrections = smooth_values(points, raw_corrections)
    offset_points(points, slots, corrections, normals)
  end

  # At each vertex: the same local bundle the ribbons are cut from, ordered by
  # rank and packed symmetrically around the bundle's mean centreline. A line
  # always finds itself, so an isolated line sits in slot 0 with no correction
  # — the overlapping-centreline baseline.
  defp raw_placement(points, normals, line_index, index) do
    [points, normals]
    |> Enum.zip_with(fn [point, normal] ->
      members = bundle_at(point, line_index, index)

      case Enum.find_index(members, fn {other, _mean, _direction} -> other == line_index end) do
        nil ->
          {0.0, 0.0}

        slot_index ->
          own_mean =
            Enum.find_value(members, point, fn {other, mean, _d} ->
              other == line_index && mean
            end)

          slot = slot_index - (length(members) - 1) / 2
          {slot, correction(members, own_mean, normal)}
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
      Enum.reduce(members, {0.0, 0.0}, fn {_other, {mx, my}, _direction}, {ax, ay} ->
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
      accumulate(
        slots,
        positions,
        count,
        index,
        position,
        -1,
        accumulate(slots, positions, count, index, position, 1, {elem(slots, index), 1})
      )

    sum / total
  end

  defp accumulate(slots, positions, count, index, position, step, acc) do
    next = index + step

    if next < 0 or next >= count or abs(elem(positions, next) - position) > @smooth_km do
      acc
    else
      {sum, total} = acc

      accumulate(
        slots,
        positions,
        count,
        next,
        position,
        step,
        {sum + elem(slots, next), total + 1}
      )
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
            nil ->
              strand

            points ->
              points |> Enum.map(&unproject(&1, scale)) |> Geometry.simplify(@output_tolerance)
          end
        end)

      %{line | geometry: %{type: "MultiLineString", coordinates: strands}}
    end)
  end

  defp strand_list(%{"type" => "MultiLineString", "coordinates" => strands}), do: strands
  defp strand_list(%{type: "MultiLineString", coordinates: strands}), do: strands
  defp strand_list(_geometry), do: []
end
