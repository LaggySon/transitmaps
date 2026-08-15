defmodule Transitmaps.Display.LineGraph do
  @moduledoc """
  Collapses every line's geometry onto one shared network, then cuts that
  network into edges that each carry a fixed set of lines.

  This is the piece the rest of the drawing pipeline stands on, and it is a
  *topological* answer to a question that cannot be answered geometrically.
  A feed gives each line its own trace of the same railway: ten operators
  along the West Coast Main Line arrive as ten polylines wandering within a
  hundred metres of each other, agreeing about nothing. Asking "who else is
  here?" at each vertex of each line — the obvious approach, and the one this
  replaces — gives ten *different* answers along the same corridor, because
  every line polls from a different place. Everything downstream then has to
  paper over the disagreement with smoothing, majority votes and tie-breaks,
  and lines still flicker in and out of the bundle they belong to.

  Instead, lines are made to *share geometry*. Strands are absorbed longest
  first: the first one to cover a stretch of ground lays down a **track**,
  and every later strand that runs along it within `#{trunc(1000 * 0.12)} m
  is recorded as using that same track rather than contributing a rival
  polyline. A line becomes a set of intervals on shared tracks — a path
  through a network — so "who runs here" stops being a measurement and
  becomes a fact about the graph.

  Cutting each track at every point where that set changes gives the
  **edges**: maximal runs of track along which the membership is constant.
  An edge is what gets drawn — once, with its lines side by side — and
  because each line's coverage is a union of edges, no stretch of any line
  can be lost or drawn twice.

  Membership boundaries snap to a #{trunc(1000 * 0.15)} m grid along the
  track and always outward, so a line's coverage is never trimmed and the
  network is never cut into slivers too short to read.
  """

  alias Transitmaps.Display.Path
  alias Transitmaps.Geometry

  # How far off a track a line may run and still be treated as running along
  # it. Set at the width of a big railway rather than a single track: a trunk
  # route carries its operators over several parallel tracks that fan wider
  # still through a station throat, and measured any tighter they drop in and
  # out of the corridor they plainly share.
  @snap_km 0.12

  # Lines only share track where they run the same way (or exactly against
  # it, which is the same track travelled the other way). A crossing is not a
  # corridor.
  @parallel_cosine 0.7

  # A match may not skip more than this many probes along the track at once,
  # which keeps a line from jumping to a distant part of a track that happens
  # to loop back near it.
  @max_sample_jump 3

  # Stretches shorter than this are noise in the match, not track: a wobble
  # out of range mid-corridor, or a few probes clipping a track the line
  # merely crosses. They are absorbed into their surroundings.
  @min_run_km 0.15

  # Edge boundaries snap to this grid along the track. Ribbons shorter than
  # this read as fragments rather than as a railway, and every boundary that
  # moves is rounded outward, so a line covers slightly more track rather
  # than leaving a gap.
  @min_edge_km 0.15

  @doc """
  Builds the shared line graph for `lines`.

  Each line needs a `:geometry` MultiLineString. Returns
  `%{scale:, tracks:, edges:}` where every edge is
  `%{id:, track:, from:, to:, lines:}` — `from` and `to` are distances in
  kilometres along the track, and `lines` are indexes into `lines`, sorted.
  Returns `nil` when there is no drawable geometry.
  """
  def build(lines) do
    strands =
      for {line, line_index} <- Enum.with_index(lines),
          strand <- strand_list(line.geometry),
          match?([_, _ | _], strand) do
        {line_index, strand}
      end

    case strands do
      [] ->
        nil

      [{_line_index, [reference | _]} | _] ->
        network(strands, Geometry.km_scale(reference))
    end
  end

  @doc "The coordinates an edge draws, as `[lon, lat]` pairs."
  def edge_coordinates(graph, edge) do
    graph.tracks
    |> Map.fetch!(edge.track)
    |> Path.slice(edge.from, edge.to)
    |> Enum.map(&unproject(&1, graph.scale))
  end

  @doc "Converts a projected point back to `[lon, lat]`."
  def unproject({x, y}, {kx, ky}), do: [x / kx, y / ky]

  defp network(strands, scale) do
    absorbed =
      strands
      |> Enum.map(fn {line_index, strand} ->
        {line_index, Path.new(Enum.map(strand, &project(&1, scale)))}
      end)
      |> Enum.reject(fn {_line_index, path} -> is_nil(path) end)
      # Longest first, so a trunk route's geometry is the one the corridor
      # keeps and short service variants snap onto it rather than the reverse.
      |> Enum.sort_by(fn {line_index, path} -> {-path.length, line_index} end)
      |> Enum.reduce(%{tracks: %{}, index: %{}, next: 0, usages: []}, &absorb/2)

    %{scale: scale, tracks: absorbed.tracks, edges: edges(absorbed.tracks, absorbed.usages)}
  end

  # -- absorbing a strand into the network -------------------------------------

  defp absorb({line_index, path}, state) do
    matches = for index <- 0..(Path.sample_count(path) - 1), do: match(state, path, index)

    matches
    |> runs()
    |> tidy(path)
    |> anchored()
    |> Enum.reduce(state, &record(&2, line_index, path, &1))
  end

  # The track this probe runs along, as `{track id, probe index}`: the nearest
  # probe of any track within snapping range that is travelling the same way.
  defp match(state, path, index) do
    point = Path.sample_point(path, index)
    direction = Path.sample_direction(path, index)
    {cx, cy} = cell(point)

    found =
      for dx <- -1..1,
          dy <- -1..1,
          {track, other} <- Map.get(state.index, {cx + dx, cy + dy}, []),
          reduce: nil do
        best -> closer(best, {track, other}, state.tracks, point, direction)
      end

    case found do
      nil -> nil
      {track, other, _distance} -> {track, other}
    end
  end

  defp closer(best, {track, other}, tracks, point, direction) do
    path = Map.fetch!(tracks, track)
    distance = Path.distance(Path.sample_point(path, other), point)

    cond do
      distance > @snap_km ->
        best

      abs(Path.dot(direction, Path.sample_direction(path, other))) < @parallel_cosine ->
        best

      match?({_track, _other, previous} when previous <= distance, best) ->
        best

      true ->
        {track, other, distance}
    end
  end

  # Consecutive probes that matched the same track, advancing steadily along
  # it, are one run on that track; consecutive misses are one novel run.
  defp runs(matches) do
    matches
    |> Enum.with_index()
    |> Enum.reduce([], fn {found, index}, open -> extend(open, found, index) end)
    |> Enum.reverse()
  end

  defp extend(
         [{:on, track, from, _to, entered, left, heading} | rest] = open,
         {track, other},
         index
       ) do
    step = other - left

    cond do
      abs(step) > @max_sample_jump ->
        [started(track, index, other) | open]

      heading == 0 or step == 0 or sign(step) == heading ->
        settled = if heading == 0, do: sign(step), else: heading
        [{:on, track, from, index, entered, other, settled} | rest]

      true ->
        [started(track, index, other) | open]
    end
  end

  defp extend([{:novel, from, _to} | rest], nil, index), do: [{:novel, from, index} | rest]
  defp extend(open, nil, index), do: [{:novel, index, index} | open]
  defp extend(open, {track, other}, index), do: [started(track, index, other) | open]

  defp started(track, index, other), do: {:on, track, index, index, other, other, 0}

  defp sign(value) when value > 0, do: 1
  defp sign(value) when value < 0, do: -1
  defp sign(_value), do: 0

  # Runs too short to be real track are demoted and merged away, then a brief
  # novel gap between two runs on one track is closed: without this a line
  # straying a platform's width for two hundred metres mid-corridor lays down
  # a stray parallel track and cuts the corridor into three.
  defp tidy(runs, path) do
    minimum = max(1, round(@min_run_km / Path.sample_km()))

    runs
    |> Enum.map(&demote(&1, minimum))
    |> merge()
    |> bridge(minimum)
    |> merge()
    |> Enum.reject(&dropped?(&1, path))
  end

  defp demote({:on, _track, from, to, _entry, _exit, _heading}, minimum) when to - from < minimum,
    do: {:novel, from, to}

  defp demote(run, _minimum), do: run

  defp merge([{:novel, from, _to}, {:novel, _next, to} | rest]),
    do: merge([{:novel, from, to} | rest])

  defp merge([run | rest]), do: [run | merge(rest)]
  defp merge([]), do: []

  defp bridge([before, {:novel, _gap_from, _gap_to} = gap, aft | rest], minimum) do
    case joined(before, gap, aft, minimum) do
      nil -> [before | bridge([gap, aft | rest], minimum)]
      run -> bridge([run | rest], minimum)
    end
  end

  defp bridge([run | rest], minimum), do: [run | bridge(rest, minimum)]
  defp bridge([], _minimum), do: []

  # A gap short enough to be a wobble, between two runs carrying on the same
  # way along one track, is the same stretch of corridor throughout.
  defp joined(
         {:on, track, from, _to, entered, left, _heading},
         {:novel, gap_from, gap_to},
         {:on, track, _next_from, next_to, next_entered, next_left, _next_heading},
         minimum
       )
       when gap_to - gap_from < minimum do
    heading = sign(next_left - entered)

    if heading != 0 and sign(left - entered) in [0, heading] and
         sign(next_left - next_entered) in [0, heading] and
         sign(next_entered - left) in [0, heading] do
      {:on, track, from, next_to, entered, next_left, heading}
    end
  end

  defp joined(_before, _gap, _aft, _minimum), do: nil

  # A novel run of a single probe carries no length worth laying track for.
  defp dropped?({:novel, from, to}, path) do
    Path.sample_position(path, to) - Path.sample_position(path, from) <= 0.0
  end

  defp dropped?(_run, _path), do: false

  # A novel run reaches back to the track it left and on to the track it
  # rejoins, so a branch meets its trunk instead of stopping a snapping
  # radius short of it.
  defp anchored(runs) do
    indexed = List.to_tuple(runs)

    runs
    |> Enum.with_index()
    |> Enum.map(fn
      {{:novel, from, to}, index} ->
        {:novel, from, to, anchor(indexed, index - 1, :exit), anchor(indexed, index + 1, :entry)}

      {run, _index} ->
        run
    end)
  end

  defp anchor(runs, index, side) when index >= 0 and index < tuple_size(runs) do
    case elem(runs, index) do
      {:on, track, _from, _to, entered, left, _heading} ->
        {track, if(side == :entry, do: entered, else: left)}

      _run ->
        nil
    end
  end

  defp anchor(_runs, _index, _side), do: nil

  defp record(state, line_index, _path, {:on, track, _from, _to, entered, left, _heading}) do
    track_path = Map.fetch!(state.tracks, track)
    first = Path.sample_position(track_path, min(entered, left))
    last = Path.sample_position(track_path, max(entered, left))

    %{state | usages: [{line_index, track, first, last} | state.usages]}
  end

  defp record(state, line_index, path, {:novel, from, to, before, aft}) do
    points =
      Enum.concat([
        anchor_point(state, before),
        Path.slice(path, Path.sample_position(path, from), Path.sample_position(path, to)),
        anchor_point(state, aft)
      ])

    case Path.new(points) do
      nil ->
        state

      track_path ->
        track = state.next

        %{
          state
          | tracks: Map.put(state.tracks, track, track_path),
            index: add_to_index(state.index, track, track_path),
            next: track + 1,
            usages: [{line_index, track, 0.0, track_path.length} | state.usages]
        }
    end
  end

  defp anchor_point(_state, nil), do: []

  defp anchor_point(state, {track, index}) do
    [state.tracks |> Map.fetch!(track) |> Path.sample_point(index)]
  end

  defp add_to_index(index, track, path) do
    Enum.reduce(0..(Path.sample_count(path) - 1), index, fn sample, acc ->
      key = path |> Path.sample_point(sample) |> cell()
      Map.update(acc, key, [{track, sample}], &[{track, sample} | &1])
    end)
  end

  # Cells are exactly the snapping radius across, so the nine cells around a
  # probe always contain everything within reach of it, whichever side of a
  # cell boundary it happened to fall.
  defp cell({x, y}), do: {floor(x / @snap_km), floor(y / @snap_km)}

  # -- cutting tracks into edges -----------------------------------------------

  defp edges(tracks, usages) do
    usages
    |> Enum.group_by(fn {_line, track, _from, _to} -> track end)
    |> Enum.sort()
    |> Enum.flat_map(fn {track, spans} -> track_edges(track, Map.fetch!(tracks, track), spans) end)
    |> Enum.with_index()
    |> Enum.map(fn {edge, id} -> Map.put(edge, :id, id) end)
  end

  defp track_edges(track, path, spans) do
    steps = max(1, round(path.length / @min_edge_km))
    unit = path.length / steps

    quantized =
      spans
      |> Enum.map(fn {line, _track, from, to} ->
        first = from |> Kernel./(unit) |> floor() |> max(0) |> min(steps - 1)
        last = to |> Kernel./(unit) |> ceil() |> max(first + 1) |> min(steps)
        {line, first, last}
      end)

    quantized
    |> Enum.flat_map(fn {_line, first, last} -> [first, last] end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [first, last] ->
      lines =
        for {line, span_first, span_last} <- quantized,
            span_first <= first,
            span_last >= last,
            uniq: true,
            do: line

      {first, last, Enum.sort(lines)}
    end)
    |> Enum.reject(fn {_first, _last, lines} -> lines == [] end)
    |> join()
    |> Enum.map(fn {first, last, lines} ->
      %{
        track: track,
        from: at(first, steps, unit, path),
        to: at(last, steps, unit, path),
        lines: lines
      }
    end)
  end

  # Quantizing can leave neighbouring stretches with the same membership;
  # drawn separately they would be two ribbons with a seam between them.
  defp join([{first, middle, lines}, {middle, last, lines} | rest]),
    do: join([{first, last, lines} | rest])

  defp join([edge | rest]), do: [edge | join(rest)]
  defp join([]), do: []

  defp at(step, steps, _unit, path) when step >= steps, do: path.length
  defp at(step, _steps, unit, _path), do: step * unit

  defp project([lon, lat], {kx, ky}), do: {lon * kx, lat * ky}

  defp strand_list(%{"type" => "MultiLineString", "coordinates" => strands}), do: strands
  defp strand_list(%{type: "MultiLineString", coordinates: strands}), do: strands
  defp strand_list(_geometry), do: []
end
