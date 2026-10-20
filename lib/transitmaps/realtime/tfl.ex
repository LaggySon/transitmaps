defmodule Transitmaps.Realtime.Tfl do
  @moduledoc """
  Live arrivals at TfL's stations — the Tube, DLR, Overground, Elizabeth
  line and trams — from TfL's Unified API, which needs no key for this
  (`TFL_APP_KEY` raises its rate limit). The TfL feed is imported without a
  timetable, so these are its stations' only departures.

  Each station's arrivals are kept for `@fresh_ms`, so a station open in
  many browsers costs TfL one request per half minute.
  """

  use GenServer

  require Logger

  @api "https://api.tfl.gov.uk"
  @table __MODULE__
  @fresh_ms :timer.seconds(30)
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
  def arrivals(stop_id) do
    now = System.monotonic_time(:millisecond)

    case cached(stop_id) do
      {fetched_at, fetched_unix, arrivals} when now - fetched_at < @fresh_ms ->
        {:ok, arrivals, fetched_unix}

      _missing_or_old ->
        case fetch(stop_id) do
          {:ok, arrivals} ->
            unix = System.os_time(:second)
            cache(stop_id, {now, unix, arrivals})
            {:ok, arrivals, unix}

          :error ->
            :unavailable
        end
    end
  end

  # With the cache off (in tests), every call asks TfL.
  defp cached(stop_id) do
    with true <- enabled?(),
         [{_stop_id, entry}] <- :ets.lookup(@table, stop_id) do
      entry
    else
      _ -> nil
    end
  end

  defp cache(stop_id, entry) do
    if enabled?(), do: :ets.insert(@table, {stop_id, entry})
  end

  defp enabled? do
    Application.get_env(:transitmaps, :realtime_cache, true) and
      :ets.whereis(@table) != :undefined
  end

  defp fetch(stop_id) do
    if String.match?(stop_id, ~r/^[A-Za-z0-9]+$/) do
      options =
        [
          receive_timeout: @timeout_ms,
          retry: false,
          params: if(key = System.get_env("TFL_APP_KEY"), do: [app_key: key], else: [])
        ]
        |> Keyword.merge(Application.get_env(:transitmaps, __MODULE__, [])[:req_options] || [])

      case Req.get(@api <> "/StopPoint/#{stop_id}/Arrivals", options) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, body |> Enum.flat_map(&arrival(&1, stop_id)) |> Enum.sort_by(& &1.time)}

        other ->
          Logger.info("TfL arrivals not fetched for #{stop_id}: #{inspect(other, limit: 3)}")
          :error
      end
    else
      :error
    end
  rescue
    error ->
      Logger.info("TfL arrivals unreadable for #{stop_id}: #{Exception.message(error)}")
      :error
  end

  defp arrival(%{"destinationNaptanId" => stop_id}, stop_id), do: []

  defp arrival(prediction, _stop_id) do
    with %{"expectedArrival" => expected, "lineName" => line} when is_binary(line) <- prediction,
         {:ok, time, _offset} <- DateTime.from_iso8601(expected) do
      [
        %{
          line: line,
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

  defp destination(prediction) do
    name = prediction["destinationName"] || prediction["towards"]
    if name, do: String.replace(name, ~r/ (Underground|Rail|DLR|Tram) Station$/, "")
  end

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
