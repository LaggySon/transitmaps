defmodule Transitmaps.Realtime.Tfl do
  @moduledoc """
  Live arrivals at TfL's stations — the Tube, DLR, Overground, Elizabeth
  line and trams — from TfL's Unified API, which needs no key for this
  (`TFL_APP_KEY` raises its rate limit). The TfL feed is imported without a
  timetable, so these are its stations' only departures.

  Each station's arrivals are kept for `@fresh_ms`, so a station open in
  many browsers costs TfL one request per half minute. A train's own
  predictions (for its run, `Transitmaps.Services.Tfl`) are kept as long,
  and a line's stop orders for `@sequence_ms`.
  """

  use GenServer

  require Logger

  @api "https://api.tfl.gov.uk"
  @table __MODULE__
  @fresh_ms :timer.seconds(30)
  @sequence_ms :timer.hours(6)
  @timeout_ms :timer.seconds(8)

  # What TfL calls a mode, as the map's modes.
  @categories %{
    "tube" => "metro",
    "dlr" => "metro",
    "overground" => "rail",
    "elizabeth-line" => "rail",
    "tram" => "tram"
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Whether `feed` is TfL's, whose stations' departures come from here."
  def feed?(%{name: "tfl"}), do: true
  def feed?(_feed), do: false

  @doc """
  The trains due at TfL station `stop_id`: `{:ok, arrivals, fetched_at}`,
  each arrival `%{line, category, destination, platform, time}` with
  `time` a Unix time, or `:unavailable`. Trains that end here are left
  out: they depart from nowhere.
  """
  def arrivals("HUB" <> _ = hub_id) do
    with {:ok, [_ | _] = children, _at} <- hub_children(hub_id),
         [_ | _] = fetched <-
           for({:ok, arrivals, at} <- Enum.map(children, &arrivals/1), do: {arrivals, at}) do
      arrivals =
        fetched
        |> Enum.flat_map(&elem(&1, 0))
        |> Enum.uniq_by(fn arrival ->
          if arrival.vehicle_id,
            do: {arrival.line_id, arrival.vehicle_id, arrival.time},
            else: arrival
        end)
        |> Enum.sort_by(& &1.time)

      {:ok, arrivals, fetched |> Enum.map(&elem(&1, 1)) |> Enum.min()}
    else
      _ -> :unavailable
    end
  end

  def arrivals(stop_id) do
    if id?(stop_id) do
      cached_fetch(stop_id, @fresh_ms, fn ->
        with {:ok, body} <- get("/StopPoint/#{stop_id}/Arrivals") do
          {:ok, body |> Enum.flat_map(&arrival(&1, stop_id)) |> Enum.sort_by(& &1.time)}
        end
      end)
    else
      :unavailable
    end
  end

  @doc """
  Where train `vehicle_id` is due next, `{:ok, predictions, fetched_at}`,
  each `%{stop_id, name, line_id, destination_id, platform, time}`, soonest
  first, or `:unavailable`. TfL predicts about half an hour ahead. A
  vehicle id is only unique within a line, so callers match `line_id`.
  """
  def vehicle_arrivals(vehicle_id) do
    if id?(vehicle_id) do
      cached_fetch({:vehicle, vehicle_id}, @fresh_ms, fn ->
        with {:ok, body} <- get("/Vehicle/#{vehicle_id}/Arrivals") do
          {:ok, body |> Enum.flat_map(&prediction/1) |> Enum.sort_by(& &1.time)}
        end
      end)
    else
      :unavailable
    end
  end

  @doc """
  The orders line `line_id`'s trains call at its stops in, both ways and
  every branch, and the station each stop is part of:
  `{:ok, %{orders: [[stop_id]], stations: %{stop_id => station_id}},
  fetched_at}` or `:unavailable`. A station is the stop itself, or at an
  interchange its hub ("HUBPAD"), as the map's stations are imported.
  """
  def route_sequences(line_id) do
    if String.match?(line_id, ~r/^[a-z0-9-]+$/) do
      cached_fetch({:sequences, line_id}, @sequence_ms, fn ->
        with {:ok, %{"orderedLineRoutes" => routes} = body} when is_list(routes) <-
               get("/Line/#{line_id}/Route/Sequence/all") do
          stations =
            for %{"stopPoint" => points} when is_list(points) <-
                  body["stopPointSequences"] || [],
                %{"id" => id} = point <- points,
                into: %{},
                do: {id, point["topMostParentId"] || id}

          {:ok,
           %{orders: for(%{"naptanIds" => [_ | _] = ids} <- routes, do: ids), stations: stations}}
        else
          {:ok, _other} -> :error
          :error -> :error
        end
      end)
    else
      :unavailable
    end
  end

  # An interchange ("HUBPAD", Paddington) has no arrivals of its own; its
  # stations (the Underground's, the Elizabeth line's) have. Bus stops are
  # left out.
  defp hub_children(hub_id) do
    cached_fetch({:hub, hub_id}, @sequence_ms, fn ->
      with {:ok, %{"children" => children}} when is_list(children) <-
             get("/StopPoint/#{hub_id}") do
        {:ok, for(%{"id" => id} <- children, String.match?(id, ~r/^9[14]0G[A-Z0-9]+$/), do: id)}
      else
        {:ok, _other} -> :error
        :error -> :error
      end
    end)
  end

  defp id?(id), do: is_binary(id) and String.match?(id, ~r/^[A-Za-z0-9]+$/)

  # The answer kept under `key` while younger than `fresh_ms`, else `fetch`'s.
  defp cached_fetch(key, fresh_ms, fetch) do
    now = System.monotonic_time(:millisecond)

    case cached(key) do
      {fetched_at, fetched_unix, value} when now - fetched_at < fresh_ms ->
        {:ok, value, fetched_unix}

      _missing_or_old ->
        case fetch.() do
          {:ok, value} ->
            unix = System.os_time(:second)
            cache(key, {now, unix, value})
            {:ok, value, unix}

          :error ->
            :unavailable
        end
    end
  end

  # With the cache off (in tests), every call asks TfL.
  defp cached(key) do
    with true <- enabled?(),
         [{_key, entry}] <- :ets.lookup(@table, key) do
      entry
    else
      _ -> nil
    end
  end

  defp cache(key, entry) do
    if enabled?(), do: :ets.insert(@table, {key, entry})
  end

  defp enabled? do
    Application.get_env(:transitmaps, :realtime_cache, true) and
      :ets.whereis(@table) != :undefined
  end

  # TfL's answer at `path`: a list, or for a line's sequences a map.
  defp get(path) do
    options =
      [
        receive_timeout: @timeout_ms,
        retry: false,
        params: if(key = System.get_env("TFL_APP_KEY"), do: [app_key: key], else: [])
      ]
      |> Keyword.merge(Application.get_env(:transitmaps, __MODULE__, [])[:req_options] || [])

    case Req.get(@api <> path, options) do
      {:ok, %{status: 200, body: body}} when is_list(body) or is_map(body) ->
        {:ok, body}

      other ->
        Logger.info("TfL #{path} not fetched: #{inspect(other, limit: 3)}")
        :error
    end
  rescue
    error ->
      Logger.info("TfL #{path} unreadable: #{Exception.message(error)}")
      :error
  end

  defp arrival(%{"destinationNaptanId" => stop_id}, stop_id), do: []

  defp arrival(prediction, _stop_id) do
    with %{"expectedArrival" => expected, "lineName" => line} when is_binary(line) <- prediction,
         {:ok, time, _offset} <- DateTime.from_iso8601(expected) do
      [
        %{
          line: line,
          line_id: prediction["lineId"],
          stop_id: present(prediction["naptanId"]),
          vehicle_id: present(prediction["vehicleId"]),
          destination_id: present(prediction["destinationNaptanId"]),
          category: Map.get(@categories, prediction["modeName"], "metro"),
          destination: destination(prediction),
          platform: platform(prediction["platformName"]),
          time: DateTime.to_unix(time)
        }
      ]
    else
      _ -> []
    end
  end

  defp prediction(prediction) do
    with %{"naptanId" => stop_id, "expectedArrival" => expected} when is_binary(stop_id) <-
           prediction,
         {:ok, time, _offset} <- DateTime.from_iso8601(expected) do
      [
        %{
          stop_id: stop_id,
          name: station_name(prediction["stationName"]),
          line_id: prediction["lineId"],
          destination_id: present(prediction["destinationNaptanId"]),
          platform: platform(prediction["platformName"]),
          time: DateTime.to_unix(time)
        }
      ]
    else
      _ -> []
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp destination(prediction),
    do: station_name(prediction["destinationName"] || prediction["towards"])

  defp station_name(nil), do: nil

  defp station_name(name),
    do: String.replace(name, ~r/ (Underground|Rail|DLR|Tram) Station$/, "")

  # "Westbound - Platform 1" is platform 1; the Elizabeth line's "B" is
  # already short. Anything else ("Outer Rail") says nothing a passenger
  # would look for on a sign.
  defp platform(nil), do: nil

  defp platform(name) do
    case Regex.run(~r/Platform\s+(\S+)$/i, name) do
      [_, number] -> number
      nil -> if String.length(name) <= 3, do: name
    end
  end
end
