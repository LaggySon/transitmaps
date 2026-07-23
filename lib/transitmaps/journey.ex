defmodule Transitmaps.Journey do
  @moduledoc """
  A schedule-free trip planner over imported GTFS data.

  The map has no timetables — routes are stored as representative geometry and
  each station carries the lines that serve it — so this planner works on
  connectivity, not departure times. Two stations are connected when a single
  line stops at both, and a journey is a chain of such lines. Planning is a
  breadth-first search over that line graph, so the itinerary it returns uses
  the fewest transfers possible.

  `plan/2` loads stations from the database; `plan/3` runs the same search
  over any station list, which keeps the search logic pure and testable.
  """

  alias Transitmaps.Display.Identity
  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.Stop
  alias Transitmaps.Repo

  @typedoc "A single ride: one line between two stations, no change in between."
  @type leg :: %{line: map(), from: struct(), to: struct()}

  @doc """
  Plans a journey between two station-name queries, loading stations from the
  database. See `plan/3` for the return shape.
  """
  def plan(from_query, to_query) when is_binary(from_query) and is_binary(to_query) do
    plan(stations(), from_query, to_query)
  end

  @doc """
  Resolves `from_query` and `to_query` to stations in `stations` and finds the
  fewest-transfer route between them.

  Returns `{:ok, itinerary}` where `itinerary` is a map with `:origin`,
  `:destination`, `:transfers` (an integer) and `:legs` (a list of `t:leg/0`),
  or `{:error, reason}` where `reason` is one of `:blank`, `:same_station`,
  `:no_route`, or `{:not_found, query}`.
  """
  def plan(stations, from_query, to_query)
      when is_list(stations) and is_binary(from_query) and is_binary(to_query) do
    with {:ok, origin} <- find_station(stations, from_query),
         {:ok, destination} <- find_station(stations, to_query) do
      route(stations, origin, destination)
    end
  end

  @doc "All stations, colocated platforms merged, as served to the map."
  def stations do
    Stop
    |> Repo.all()
    |> Gtfs.merge_colocated_stops()
  end

  @doc """
  Finds the station in `stations` that best matches a free-text `query`.

  Prefers an exact name match, then a name starting with the query, then the
  shortest name that contains it (the most specific). Returns `{:ok, station}`,
  `{:error, :blank}` for empty input, or `{:error, {:not_found, query}}`.
  """
  def find_station(stations, query) when is_binary(query) do
    normalized = query |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:error, :blank}

      station = best_match(stations, normalized) ->
        {:ok, station}

      true ->
        {:error, {:not_found, String.trim(query)}}
    end
  end

  defp best_match(stations, normalized) do
    stations
    |> Enum.filter(fn station ->
      station |> station_name() |> String.downcase() |> String.contains?(normalized)
    end)
    |> Enum.sort_by(&match_rank(&1, normalized))
    |> List.first()
  end

  # Lower sorts first: exact name, then prefix match, then shortest containing
  # name. The trailing name breaks ties deterministically.
  defp match_rank(station, normalized) do
    name = station |> station_name() |> String.downcase()

    tier =
      cond do
        name == normalized -> 0
        String.starts_with?(name, normalized) -> 1
        true -> 2
      end

    {tier, String.length(name), name}
  end

  defp route(stations, origin, destination) do
    indexed = Enum.with_index(stations)
    origin_index = index_of(indexed, origin)
    destination_index = index_of(indexed, destination)

    cond do
      origin_index == destination_index ->
        {:error, :same_station}

      true ->
        station_by_index = Map.new(indexed, fn {station, index} -> {index, station} end)
        lines_by_index = Map.new(indexed, fn {station, index} -> {index, line_keys(station)} end)
        indices_by_line = build_line_index(indexed)
        line_meta = build_line_meta(stations)

        search(%{
          origin_index: origin_index,
          destination_index: destination_index,
          station_by_index: station_by_index,
          lines_by_index: lines_by_index,
          indices_by_line: indices_by_line,
          line_meta: line_meta
        })
    end
  end

  # Breadth-first over lines: the frontier is the set of lines reachable with a
  # given number of transfers. `visited` maps each reached line to the line it
  # was boarded from (`nil` for the origin's own lines) and the station index
  # where that boarding happened.
  defp search(ctx) do
    origin_lines = Map.fetch!(ctx.lines_by_index, ctx.origin_index)
    visited = Map.new(origin_lines, fn line -> {line, {nil, ctx.origin_index}} end)

    bfs(:queue.from_list(origin_lines), visited, ctx)
  end

  defp bfs(queue, visited, ctx) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {:error, :no_route}

      {{:value, line}, rest} ->
        if MapSet.member?(Map.fetch!(ctx.indices_by_line, line), ctx.destination_index) do
          {:ok, build_itinerary(line, visited, ctx)}
        else
          {next_queue, next_visited} = expand(line, rest, visited, ctx)
          bfs(next_queue, next_visited, ctx)
        end
    end
  end

  # From every station on `line`, board every not-yet-visited line, recording
  # the transfer station. Those stations are shared by both lines by
  # construction, so each is a valid interchange.
  defp expand(line, queue, visited, ctx) do
    ctx.indices_by_line
    |> Map.fetch!(line)
    |> Enum.reduce({queue, visited}, fn station_index, {queue_acc, visited_acc} ->
      ctx.lines_by_index
      |> Map.fetch!(station_index)
      |> Enum.reduce({queue_acc, visited_acc}, fn next_line, {q, v} ->
        if Map.has_key?(v, next_line) do
          {q, v}
        else
          {:queue.in(next_line, q), Map.put(v, next_line, {line, station_index})}
        end
      end)
    end)
  end

  defp build_itinerary(last_line, visited, ctx) do
    segments = backtrack(visited, last_line, [])

    legs =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {{line, board_index}, position} ->
        alight_index =
          case Enum.at(segments, position + 1) do
            {_next_line, next_board_index} -> next_board_index
            nil -> ctx.destination_index
          end

        %{
          line: Map.fetch!(ctx.line_meta, line),
          from: Map.fetch!(ctx.station_by_index, board_index),
          to: Map.fetch!(ctx.station_by_index, alight_index)
        }
      end)

    %{
      origin: Map.fetch!(ctx.station_by_index, ctx.origin_index),
      destination: Map.fetch!(ctx.station_by_index, ctx.destination_index),
      transfers: length(segments) - 1,
      legs: legs
    }
  end

  # Walks the `visited` chain back to the origin, producing the boarded lines in
  # travel order as `{line, board_station_index}` tuples.
  defp backtrack(visited, line, acc) do
    {from_line, board_index} = Map.fetch!(visited, line)
    acc = [{line, board_index} | acc]

    if is_nil(from_line), do: acc, else: backtrack(visited, from_line, acc)
  end

  defp build_line_index(indexed) do
    indexed
    |> Enum.reduce(%{}, fn {station, index}, acc ->
      Enum.reduce(line_keys(station), acc, fn line, acc2 ->
        Map.update(acc2, line, MapSet.new([index]), &MapSet.put(&1, index))
      end)
    end)
  end

  defp build_line_meta(stations) do
    Enum.reduce(stations, %{}, fn station, acc ->
      station
      |> station_lines()
      |> Enum.reduce(acc, fn line, acc2 ->
        key = line_key(line)
        if Map.has_key?(acc2, key), do: acc2, else: Map.put(acc2, key, present_line(line))
      end)
    end)
  end

  defp index_of(indexed, station) do
    Enum.find_value(indexed, fn {candidate, index} ->
      if candidate == station, do: index
    end)
  end

  defp line_keys(station) do
    station
    |> station_lines()
    |> Enum.map(&line_key/1)
    |> Enum.uniq()
  end

  defp line_key(line), do: {line_value(line, :name), line_value(line, :agency)}

  # Stored line entries may be atom- or string-keyed (structs vs jsonb loaded
  # from the database), so read both shapes — matching `Transitmaps.Gtfs`.
  defp line_value(line, key), do: Map.get(line, key) || Map.get(line, Atom.to_string(key))

  defp present_line(line) do
    agency = line_value(line, :agency)
    category = line_value(line, :category)

    %{
      name: line_value(line, :name),
      agency: agency,
      category: category,
      color: Identity.brand_color(agency, category) || line_value(line, :color)
    }
  end

  defp station_lines(%{lines: lines}) when is_list(lines), do: lines
  defp station_lines(_station), do: []

  defp station_name(station), do: Map.get(station, :name) || ""
end
