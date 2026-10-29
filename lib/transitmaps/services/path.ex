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
  # Track drawn this close to a station may all be its own: at a junction
  # the nearest strand can be the wrong branch, so the leg may start and
  # end on any of them, whichever joins the stops by the shortest way.
  @snap_km 0.15
  # Stepping off the track to a stop counts this many times its length,
  # so a leg runs from beside one stop to beside the next rather than
  # meeting both from one point between two stations close together.
  @snap_weight 3
  # Coarsely drawn track (a long straight between two points) is given a
  # point at least this often, so stops and other strands can meet it
  # along its length and not only at its ends; a very long straight (a
  # train drawn station to station) gets at most `@max_steps`.
  @step_km 0.025
  @max_steps 40
  # Where a drawn strand stops short of another (one shape ends a few
  # metres from the next), they are joined across a gap up to this long.
  @join_km 0.06
  # Strands that run alongside this close without sharing a point (two
  # shapes of the same track, drawn from different sources or stitched out
  # and back) are joined where they do. Strands that cross are not: on a
  # flat map, one line's tunnel crosses another's without meeting it.
  @touch_km 0.008
  @parallel_cos 0.9
  # A leg longer than this many times the straight distance between its
  # stops, plus a margin, has gone astray along other track: it is left
  # out rather than drawn the long way round.
  @detour 3
  @detour_margin_km 0.5
  # How far a leg's search reaches beyond its two stops: this share of the
  # distance between them, and at least `@min_reach` degrees, which keeps
  # a short hop between city stations a small search. Track that bulges
  # further (Dawlish's sea wall, east of Newton Abbot to Exeter) is found
  # by searching again, `@wider` times as far and at least
  # `@wide_min_reach` before that.
  @reach 0.35
  @min_reach 0.01
  @wide_min_reach 0.05
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

  # Consecutive legs meeting at a stop run on as one strand: one may end
  # on one track beside a station and the next start on another, a few
  # metres off, and the strand runs through the station between them.
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

  defp join([{lon, lat} = last | _] = strand, [first | _] = leg, strands) do
    if km(last, first, Geometry.km_scale([lon, lat])) <= 2 * @snap_km,
      do: [Enum.reverse(leg, strand) | strands],
      else: [Enum.reverse(leg), strand | strands]
  end

  # -- one leg -----------------------------------------------------------------

  defp leg([], _a, _b, _wider), do: nil

  defp leg(lines, {alon, alat} = a, {blon, blat} = b, wider) do
    span = max(abs(alon - blon), abs(alat - blat)) * @reach

    reach =
      if wider == 1,
        do: max(span, @min_reach),
        else: max(span, @wide_min_reach) * wider

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

    with [_ | _] = starts <- snaps(graph, a, scale),
         [_ | _] = ends <- snaps(graph, b, scale),
         [_ | _] = path <- shortest(graph, starts, Map.new(ends), b, scale),
         true <- length_km(path, scale) <= km(a, b, scale) * @detour + @detour_margin_km do
      path
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
      |> Enum.map(&densify(&1, scale))
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

    headings = Map.new(edges, fn {point, next} -> {point, heading(point, next, scale)} end)

    edges
    |> join_dead_ends(owners, scale)
    |> join_touching(owners, headings, scale)
  end

  # The way the track runs at `point`, as a unit vector: from one of its
  # neighbours to the other, or towards its only one.
  defp heading(point, next, {kx, ky}) do
    {{x1, y1}, {x2, y2}} =
      case next do
        [{only, _km}] -> {only, point}
        [{a, _}, {b, _} | _] -> {a, b}
      end

    dx = (x2 - x1) * kx
    dy = (y2 - y1) * ky
    length = :math.sqrt(dx * dx + dy * dy)
    if length > 0, do: {dx / length, dy / length}, else: {0.0, 0.0}
  end

  defp parallel?({ax, ay}, {bx, by}), do: abs(ax * bx + ay * by) >= @parallel_cos

  defp densify([first | _] = points, scale) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{plon, plat} = p, {qlon, qlat} = q] ->
      steps = min(ceil(km(p, q, scale) / @step_km), @max_steps)

      for step <- 1..max(steps, 1)//1 do
        if step == steps or steps <= 1,
          do: q,
          else: {plon + (qlon - plon) * step / steps, plat + (qlat - plat) * step / steps}
      end
    end)
    |> then(&[first | &1])
  end

  defp link(edges, p, q, km) do
    edges
    |> Map.update(p, [{q, km}], &[{q, km} | &1])
    |> Map.update(q, [{p, km}], &[{p, km} | &1])
  end

  # A strand's loose end is joined to the nearest point of each other
  # strand within reach: joined only to the nearest of all, it would often
  # meet a strand it already runs into and leave the one beyond unreached.
  defp join_dead_ends(edges, owners, scale) do
    points = for {point, [_only]} <- edges, do: point
    join_near(edges, points, owners, scale, @join_km, fn _point, _other -> true end)
  end

  defp join_touching(edges, owners, headings, scale) do
    alongside? = fn point, other -> parallel?(headings[point], headings[other]) end
    join_near(edges, Map.keys(edges), owners, scale, @touch_km, alongside?)
  end

  defp join_near(edges, points, owners, scale, reach, joinable?) do
    grid = Enum.group_by(Map.keys(edges), &cell(&1, scale, reach))

    Enum.reduce(points, edges, fn point, acc ->
      own = owners[point]
      {cx, cy} = cell(point, scale, reach)

      for dx <- -1..1,
          dy <- -1..1,
          other <- Map.get(grid, {cx + dx, cy + dy}, []),
          Enum.all?(owners[other], &(&1 not in own)),
          distance = km(point, other, scale),
          distance <= reach,
          joinable?.(point, other) do
        {distance, other}
      end
      |> Enum.group_by(fn {_distance, other} -> owners[other] end)
      |> Enum.reduce(acc, fn {_strand, candidates}, acc ->
        {distance, other} = Enum.min(candidates)
        link(acc, point, other, distance)
      end)
    end)
  end

  defp cell({lon, lat}, {kx, ky}, size), do: {floor(lon * kx / size), floor(lat * ky / size)}

  # Where a leg can start or end at `stop`: every point of track within
  # `@snap_km`, else the nearest within `@station_km`, each with the
  # (weighted) cost of stepping off it to the stop.
  defp snaps(graph, stop, scale) do
    distances = Enum.map(Map.keys(graph), &{&1, km(&1, stop, scale)})

    near =
      case Enum.filter(distances, fn {_point, distance} -> distance <= @snap_km end) do
        [] ->
          case Enum.min_by(distances, &elem(&1, 1), fn -> nil end) do
            {_point, distance} = nearest when distance <= @station_km -> [nearest]
            _ -> []
          end

        near ->
          near
      end

    Enum.map(near, fn {point, distance} -> {point, distance * @snap_weight} end)
  end

  # A* along the graph from any of `starts` to any of `ends` (each with
  # its distance from its stop, counted in), guided by the straight
  # distance left to `stop`.
  defp shortest(graph, starts, ends, stop, scale) do
    open =
      Enum.reduce(starts, :gb_sets.new(), fn {point, distance}, open ->
        :gb_sets.add({distance + km(point, stop, scale), point}, open)
      end)

    cost = Map.new(starts)
    search(graph, ends, stop, scale, open, cost, %{}, MapSet.new())
  end

  defp search(graph, ends, stop, scale, open, cost, came, closed) do
    if :gb_sets.is_empty(open) do
      nil
    else
      {{_estimate, point}, open} = :gb_sets.take_smallest(open)

      cond do
        point == :end ->
          unwind(came, came[:end], [came[:end]])

        MapSet.member?(closed, point) ->
          search(graph, ends, stop, scale, open, cost, came, closed)

        true ->
          here = cost[point]

          # A point the leg can end at offers the way off the track to the
          # stop as one more step.
          steps =
            case ends do
              %{^point => distance} -> [{:end, distance} | graph[point]]
              _ -> graph[point]
            end

          {open, cost, came} =
            Enum.reduce(steps, {open, cost, came}, fn {next, km}, {open, cost, came} ->
              through = here + km

              if through < Map.get(cost, next, :infinity) do
                estimate = if next == :end, do: through, else: through + km(next, stop, scale)

                {:gb_sets.add({estimate, next}, open), Map.put(cost, next, through),
                 Map.put(came, next, point)}
              else
                {open, cost, came}
              end
            end)

          search(graph, ends, stop, scale, open, cost, came, MapSet.put(closed, point))
      end
    end
  end

  defp unwind(came, point, path) do
    case came do
      %{^point => previous} -> unwind(came, previous, [previous | path])
      _ -> path
    end
  end

  defp length_km(path, scale) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [p, q], sum -> sum + km(p, q, scale) end)
  end

  defp km({lon1, lat1}, {lon2, lat2}, {kx, ky}) do
    dx = (lon1 - lon2) * kx
    dy = (lat1 - lat2) * ky
    :math.sqrt(dx * dx + dy * dy)
  end
end
