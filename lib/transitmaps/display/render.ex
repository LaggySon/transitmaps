defmodule Transitmaps.Display.Render do
  @moduledoc """
  Turns the ordered line graph into the features the map draws.

  Two renderings come off the same graph, and neither one moves any
  geometry: a line is served on the track it actually runs on, and its place
  across the corridor travels with it as a **slot** — a signed count of
  places from the middle of the bundle. The renderer turns a slot into a
  sideways shift *in screen pixels*, so a corridor holds its shape at every
  zoom.

  That is the whole point of doing it this way. Bundling by moving the
  served coordinates apart has to pick one ground distance for the gap
  between neighbours, and no such distance exists: ten metres is a third of
  a pixel at the country zooms and fifty pixels at the deepest street zoom,
  so the same map is a smear at one end and a fan of unrelated lines at the
  other. A slot has no size until it is drawn, and the size it takes is
  whatever reads well at the zoom it is drawn at.

  Slots come from the per-edge order: the *n* lines on an edge take slots
  `-(n-1)/2 … (n-1)/2`, so the bundle stays centred on the track and the
  survivors close up when a line leaves. Along a track, each line's slots
  are smoothed over a short window and stepped in quarters, which turns the
  jump where a bundle changes composition into a short ramp of a few
  features — the map's answer to a junction throat, and too small to see at
  the zooms where the offsets themselves are small.

  `ribbons/2` is the same graph read the other way: one feature per stretch
  of track, carrying its lines in order, for drawing a corridor as a single
  striped line instead of as neighbours.
  """

  alias Transitmaps.Display.LineGraph
  alias Transitmaps.Display.Path
  alias Transitmaps.Geometry

  # Slots are stepped this fine. A ramp between two bundle shapes is drawn as
  # constant-slot pieces, and a quarter of a slot is under a pixel of shift
  # at any zoom the map draws — small enough that the ramp reads as a
  # diagonal rather than as stairs.
  @slot_step 0.25

  # Slot changes are averaged over this much track either side, so a line
  # closing into the space a neighbour left does it over a junction's length
  # instead of stepping sideways at a vertex.
  @taper_km 0.35

  # Served geometry is simplified at about 2 m, which is finer than the
  # 2.5 m the importer stores, so nothing is coarsened on the way out.
  @output_tolerance 0.00002

  @doc """
  One feature per run of track a line holds a single slot along.

  Each is `%{line:, slot:, bundle:, coordinates:}` — `line` indexes the
  input lines, `slot` is the signed offset in bundle places, and `bundle` is
  how many lines share the widest part of the run.
  """
  def runs(graph, orders)

  def runs(nil, _orders), do: []

  def runs(graph, orders) do
    graph.edges
    |> Enum.group_by(& &1.track)
    |> Enum.sort()
    |> Enum.flat_map(fn {track, edges} ->
      track_runs(Map.fetch!(graph.tracks, track), edges, orders, graph.scale)
    end)
  end

  @doc """
  One feature per stretch of track, carrying every line on it in order.

  Each is `%{lines:, coordinates:}` with `lines` in the same left-to-right
  order `runs/2` slots them in, so a striped ribbon and a bundle of
  neighbours put the colours in the same places.
  """
  def ribbons(graph, orders)

  def ribbons(nil, _orders), do: []

  def ribbons(graph, orders) do
    graph.edges
    |> Enum.group_by(& &1.track)
    |> Enum.sort()
    |> Enum.flat_map(fn {track, edges} ->
      path = Map.fetch!(graph.tracks, track)

      edges
      |> Enum.sort_by(& &1.from)
      |> Enum.map(fn edge -> {Map.fetch!(orders, edge.id), edge.from, edge.to} end)
      |> merge_ribbons()
      |> Enum.map(fn {lines, from, to} ->
        %{lines: lines, coordinates: coordinates(path, from, to, graph.scale)}
      end)
      |> Enum.reject(&(length(&1.coordinates) < 2))
    end)
  end

  defp merge_ribbons([{lines, from, boundary}, {lines, boundary, to} | rest]),
    do: merge_ribbons([{lines, from, to} | rest])

  defp merge_ribbons([ribbon | rest]), do: [ribbon | merge_ribbons(rest)]
  defp merge_ribbons([]), do: []

  # -- slotting each line along one track --------------------------------------

  defp track_runs(path, edges, orders, scale) do
    placed = Enum.map(edges, fn edge -> {edge, Map.fetch!(orders, edge.id)} end)
    probes = for index <- 0..(Path.sample_count(path) - 1), do: Path.sample_position(path, index)

    placed
    |> Enum.flat_map(fn {_edge, order} -> order end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&line_runs(path, probes, placed, &1, scale))
  end

  defp line_runs(path, probes, placed, line, scale) do
    probes
    |> along(spans(placed, line), [])
    |> smooth(probes)
    |> Enum.zip(probes)
    |> chunk_runs()
    |> Enum.map(fn {slot, bundle, from, to} ->
      %{line: line, slot: slot, bundle: bundle, coordinates: coordinates(path, from, to, scale)}
    end)
    |> Enum.reject(&(length(&1.coordinates) < 2))
  end

  # Where along this track the line runs, and in which slot: one entry per
  # edge carrying it, in track order.
  defp spans(placed, line) do
    placed
    |> Enum.filter(fn {_edge, order} -> line in order end)
    |> Enum.map(fn {edge, order} ->
      place = Enum.find_index(order, &(&1 == line))
      {edge.from, edge.to, place - (length(order) - 1) / 2, length(order)}
    end)
    |> Enum.sort()
  end

  # Probes and spans are both in track order, so one walk places every probe.
  defp along([], _spans, acc), do: Enum.reverse(acc)

  defp along([_position | rest], [], acc), do: along(rest, [], [nil | acc])

  defp along([position | rest] = probes, [{from, to, slot, bundle} | later] = spans, acc) do
    cond do
      position < from -> along(rest, spans, [nil | acc])
      position <= to -> along(rest, spans, [{slot, bundle} | acc])
      true -> along(probes, later, acc)
    end
  end

  # Distance-weighted averaging within each run of track the line holds, so a
  # change of slot becomes a ramp. Averaging never reaches across a gap: the
  # slot a line had before it left the track says nothing about the slot it
  # takes when it comes back.
  defp smooth(placed, probes) do
    placed
    |> Enum.zip(probes)
    |> Enum.chunk_by(fn {place, _position} -> is_nil(place) end)
    |> Enum.flat_map(fn
      [{nil, _position} | _rest] = chunk -> Enum.map(chunk, fn _entry -> nil end)
      chunk -> smooth_run(chunk)
    end)
  end

  defp smooth_run(chunk) do
    slots = chunk |> Enum.map(fn {{slot, _bundle}, _position} -> slot end) |> List.to_tuple()
    bundles = chunk |> Enum.map(fn {{_slot, bundle}, _position} -> bundle end) |> List.to_tuple()
    positions = chunk |> Enum.map(fn {_place, position} -> position end) |> List.to_tuple()
    count = tuple_size(slots)

    for index <- 0..(count - 1) do
      {sum, total, widest} = window(slots, bundles, positions, count, index)
      {stepped(sum / total), widest}
    end
  end

  defp window(slots, bundles, positions, count, index) do
    at = elem(positions, index)
    seed = {elem(slots, index), 1, elem(bundles, index)}
    forward = accumulate(slots, bundles, positions, count, index + 1, at, 1, seed)

    accumulate(slots, bundles, positions, count, index - 1, at, -1, forward)
  end

  defp accumulate(slots, bundles, positions, count, index, at, step, acc) do
    if index < 0 or index >= count or abs(elem(positions, index) - at) > @taper_km do
      acc
    else
      {sum, total, widest} = acc

      accumulate(slots, bundles, positions, count, index + step, at, step, {
        sum + elem(slots, index),
        total + 1,
        max(widest, elem(bundles, index))
      })
    end
  end

  defp stepped(value), do: Float.round(value / @slot_step) * @slot_step

  # Neighbouring probes holding one slot are a single drawn run. A run
  # borrows the next one's first probe, so consecutive pieces of a line meet
  # instead of leaving a seam where the ramp steps.
  defp chunk_runs(placed) do
    chunks = Enum.chunk_by(placed, fn {place, _position} -> place end)

    chunks
    |> Enum.zip(Enum.drop(chunks, 1) ++ [[]])
    |> Enum.flat_map(fn
      {[{nil, _position} | _rest], _next} ->
        []

      {[{{slot, bundle}, from} | _rest] = chunk, next} ->
        {_place, last} = List.last(chunk)
        [{slot, bundle, from, boundary(next, last)}]
    end)
  end

  defp boundary([{{_slot, _bundle}, position} | _rest], _last), do: position
  defp boundary(_next, last), do: last

  defp coordinates(path, from, to, scale) do
    path
    |> Path.slice(from, to)
    |> Enum.map(&LineGraph.unproject(&1, scale))
    |> Geometry.simplify(@output_tolerance)
  end
end
