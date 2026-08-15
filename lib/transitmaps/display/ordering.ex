defmodule Transitmaps.Display.Ordering do
  @moduledoc """
  Decides which order the lines on an edge sit in, across the corridor.

  Once lines share track, the only thing left to settle is who is on the
  left. It matters more than it sounds: a line that leaves the corridor to
  the left, drawn on the right of the bundle, has to cut across every one of
  its neighbours to get there. Those cuts are what makes an auto-drawn
  transit map look tangled, and minimising them is the whole of the
  "line-ordering" problem this stage is named for (the *metro-line crossing
  minimisation* of the transit-cartography literature, and the middle stage
  of Bast, Brosi and Storandt's LOOM).

  Each junction is treated as a disc. Every edge meeting there presents a
  cross-section — its lines in order, laid across the disc perpendicular to
  the direction the edge leaves in — and the fronts are read off in
  bearing order, so the disc's rim carries every line-end once. A line
  passing through appears at two points on the rim and so spans a chord;
  two lines cross exactly when their chords interleave. Counting interleaved
  pairs counts the crossings a reader would see.

  Orders start at the stable line ranking (which crosses nothing along a
  corridor, only at its junctions) and are improved by swapping neighbours
  wherever that lowers the count at the junctions the edge touches. Only
  strict improvements are taken, so an edge nothing else meets keeps the
  ranked order and the map stays stable between builds.
  """

  alias Transitmaps.Display.Path

  # Edge ends closer than this belong to one junction. A branch's first
  # coordinate is anchored onto the trunk it leaves, so the two ends meet
  # within a boundary's rounding of each other.
  @node_km 0.15

  # Bearings are read this far along the edge rather than from its first
  # segment, so a junction throat's opening curve does not decide which way
  # the edge is heading.
  @bearing_km 0.2

  # Improvement passes over the whole graph. Crossing counts settle in two or
  # three; the cap only bounds pathological input.
  @passes 6

  @doc """
  Line order per edge, as `%{edge id => [line index]}` left to right
  relative to the edge's own direction of travel.
  """
  def order(nil), do: %{}

  def order(graph) do
    nodes = graph |> edge_ends() |> cluster() |> Enum.filter(&(length(&1) > 1))
    junctions = nodes |> Enum.with_index() |> Map.new(fn {ends, index} -> {index, ends} end)

    incident =
      for {index, ends} <- junctions, stop <- ends, reduce: %{} do
        acc -> Map.update(acc, stop.edge, [index], &Enum.uniq([index | &1]))
      end

    graph.edges
    |> Map.new(fn edge -> {edge.id, edge.lines} end)
    |> optimise(junctions, incident)
  end

  # -- junction discovery ------------------------------------------------------

  # Both ends of every edge, with the bearing the edge leaves that end on.
  # Positions along a track are resolved for the whole track in one pass.
  defp edge_ends(graph) do
    graph.edges
    |> Enum.group_by(& &1.track)
    |> Enum.sort()
    |> Enum.flat_map(fn {track, edges} ->
      path = Map.fetch!(graph.tracks, track)

      positions =
        edges
        |> Enum.flat_map(&anchor_positions/1)
        |> Enum.uniq()
        |> Enum.sort()

      points =
        path
        |> Path.locate(positions)
        |> Enum.map(fn {_index, point} -> point end)

      located = positions |> Enum.zip(points) |> Map.new()

      Enum.flat_map(edges, fn edge ->
        [
          stop(edge, :start, edge.from, ahead(edge), located),
          stop(edge, :end, edge.to, behind(edge), located)
        ]
      end)
    end)
  end

  defp anchor_positions(edge), do: [edge.from, edge.to, ahead(edge), behind(edge)]

  defp ahead(edge), do: min(edge.from + @bearing_km, edge.to)
  defp behind(edge), do: max(edge.to - @bearing_km, edge.from)

  defp stop(edge, side, at, towards, located) do
    {x, y} = point = Map.fetch!(located, at)
    {ax, ay} = Map.fetch!(located, towards)

    %{edge: edge.id, side: side, point: point, bearing: :math.atan2(ay - y, ax - x)}
  end

  defp cluster(ends) do
    indexed = ends |> Enum.with_index() |> Map.new(fn {stop, index} -> {index, stop} end)

    cells =
      Enum.group_by(
        indexed,
        fn {_index, stop} -> cell(stop.point) end,
        fn {index, _stop} -> index end
      )

    {groups, _seen} =
      indexed
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, fn index, {groups, seen} ->
        if MapSet.member?(seen, index) do
          {groups, seen}
        else
          {members, seen} = flood([index], indexed, cells, MapSet.put(seen, index), [])
          {[Enum.map(members, &Map.fetch!(indexed, &1)) | groups], seen}
        end
      end)

    Enum.reverse(groups)
  end

  defp flood([], _indexed, _cells, seen, members), do: {members, seen}

  defp flood([index | queue], indexed, cells, seen, members) do
    stop = Map.fetch!(indexed, index)
    {cx, cy} = cell(stop.point)

    {found, seen} =
      for dx <- -1..1,
          dy <- -1..1,
          other <- Map.get(cells, {cx + dx, cy + dy}, []),
          reduce: {[], seen} do
        {found, seen} ->
          if MapSet.member?(seen, other) or
               Path.distance(stop.point, Map.fetch!(indexed, other).point) > @node_km do
            {found, seen}
          else
            {[other | found], MapSet.put(seen, other)}
          end
      end

    flood(found ++ queue, indexed, cells, seen, [index | members])
  end

  defp cell({x, y}), do: {floor(x / @node_km), floor(y / @node_km)}

  # -- crossing minimisation ---------------------------------------------------

  defp optimise(orders, junctions, incident) do
    ids = orders |> Map.keys() |> Enum.sort()

    Enum.reduce_while(1..@passes, orders, fn _pass, orders ->
      {improved, changed?} =
        Enum.reduce(ids, {orders, false}, fn id, {orders, changed?} ->
          {orders, moved?} = improve(orders, id, Map.get(incident, id, []), junctions)
          {orders, changed? or moved?}
        end)

      if changed?, do: {:cont, improved}, else: {:halt, orders}
    end)
  end

  defp improve(orders, _id, [], _junctions), do: {orders, false}

  defp improve(orders, id, indexes, junctions) do
    case Map.fetch!(orders, id) do
      order when length(order) < 2 ->
        {orders, false}

      order ->
        Enum.reduce(0..(length(order) - 2), {orders, false}, fn position, {orders, changed?} ->
          candidate = orders |> Map.fetch!(id) |> swap(position)
          proposed = Map.put(orders, id, candidate)

          if cost(indexes, junctions, proposed) < cost(indexes, junctions, orders) do
            {proposed, true}
          else
            {orders, changed?}
          end
        end)
    end
  end

  defp swap(order, position) do
    {before, [left, right | rest]} = Enum.split(order, position)
    before ++ [right, left | rest]
  end

  defp cost(indexes, junctions, orders) do
    Enum.reduce(indexes, 0, fn index, total ->
      total + crossings(Map.fetch!(junctions, index), orders)
    end)
  end

  # Every line-end around the junction's rim in bearing order. Walking
  # anticlockwise crosses an edge's front from its right side to its left, so
  # an edge leaving the junction is read against its stored order and an edge
  # arriving at it with the order.
  defp crossings(ends, orders) do
    chords =
      ends
      |> Enum.sort_by(fn stop -> {stop.bearing, stop.edge, stop.side} end)
      |> Enum.flat_map(fn stop ->
        order = Map.fetch!(orders, stop.edge)
        if stop.side == :start, do: Enum.reverse(order), else: order
      end)
      |> Enum.with_index()
      |> Enum.group_by(fn {line, _at} -> line end, fn {_line, at} -> at end)
      |> Enum.flat_map(fn
        {_line, [first, second]} -> [{min(first, second), max(first, second)}]
        {_line, _elsewhere} -> []
      end)

    for {a1, b1} <- chords, {a2, b2} <- chords, {a1, b1} < {a2, b2}, reduce: 0 do
      total ->
        if (a2 > a1 and a2 < b1) != (b2 > a1 and b2 < b1), do: total + 1, else: total
    end
  end
end
