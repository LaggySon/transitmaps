defmodule Transitmaps.Services do
  @moduledoc """
  A trip's whole run, opened from one of a station's departures: every
  stop it calls at on one day, in order, with its times and platforms, and
  live times laid over them where the agency publishes them.

  A departure names its trip with `service` (`Transitmaps.Departures`): the
  feed, the trip, the service day and, for a trip run at a frequency, which
  of its runs (the stop it was listed at and when it leaves there). The
  trip's calls come from its bucket in `trip_calls`
  (`Transitmaps.Gtfs.Timetable.trip/2`).
  """

  import Ecto.Query

  alias Transitmaps.Departures
  alias Transitmaps.Departures.Live
  alias Transitmaps.Gtfs.{Feed, Stop, Timetable}
  alias Transitmaps.Realtime
  alias Transitmaps.Repo

  @doc """
  The run of trip `trip` of feed `feed` on service day `date`, as
  `{:ok, %{line, destination, date, timezone, live, updated_at, cancelled,
  calls}}`, or `{:error, :not_found}`.

  `seq` and `at` (Unix), when given, say when the trip leaves its stop
  `seq`, which picks the run of a trip run at a frequency.

  Each call is `%{name, station, lng, lat, platform, arrival, departure,
  scheduled, time, delay, status, pickup, drop_off}`: `station` is the
  `stops` row to open it on the map (nil if it has none), `arrival` and
  `departure` are the timetable's Unix times, `scheduled` and `time` the
  time the call is shown at (when it leaves, or arrives at the last stop),
  in the timetable and live, and `status` is one of the departures'
  statuses.
  """
  def show(%{feed: feed_id, trip: trip_id, date: %Date{} = date} = service) do
    with %Feed{trip_buckets: count} = feed when is_integer(count) <- Repo.get(Feed, feed_id),
         bucket when is_binary(bucket) <- read_bucket(feed, trip_id),
         %{} = trip <- Timetable.trip(bucket, trip_id) do
      {:ok, present(feed, trip, trip_id, date, service)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp read_bucket(feed, trip_id) do
    bucket = Timetable.trip_bucket(trip_id, feed.trip_buckets)

    from(t in "trip_calls",
      where: t.feed_id == ^feed.id and t.bucket == ^bucket,
      select: t.calls
    )
    |> Repo.one()
  end

  defp present(feed, trip, trip_id, date, service) do
    timezone = Departures.valid_timezone(feed.timezone)

    base =
      Departures.service_day_start(date, timezone) + offset(trip.calls, date, timezone, service)

    stations = stations(feed, trip.calls)
    last = length(trip.calls) - 1

    {update, live, updated_at} = live_update(feed, trip_id, date)

    calls =
      trip.calls
      |> Enum.with_index()
      |> Enum.map(fn {call, index} ->
        present_call(call, index == last, base, update, Map.get(stations, call.station))
      end)

    %{
      line: Departures.present_line(trip.line),
      destination: trip.headsign || List.last(calls)[:name],
      date: Date.to_iso8601(date),
      timezone: timezone,
      live: live,
      updated_at: updated_at,
      cancelled: match?(%{cancelled: true}, update),
      calls: calls
    }
  end

  # A trip run at a frequency is stored once, at its first run's times; the
  # departure it was opened from says how much later this run is.
  defp offset(calls, date, timezone, %{seq: seq, at: at}) when is_integer(at) do
    case Enum.find(calls, &(&1.seq == seq)) do
      %{} = call ->
        case call.departure || call.arrival do
          nil -> 0
          seconds -> at - (Departures.service_day_start(date, timezone) + seconds)
        end

      nil ->
        0
    end
  end

  defp offset(_calls, _date, _timezone, _service), do: 0

  defp stations(feed, calls) do
    station_ids = calls |> Enum.map(& &1.station) |> Enum.uniq()

    from(s in Stop,
      where: s.feed_id == ^feed.id and s.stop_id in ^station_ids,
      select: {s.stop_id, %{id: s.id, name: s.name, lng: s.lon, lat: s.lat}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp live_update(feed, trip_id, date) do
    if Realtime.sources(feed) == [] do
      {nil, "none", nil}
    else
      case Realtime.updates(feed, [trip_id]) do
        {:ok, updates, at} -> {Live.update_for(updates, trip_id, date), "live", at}
        :none -> {nil, "none", nil}
        :unavailable -> {nil, "unavailable", nil}
      end
    end
  end

  defp present_call(call, last?, base, update, station) do
    arrival = call.arrival && base + call.arrival
    departure = call.departure && base + call.departure

    # A call is shown at the time it leaves, but at the last stop at the
    # time it arrives.
    {scheduled, event} =
      if last? or departure == nil,
        do: {arrival || departure, :arrival},
        else: {departure, :departure}

    live =
      if scheduled,
        do:
          Live.delay(update, %{seq: call.seq, stop_id: call.stop_id, scheduled: scheduled}, event)

    {time, delay, status} =
      case live do
        :cancelled -> {scheduled, nil, "cancelled"}
        {:delay, delay} -> {scheduled + delay, delay, Live.status(delay)}
        nil -> {scheduled, nil, "scheduled"}
      end

    %{
      name: (station && station.name) || call.name,
      station: station && station.id,
      lng: station && station.lng,
      lat: station && station.lat,
      platform: call.platform,
      arrival: arrival,
      departure: departure,
      scheduled: scheduled,
      time: time,
      delay: delay,
      status: status,
      pickup: call.pickup,
      drop_off: call.drop_off
    }
  end
end
