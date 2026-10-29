defmodule Transitmaps.Services.Path do
  @moduledoc """
  The track one service runs, for the map to pick it out while its
  timetable is open.

  Feeds keep a shape per trip, but the import keeps only each route's drawn
  lines, and many routes (half of Britain's national rail patterns) have no
  shape of their own. So the path is found on the map's own lines: between
  each pair of consecutive stops, the shortest way along the operator's
  drawn track in that mode, else along any operator's. A leg with no drawn
  track between its stops is left out, as the map leaves it out.

  Each leg is searched only in a box around its two stops, so a long
  journey is many small searches rather than one over a national network.
  """

  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs.Cells

  # A station can sit this far from the track drawn past it.
  @station_km 3.0
  # Where a drawn strand stops short of another (one shape ends a few
  # metres from the next), they are joined across a gap up to this long.
  @join_km 0.06
  # How far a leg's search reaches beyond its two stops: this share of the
  # distance between them, and at least this many degrees. Track that
  # bulges further (Dawlish's sea wall, east of Newton Abbot to Exeter) is
  # found by searching again, wider.
  @reach 0.35
  @min_reach 0.05
  @wider 4
  # The path is thinned to this tolerance (degrees, about 1 m).
  @tolerance 0.00001

  @doc """
  The path of a service of `line` (`%{category, agency_name}`) in feed
  `feed_id` calling at `stops` (`{lon, lat}` each, in order; nil for a stop
  that isn't on the map), as a list of strands of `[lon, lat]` points.
  """
  def build(feed_id, line, stops) do
    [line.category]
    |> Cells.lines(feed_id, :full)
    |> along(line.agency_name, stops)
  end

  @doc """
  `build/3` on lines already loaded, in `Transitmaps.Gtfs.Cells.lines/3`'s
  form, preferring the track of `agency`'s lines.
  """
  def along(lines, agency, stops) do
    own =
      Enum.filter(lines, fn {properties, _strands} ->
        Jason.decode!(properties)["agency"] == agency
      end)

    stops
    |> Enum.reject(&is_nil/1)
    |> Enum.dedup()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      Enum.find_value([{own, 1}, {own, @wider}, {lines, 1}, {lines, @wider}], fn {lines, wider} ->
        leg(lines, a, b, wider)
      end)
    end)
    |> join_legs()
    |> Enum.map(fn strand ->
      strand
      |> Enum.map(fn {lon, lat} -> [lon, lat] end)
      |> Geometry.simplify(@tolerance)
      |> Enum.map(fn [lon, lat] -> [Float.round(lon, 6), Float.round(lat, 6)] end)
    end)
  end

  # Consecutive legs meeting at a stop run on as one strand.
  defp join_legs(legs) do
    legs
    |> Enum.reduce([], fn
      nil, strands -> [nil | strands]
      leg, [[_ | _] = strand | strands] -> join(strand, leg, strands)
      leg, strands -> [Enum.reverse(leg) | strands]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.filter(&match?([_, _ | _], &1))
  end

  # `strand` is reversed, so its head is where it ends.
  defp join([last | _] = strand, [last | rest], strands),
    do: [Enum.reverse(rest, strand) | strands]

  defp join(strand, leg, strands), do: [Enum.reverse(leg), strand | strands]

  # -- one leg -----------------------------------------------------------------

  defp leg([], _a, _b, _wider), do: nil

  defp leg(lines, {alon, alat} = a, {blon, blat} = b, wider) do
    reach = max(max(abs(alon - blon), abs(alat - blat)) * @reach, @min_reach) * wider

    box =
      {min(alon, blon) - reach, min(alat, blat) - reach, max(alon, blon) + reach,
       max(alat, blat) + reach}

    stretches =
      for {_properties, strands} <- lines,
          strand <- strands,
          stretch <- Cells.stretches(strand, box),
          do: stretch

    scale = Geometry.km_scale([(alon + blon) / 2, (alat + blat) / 2])
    graph = graph(stretches, scale)

    with from when from != nil <- nearest(graph, a, scale),
         to when to != nil <- nearest(graph, b, scale) do
      shortest(graph, from, to, scale)
    else
      _ -> nil
    end
  end

  # Every point of the stretches, with the points it runs to and how far.
  # Points shared by two stretches are where they meet; a stretch ending
  # just short of another is joined to it.
  defp graph(stretches, scale) do
    {edges, owners} =
      stretches
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {points, index}, {edges, owners} ->
        owners =
          Enum.reduce(points, owners, &Map.update(&2, &1, [index], fn ids -> [index | ids] end))

        edges =
          points
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.reject(fn [p, q] -> p == q end)
          |> Enum.reduce(edges, fn [p, q], edges -> link(edges, p, q, km(p, q, scale)) end)

        {edges, owners}
      end)

    join_dead_ends(edges, owners, scale)
  end

  defp link(edges, p, q, km) do
    edges
    |> Map.update(p, [{q, km}], &[{q, km} | &1])
    |> Map.update(q, [{p, km}], &[{p, km} | &1])
  end

  defp join_dead_ends(edges, owners, scale) do
    grid = Enum.group_by(Map.keys(edges), &cell(&1, scale))

    edges
    |> Enum.filter(fn {_point, next} -> length(next) == 1 end)
    |> Enum.reduce(edges, fn {point, _next}, edges ->
      own = owners[point]
      {cx, cy} = cell(point, scale)

      candidates =
        for dx <- -1..1,
            dy <- -1..1,
            other <- Map.get(grid, {cx + dx, cy + dy}, []),
            Enum.all?(owners[other], &(&1 not in own)),
            distance = km(point, other, scale),
            distance <= @join_km,
            do: {distance, other}

      case candidates do
        [] ->
          edges

        _ ->
          {distance, other} = Enum.min(candidates)
          link(edges, point, other, distance)
      end
    end)
  end

  defp cell({lon, lat}, {kx, ky}), do: {floor(lon * kx / @join_km), floor(lat * ky / @join_km)}

  defp nearest(graph, stop, scale) do
    graph
    |> Map.keys()
    |> Enum.min_by(&km(&1, stop, scale), fn -> nil end)
    |> case do
      nil -> nil
      point -> if km(point, stop, scale) <= @station_km, do: point
    end
  end

  # A* along the graph, guided by the straight distance left to go.
  defp shortest(_graph, from, from, _scale), do: [from]

  defp shortest(graph, from, to, scale) do
    open = :gb_sets.singleton({km(from, to, scale), from})
    search(graph, to, scale, open, %{from => 0.0}, %{}, MapSet.new())
  end

  defp search(graph, to, scale, open, cost, came, closed) do
    if :gb_sets.is_empty(open) do
      nil
    else
      {{_estimate, point}, open} = :gb_sets.take_smallest(open)

      cond do
        point == to ->
          unwind(came, to, [to])

        MapSet.member?(closed, point) ->
          search(graph, to, scale, open, cost, came, closed)

        true ->
          here = cost[point]

          {open, cost, came} =
            Enum.reduce(graph[point], {open, cost, came}, fn {next, km}, {open, cost, came} ->
              through = here + km

              if through < Map.get(cost, next, :infinity) do
                {:gb_sets.add({through + km(next, to, scale), next}, open),
                 Map.put(cost, next, through), Map.put(came, next, point)}
              else
                {open, cost, came}
              end
            end)

          search(graph, to, scale, open, cost, came, MapSet.put(closed, point))
      end
    end
  end

  defp unwind(came, point, path) do
    case came do
      %{^point => previous} -> unwind(came, previous, [previous | path])
      _ -> path
    end
  end

  defp km({lon1, lat1}, {lon2, lat2}, {kx, ky}) do
    dx = (lon1 - lon2) * kx
    dy = (lat1 - lat2) * ky
    :math.sqrt(dx * dx + dy * dy)
  end
end
