defmodule Transitmaps.Departures do
  @moduledoc """
  A station's next departures: its timetable (`Transitmaps.Gtfs.Timetable`)
  with live times laid over it where the agency publishes them
  (`Transitmaps.Realtime`), or TfL's live arrivals at its stations
  (`Transitmaps.Realtime.Tfl`).

  The map's station markers merge stops of several agencies, so a request
  names every stop under a marker and gets one list back, in time order.

  A timetable counts each day's times from noon minus 12 hours, local
  time, so a train "at 25:10" on Monday leaves at ten past one on Tuesday
  morning, and the count stays right across a change of clocks.
  """

  import Ecto.Query

  alias Transitmaps.Display.Identity
  alias Transitmaps.Gtfs.{RouteTypes, Stop, Timetable}
  alias Transitmaps.Realtime
  alias Transitmaps.Realtime.Tfl
  alias Transitmaps.Repo

  @max_stops 24
  @max_limit 60
  @default_limit 10

  # A late train is still to come. Its timetable is read this far back when
  # live times could have it running late.
  @late_window 3 * 3600

  # Within a minute of the timetable is on time.
  @on_time 60

  @doc """
  The next departures from stops `stop_ids` (`stops` rows), at most
  `:limit` of them (default #{@default_limit}, at most #{@max_limit}), as
  `%{departures, more, timezone, live, updated_at, timetable}`:

    * `departures` — `%{time, scheduled, delay, status, destination,
      platform, line}`, `time` (when it leaves, live or not) and
      `scheduled` as Unix times and `status` one of `"on_time"`, `"late"`,
      `"early"`, `"cancelled"`, `"scheduled"` (no live time) or `"live"` (a
      live time with no timetable to compare to)
    * `more` — whether later departures were left out
    * `timezone` — the stations' time zone, to show the times in
    * `live` — `"live"` when live times came in, `"unavailable"` when the
      agency's live feed couldn't be reached, `"none"` when it has none
    * `updated_at` — when the live times were fetched (Unix), or nil
    * `timetable` — `"ok"`, `"expired"` (the import is older than its
      timetable runs), or `"none"`

  `:now` sets the time (Unix) the departures follow (in tests).
  """
  def list(stop_ids, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    stops = load(Enum.take(stop_ids, @max_stops))

    results =
      stops
      |> Enum.group_by(fn {_stop, feed, _departures} -> feed end, fn {stop, _feed, departures} ->
        {stop, departures}
      end)
      |> Enum.map(fn {feed, feed_stops} -> feed_departures(feed, feed_stops, now, limit) end)

    departures =
      results
      |> Enum.flat_map(& &1.departures)
      |> drop_doubles()
      |> Enum.filter(&(&1.time >= now or (&1.status == "cancelled" and &1.scheduled >= now)))
      # In timetable order, as a departure board lists them: a late train
      # keeps its place and says how late it is.
      |> Enum.sort_by(&{&1.scheduled || &1.time, &1.time, &1.destination || ""})

    %{
      departures: Enum.take(departures, limit),
      more: length(departures) > limit,
      timezone: timezone(stops),
      live: live_status(results),
      updated_at:
        results |> Enum.map(& &1.updated_at) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end),
      timetable: timetable_status(results)
    }
  end

  defp load([]), do: []

  defp load(stop_ids) do
    from(s in Stop,
      join: f in assoc(s, :feed),
      left_join: d in "stop_departures",
      on: d.stop_id == s.id,
      where: s.id in ^stop_ids,
      select: {s, f, d.departures}
    )
    |> Repo.all()
  end

  # -- one agency's stops -------------------------------------------------------------

  defp feed_departures(feed, stops, now, limit) do
    if Tfl.feed?(feed),
      do: tfl_departures(stops),
      else: timetable_departures(feed, stops, now, limit)
  end

  defp tfl_departures(stops) do
    results = Enum.map(stops, fn {stop, _departures} -> {stop, Tfl.arrivals(stop.stop_id)} end)
    fetched = for {stop, {:ok, arrivals, at}} <- results, do: {stop, arrivals, at}

    departures =
      for {stop, arrivals, _at} <- fetched, arrival <- arrivals do
        %{
          time: arrival.time,
          scheduled: nil,
          delay: nil,
          status: "live",
          destination: arrival.destination,
          platform: arrival.platform,
          line: tfl_line(arrival, stop),
          live?: true
        }
      end

    %{
      departures: departures,
      live: if(fetched == [], do: "unavailable", else: "live"),
      updated_at: fetched |> Enum.map(&elem(&1, 2)) |> Enum.min(fn -> nil end),
      timetable: "none"
    }
  end

  # TfL names the line; the station's own list of lines has its colour.
  defp tfl_line(arrival, stop) do
    name = String.downcase(arrival.line)

    color =
      Enum.find_value(stop.lines, fn line ->
        if String.downcase(line_value(line, :agency) || "") == name or
             String.downcase(line_value(line, :name) || "") == name,
           do: line_value(line, :color)
      end)

    %{
      name: arrival.line,
      agency: "Transport for London",
      category: arrival.category,
      color:
        color || Identity.brand_color(arrival.line, arrival.category) ||
          RouteTypes.default_color(arrival.category)
    }
  end

  defp line_value(line, key), do: Map.get(line, key) || Map.get(line, Atom.to_string(key))

  defp timetable_departures(feed, stops, now, limit) do
    timetables =
      for {_stop, departures} <- stops, departures != nil, do: Timetable.unpack(departures)

    if timetables == [] or feed.timetable_from == nil do
      %{departures: [], live: "none", updated_at: nil, timetable: "none"}
    else
      live? = Realtime.sources(feed) != []
      since = if live?, do: now - @late_window, else: now
      scheduled = feed |> scheduled(timetables, since, now, limit) |> shortlist(now, limit)

      {departures, live, updated_at} =
        if live? do
          case Realtime.updates(feed, Enum.map(scheduled, & &1.trip_id)) do
            {:ok, updates, at} -> {Enum.map(scheduled, &apply_live(&1, updates)), "live", at}
            :none -> {Enum.map(scheduled, &no_live/1), "none", nil}
            :unavailable -> {Enum.map(scheduled, &no_live/1), "unavailable", nil}
          end
        else
          {Enum.map(scheduled, &no_live/1), "none", nil}
        end

      %{
        departures: departures,
        live: live,
        updated_at: updated_at,
        timetable: if(expired?(feed, now), do: "expired", else: "ok")
      }
    end
  end

  # The board lists trains in timetable order, so only the next `limit`
  # still to come can be on it, and the ones already due that may be
  # running late. A few spare cover early running and two agencies listing
  # one train.
  defp shortlist(departures, now, limit) do
    {due, to_come} = Enum.split_with(departures, &(&1.scheduled < now))
    due ++ (to_come |> Enum.sort_by(& &1.scheduled) |> Enum.take(limit + 5))
  end

  # The timetable's departures from `since`, today's and tomorrow's (and
  # yesterday's past midnight), reading on up to a week ahead for a quiet
  # station with fewer than `limit` to come.
  defp scheduled(feed, timetables, since, now, limit) do
    timezone = valid_timezone(feed.timezone)
    today = now |> DateTime.from_unix!() |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

    soon =
      read_days(
        feed,
        timetables,
        timezone,
        Date.range(Date.add(today, -1), Date.add(today, 1)),
        since
      )

    if Enum.count(soon, &(&1.scheduled >= now)) > limit,
      do: soon,
      else:
        soon ++
          read_days(
            feed,
            timetables,
            timezone,
            Date.range(Date.add(today, 2), Date.add(today, 7)),
            since
          )
  end

  defp read_days(feed, timetables, timezone, dates, since) do
    for date <- dates,
        day = Date.diff(date, feed.timetable_from),
        base = service_day_start(date, timezone),
        timetable <- timetables,
        {seconds, {trip_id, line, destination}, seq, stop_id, platform} <-
          Timetable.departures(timetable, day),
        base + seconds >= since do
      %{
        scheduled: base + seconds,
        date: date,
        trip_id: trip_id,
        seq: seq,
        stop_id: stop_id,
        destination: destination,
        platform: platform,
        line: present_line(line)
      }
    end
  end

  defp service_day_start(date, timezone) do
    case DateTime.new(date, ~T[12:00:00], timezone) do
      {:ok, noon} -> DateTime.to_unix(noon) - 12 * 3600
      {:ambiguous, noon, _later} -> DateTime.to_unix(noon) - 12 * 3600
      {:gap, _before, noon} -> DateTime.to_unix(noon) - 12 * 3600
      {:error, _reason} -> date |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix()
    end
  end

  defp expired?(feed, now) do
    timezone = valid_timezone(feed.timezone)
    today = now |> DateTime.from_unix!() |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    Date.diff(today, feed.timetable_from) >= Timetable.days() - 1
  end

  # A route as a departure board names it: its number or name, or, for a
  # train whose route is just its stops ("Bedford - Brighton"), its
  # operator. Colours follow the lines the map draws.
  defp present_line(line) do
    agency = line.agency_name
    category = line.category

    name =
      cond do
        present?(line.short_name) -> line.short_name
        category in ~w(rail intercity) and present?(agency) -> agency
        present?(line.long_name) -> line.long_name
        true -> agency
      end

    %{
      name: name,
      agency: agency,
      category: category,
      color:
        Identity.brand_color(agency, category) || line.color || RouteTypes.default_color(category)
    }
  end

  # -- live times -------------------------------------------------------------------

  defp no_live(departure) do
    departure
    |> Map.merge(%{time: departure.scheduled, delay: nil, status: "scheduled", live?: false})
    |> finish()
  end

  defp apply_live(departure, updates) do
    service_date = Calendar.strftime(departure.date, "%Y%m%d")

    update =
      updates
      |> Map.get(departure.trip_id, [])
      |> Enum.find(&(&1.start_date in [nil, service_date]))

    case live_time(update, departure) do
      :cancelled ->
        departure
        |> Map.merge(%{time: departure.scheduled, delay: nil, status: "cancelled", live?: true})
        |> finish()

      {:delay, delay} ->
        departure
        |> Map.merge(%{
          time: departure.scheduled + delay,
          delay: delay,
          status: delay_status(delay),
          live?: true
        })
        |> finish()

      nil ->
        no_live(departure)
    end
  end

  defp live_time(nil, _departure), do: nil
  defp live_time(%{cancelled: true}, _departure), do: :cancelled

  defp live_time(update, departure) do
    case stop_update(update.stops, departure) do
      %{skipped: true} ->
        :cancelled

      %{no_data: true} ->
        nil

      %{} = stop ->
        event_delay(stop.departure || stop.arrival, departure.scheduled)

      nil ->
        # No word on this stop: the delay at the last stop before it carries
        # on, or else the trip's own.
        earlier_delay(update.stops, departure) || if(update.delay, do: {:delay, update.delay})
    end
  end

  defp stop_update(stops, %{seq: seq, stop_id: stop_id}) do
    Enum.find(stops, &(&1.seq == seq and seq != nil)) ||
      Enum.find(stops, &(&1.seq == nil and &1.stop_id == stop_id))
  end

  defp earlier_delay(stops, %{seq: seq}) do
    stops
    |> Enum.filter(&(&1.seq != nil and &1.seq < seq and not &1.skipped))
    |> Enum.max_by(& &1.seq, fn -> nil end)
    |> case do
      %{departure: {delay, _time}} when is_integer(delay) -> {:delay, delay}
      %{arrival: {delay, _time}} when is_integer(delay) -> {:delay, delay}
      _ -> nil
    end
  end

  defp event_delay({_delay, time}, scheduled) when is_integer(time) and time > 0,
    do: {:delay, time - scheduled}

  defp event_delay({delay, _time}, _scheduled) when is_integer(delay), do: {:delay, delay}
  defp event_delay(_event, _scheduled), do: nil

  defp delay_status(delay) when delay >= @on_time, do: "late"
  defp delay_status(delay) when delay <= -@on_time, do: "early"
  defp delay_status(_delay), do: "on_time"

  defp finish(departure), do: Map.drop(departure, [:date, :trip_id, :seq, :stop_id])

  # -- merging agencies ---------------------------------------------------------------

  # A station two agencies list (King's Cross in National Rail's timetable
  # and in TfL's live arrivals, or one train in two feeds) shows each train
  # once: a line with live arrivals drops its timetable copies, and the same
  # line to the same place at the same time is one departure.
  defp drop_doubles(departures) do
    live_lines =
      for %{status: "live", line: line} <- departures,
          into: MapSet.new(),
          do: String.downcase(line.name)

    departures
    |> Enum.reject(fn departure ->
      departure.status != "live" and
        (MapSet.member?(live_lines, String.downcase(departure.line.name || "")) or
           MapSet.member?(live_lines, String.downcase(departure.line.agency || "")))
    end)
    |> Enum.uniq_by(&{&1.scheduled || &1.time, &1.line.name, &1.destination})
    |> Enum.map(&Map.delete(&1, :live?))
  end

  defp live_status(results) do
    statuses = Enum.map(results, & &1.live)

    cond do
      "live" in statuses -> "live"
      "unavailable" in statuses -> "unavailable"
      true -> "none"
    end
  end

  defp timetable_status(results) do
    statuses = Enum.map(results, & &1.timetable)

    cond do
      "ok" in statuses -> "ok"
      "expired" in statuses -> "expired"
      true -> "none"
    end
  end

  defp timezone(stops) do
    Enum.find_value(stops, "Etc/UTC", fn {_stop, feed, _departures} ->
      if feed.timezone && valid_timezone(feed.timezone) == feed.timezone, do: feed.timezone
    end)
  end

  defp valid_timezone(nil), do: "Etc/UTC"

  defp valid_timezone(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), timezone) do
      {:ok, _} -> timezone
      {:error, _} -> "Etc/UTC"
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
