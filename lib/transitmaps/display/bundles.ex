defmodule Transitmaps.Display.Bundles do
  @moduledoc """
  Works out which lines share each run of track, and where that track runs.

  Where several lines follow the same corridor they must render side by
  side — never overlapping — the way Apple Maps and OpenRailwayMap draw
  shared track. The corridor is read *locally*: at every point along a
  line, only the lines actually present on that stretch belong to the
  bundle there.

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
       it fell.
    4. Membership is smoothed along the line so it changes at junctions
       rather than at every wobble, and each vertex is pushed sideways
       along its (miter-clamped) normal onto the bundle's mean centreline
       — so shapes lying a track's width apart come out on one axis.

  What it does not do is decide how far apart to draw the members. That is
  a screen measurement, not a ground one: ten metres of ground is a fifth
  of a pixel at the country zooms and fifty pixels at z19, so a spacing
  baked into the geometry can only be right at one zoom. The renderer
  spaces the bands, in pixels, off the member count this module reports.

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

  # Cap on the shared-axis correction, so one badly georeferenced shape
  # cannot drag its bundle sideways off the track.
  @max_correction_km 0.06

  # A ribbon may not change composition over a stretch shorter than this. Even
  # smoothed, membership settles a band on and off again over a few hundred
  # metres around a junction throat, and every change is a step in the ribbon's
  # width: the corridor reads as a row of stubby ribbons of alternating
  # thickness rather than as one railway that gains a line and carries on.
  @min_run_km 0.35

  # How far a line takes to settle onto its own track after leaving a ribbon,
  # or to rise off it before joining one. Long enough that the turn out of a
  # corridor is a curve rather than a kink, short enough that the line is
  # visibly leaving rather than running alongside.
  @taper_km 0.3

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
  One ribbon per run of track, carrying every line that runs along it.

  Each segment is `%{members: [line index], coordinates: [[lon, lat]]}`, with
  members in a stable rank order, so a renderer can draw one thicker line
  divided into a band per member rather than drawing the members alongside
  each other. A stretch only one line uses comes back as a bundle of one, so
  the segments cover the whole network.

  A segment lies on the corridor's own centreline rather than on the track of
  whichever member produced it. Ribbons of one corridor therefore continue one
  another however the work is divided up between its members.

  Lines are drawn in rank order and each one claims, for every line on the
  ribbons it lays down, the ground those ribbons cover — both under the drawing
  line and under each member itself. A later line skips only what has already
  been claimed on its behalf, so every line is either carried by an earlier
  ribbon or draws its own: the network is covered by construction, whether or
  not two lines agree about who shares a corridor.

  Two rules keep what comes out of that readable as railways rather than as
  fragments. A ribbon may not change composition over a stretch too short to
  read as a junction, and a line joining or leaving a corridor has the first
  stretch of its own line eased off the corridor's centreline and onto its own
  track, so it turns out of the ribbon that was carrying it rather than
  surfacing beside it.
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

  # The corridor's own points, cut into runs that share a place in the bundle
  # and a claim. Every vertex lands in exactly one run and runs share their
  # boundary vertex, so the runs tile the line with no gaps; the drawn ones
  # come back as segments, and the ground they cover is claimed for every line
  # they carry.
  #
  # A ribbon stands for a corridor rather than for the line that happened to
  # draw it, so it is laid on the corridor's centreline — the same shared axis
  # the members are packed around — and not on the drawing line's own
  # shape. Drawn on the drawing line's shape, one corridor came out as a chain
  # of ribbons each lying on a different member's track: consecutive ribbons
  # stepped sideways by the width of the railway, crossed over each other where
  # they met, and the stretch a neighbour had already covered was re-drawn as a
  # ribbon floating alongside, because a claim recorded on one member's cells
  # never matched the cells the next member ran through.
  defp corridor_segments(points, line_index, index, scale, claimed) do
    bundles = Enum.map(points, &bundle_at(&1, line_index, index))

    members =
      bundles
      |> Enum.map(fn entries -> Enum.map(entries, fn {other, _mean, _dir} -> other end) end)
      |> steady_members(points)
      |> settle_short_runs(points)

    centreline = corridor_centreline(points, bundles, line_index)

    runs =
      [points, centreline, bundles, members, steady_claims(points, bundles, line_index, claimed)]
      |> Enum.zip_with(fn [point, centre, entries, members, undrawn?] ->
        {point, centre, entries, members, undrawn?}
      end)
      |> Enum.chunk_by(fn {_point, _centre, _entries, members, undrawn?} ->
        {members, undrawn?}
      end)
      |> join_segment_ends()
      |> join_to_ribbons()
      |> Enum.filter(fn {_members, undrawn?, run} -> undrawn? and match?([_, _ | _], run) end)

    segments =
      Enum.map(runs, fn {members, _undrawn?, run} ->
        %{
          members: members,
          coordinates:
            Enum.map(run, fn {_point, centre, _entries} -> unproject(centre, scale) end)
        }
      end)

    {segments, claim(claimed, runs)}
  end

  # The corridor's shared axis under this line: its own vertices pushed
  # sideways onto the bundle's mean centreline, smoothed along the line so the
  # axis bends rather than steps. Every member of a corridor lands on
  # nearly the same axis, so whichever of them draws a stretch, the ribbon
  # continues where its neighbour left off.
  defp corridor_centreline(points, bundles, line_index) do
    normals = vertex_normals(points)
    raw = corridor_corrections(points, normals, bundles, line_index)

    offset_points(points, smooth_values(points, raw), normals)
  end

  # Each run borrows the next run's first vertex, so neighbouring segments meet
  # instead of leaving a gap where the bundle changes shape.
  defp join_segment_ends(chunks) do
    chunks
    |> Enum.zip(Enum.drop(chunks, 1) ++ [[]])
    |> Enum.map(fn {chunk, next} ->
      {_point, _centre, _entries, members, undrawn?} = List.first(chunk)

      vertices =
        Enum.map(chunk ++ Enum.take(next, 1), fn {point, centre, entries, _m, _u} ->
          {point, centre, entries}
        end)

      {members, undrawn?, vertices}
    end)
  end

  # A line joins and leaves a corridor at the ribbon, not beside it: the first
  # stretch of its own line on either side of the change is eased off the
  # corridor's centreline and onto its own track.
  #
  # A ribbon carries a line until the two are a bundle's reach apart — a couple
  # of hundred metres — but only ever draws it a band's width off the corridor,
  # a few metres of ground. So a line that has been drawn as a band all the way
  # to the moment it leaves has to appear, abruptly, where it actually runs:
  # its own line starts in mid-air out to one side, with a hole between it and
  # the ribbon the eye was following it along.
  #
  # Bending its first stretch back to where the ribbon leaves off closes that
  # hole with the line itself, which is what a diagram of a shared corridor
  # does — the band turns out of the bundle and away. Drawing the line back
  # along the corridor instead would close the hole with a second copy of a
  # corridor already drawn, running straight where nothing runs straight.
  defp join_to_ribbons(runs) do
    runs
    |> Enum.with_index()
    |> Enum.map(fn
      {{members, true, [_, _ | _] = run}, position} ->
        eased =
          run
          |> ease_onto(leaving_anchor(Enum.at(runs, position - 1, nil), position))
          |> Enum.reverse()
          |> ease_onto(joining_anchor(Enum.at(runs, position + 1, nil)))
          |> Enum.reverse()

        {members, true, eased}

      {run, _position} ->
        run
    end)
  end

  # Where the corridor's centreline lay the last moment this line was on it.
  # Runs share their boundary vertex, so the last vertex the ribbon actually
  # carried is the one before that — at the shared vertex the line already
  # stands alone and names no corridor.
  defp leaving_anchor(_previous, 0), do: nil
  defp leaving_anchor({_members, false, vertices}, _position), do: anchor(Enum.at(vertices, -2))
  defp leaving_anchor(_previous, _position), do: nil

  defp joining_anchor({_members, false, vertices}), do: anchor(Enum.at(vertices, 1))
  defp joining_anchor(_next), do: nil

  defp anchor(nil), do: nil

  defp anchor({{x, y}, _centre, [_, _ | _] = entries}) do
    count = length(entries)

    {sx, sy} =
      Enum.reduce(entries, {0.0, 0.0}, fn {_other, {mx, my}, _direction}, {ax, ay} ->
        {ax + mx, ay + my}
      end)

    {sx / count - x, sy / count - y}
  end

  defp anchor(_vertex), do: nil

  defp ease_onto(run, nil), do: run

  defp ease_onto(run, offset) do
    points = Enum.map(run, fn {point, _centre, _entries} -> point end)
    [head | _] = normals = vertex_normals(points)
    lateral = dot(offset, head)

    [run, normals, cumulative_distances(points)]
    |> Enum.zip_with(fn [{{px, py} = point, {cx, cy}, entries}, {nx, ny}, travelled] ->
      # Between where the corridor ran and where this line's own ribbon goes.
      # Adding the one to the other instead overshoots by whatever correction
      # the line still carries here, which is most of a bundle's width.
      weight = eased(travelled / @taper_km)
      corridor_x = px + nx * lateral
      corridor_y = py + ny * lateral

      {point, {cx + (corridor_x - cx) * weight, cy + (corridor_y - cy) * weight}, entries}
    end)
  end

  # Falls from one to nothing over the taper, flat at both ends. Fading the
  # pull off in a straight ramp instead leaves a corner in the line where the
  # ramp starts and another where it runs out.
  defp eased(fraction) when fraction >= 1.0, do: 0.0

  defp eased(fraction) do
    remaining = 1.0 - fraction
    remaining * remaining * (3.0 - 2.0 * remaining)
  end

  # A drawn ribbon stands for every line on it, so it settles those lines' claim
  # to the ground it covers and they need not draw it again.
  #
  # Ground is measured in each line's own track, never in the ribbon's, because
  # that is where a line asks its question: a claim recorded on the corridor
  # centreline would answer for nobody but the line lying exactly under it.
  # A ribbon therefore settles the claim of every member both where the drawing
  # line runs and where that member itself runs — the sample the bundle lookup
  # already found for it. That second half is what a corridor several tracks
  # wide needs: its outer members never share a cell with the line drawing the
  # ribbon, and without it each of them drew the whole corridor again as a
  # ribbon of its own, floating a railway's width to the side of the one
  # already carrying it.
  #
  # Nothing is claimed for a line that is not on the ribbon, and nothing beyond
  # the samples the lookup vouches for, so a line still draws every stretch no
  # ribbon carries.
  defp claim(claimed, runs) do
    Enum.reduce(runs, claimed, fn {members, _undrawn?, run}, acc ->
      on_ribbon = MapSet.new(members)

      Enum.reduce(run, acc, fn {point, _centre, entries}, inner ->
        cell = near_cell(point)

        member_cells =
          for {other, mean, _direction} <- entries,
              MapSet.member?(on_ribbon, other),
              do: {near_cell(mean), other}

        Enum.reduce(
          Enum.map(members, &{cell, &1}) ++ member_cells,
          inner,
          &MapSet.put(&2, &1)
        )
      end)
    end)
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

  # Composition changes that come and go again inside `@min_run_km` are read as
  # noise rather than as a junction: the shortest such run takes the membership
  # of whichever neighbour it has most in common with, and the pass repeats
  # until every run is long enough to read. Smoothing alone cannot do this —
  # it settles each line's presence independently, so two lines swapping over a
  # few hundred metres still leaves three runs behind.
  defp settle_short_runs(per_vertex, points) do
    distances = points |> cumulative_distances() |> List.to_tuple()

    per_vertex
    |> membership_runs()
    |> settle_runs(distances)
    |> Enum.flat_map(fn {members, first, last} ->
      List.duplicate(members, last - first + 1)
    end)
  end

  defp membership_runs(per_vertex) do
    per_vertex
    |> Enum.with_index()
    |> Enum.chunk_by(fn {members, _vertex} -> members end)
    |> Enum.map(fn chunk ->
      {members, first} = hd(chunk)
      {_members, last} = List.last(chunk)
      {members, first, last}
    end)
  end

  defp settle_runs([_only] = runs, _distances), do: runs

  defp settle_runs(runs, distances) do
    shortest =
      runs
      |> Enum.with_index()
      |> Enum.filter(fn {run, _position} -> run_km(run, distances) < @min_run_km end)
      |> Enum.min_by(fn {run, _position} -> run_km(run, distances) end, fn -> nil end)

    case shortest do
      nil ->
        runs

      {_run, position} ->
        # Each pass leaves the run identical to a neighbour, so the two coalesce
        # and the count falls by at least one: the recursion always ends.
        runs
        |> adopt_neighbour(position, distances)
        |> coalesce_runs()
        |> settle_runs(distances)
    end
  end

  defp adopt_neighbour(runs, position, distances) do
    {_members, first, last} = Enum.at(runs, position)
    {members, _first, _last} = preferred_neighbour(runs, position, distances)

    List.replace_at(runs, position, {members, first, last})
  end

  # The neighbour a short run is most plausibly part of: the one sharing the
  # most lines with it, and failing that the longer of the two.
  defp preferred_neighbour(runs, position, distances) do
    {members, _first, _last} = Enum.at(runs, position)

    [position - 1, position + 1]
    |> Enum.filter(&(&1 >= 0 and &1 < length(runs)))
    |> Enum.map(&Enum.at(runs, &1))
    |> Enum.max_by(fn {neighbour, _first, _last} = run ->
      {length(neighbour -- (neighbour -- members)), run_km(run, distances)}
    end)
  end

  defp coalesce_runs(runs) do
    runs
    |> Enum.reduce([], fn
      {members, _first, last}, [{members, kept_first, _kept_last} | rest] ->
        [{members, kept_first, last} | rest]

      run, acc ->
        [run | acc]
    end)
    |> Enum.reverse()
  end

  defp run_km({_members, first, last}, distances) do
    elem(distances, last) - elem(distances, first)
  end

  # Whether each vertex still needs drawing, settled over that same window.
  # Claims are recorded cell by cell, so a line weaving in and out of the cells
  # an earlier ribbon covered reads as covered, uncovered, covered along its
  # length and would be cut up accordingly.
  #
  # A line standing on its own track is never treated as carried, whatever the
  # cells say. That is the counterweight to claiming ground under each member
  # as well as under the ribbon: claims now reach cells the drawing line never
  # touched, and nothing else stops one of them landing on a stretch the same
  # line comes back to alone later — which is how a line goes missing.
  defp steady_claims(points, bundles, line_index, claimed) do
    [points, bundles]
    |> Enum.zip_with(fn [point, bundle] ->
      carried? =
        match?([_, _ | _], bundle) and
          MapSet.member?(claimed, {near_cell(point), line_index})

      if carried?, do: 0.0, else: 1.0
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

  # The lateral correction at each vertex that puts this line on its corridor's
  # shared axis. Where a line stands alone it finds only itself, the correction
  # is nothing, and the axis is its own centreline.
  defp corridor_corrections(points, normals, bundles, line_index) do
    Enum.zip_with([points, normals, bundles], fn [point, normal, members] ->
      if Enum.any?(members, fn {other, _mean, _direction} -> other == line_index end) do
        own_mean =
          Enum.find_value(members, point, fn {other, mean, _d} -> other == line_index && mean end)

        correction(members, own_mean, normal)
      else
        0.0
      end
    end)
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

  # Push each vertex sideways along its miter-clamped normal.
  defp offset_points(points, corrections, normals) do
    Enum.zip_with([points, corrections, normals], fn [{x, y}, correction, {nx, ny}] ->
      {x + nx * correction, y + ny * correction}
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

  defp strand_list(%{"type" => "MultiLineString", "coordinates" => strands}), do: strands
  defp strand_list(%{type: "MultiLineString", coordinates: strands}), do: strands
  defp strand_list(_geometry), do: []
end
