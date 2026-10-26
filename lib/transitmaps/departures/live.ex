defmodule Transitmaps.Departures.Live do
  @moduledoc """
  Live times laid over a timetable: how late a trip runs at one of its
  stops, from the GTFS Realtime trip updates `Transitmaps.Realtime` fetched.
  Shared by a station's departures and a trip's whole run.
  """

  # Within a minute of the timetable is on time.
  @on_time 60

  @doc "The update for `trip_id` running on `date`, from `updates` (by trip id), or nil."
  def update_for(updates, trip_id, date) do
    service_date = Calendar.strftime(date, "%Y%m%d")

    updates
    |> Map.get(trip_id, [])
    |> Enum.find(&(&1.start_date in [nil, service_date]))
  end

  @doc """
  How the trip in `update` runs at the stop `call` (`%{seq, stop_id,
  scheduled}`): `:cancelled`, `{:delay, seconds}`, or nil without word.
  `event` is the time asked about, `:departure` or `:arrival`; a stop that
  only gives the other is read for it.
  """
  def delay(update, call, event \\ :departure)

  def delay(nil, _call, _event), do: nil
  def delay(%{cancelled: true}, _call, _event), do: :cancelled

  def delay(update, call, event) do
    case stop_update(update.stops, call) do
      %{skipped: true} ->
        :cancelled

      %{no_data: true} ->
        nil

      %{} = stop ->
        times =
          if event == :arrival,
            do: [stop.arrival, stop.departure],
            else: [stop.departure, stop.arrival]

        event_delay(Enum.find(times, & &1), call.scheduled)

      nil ->
        # No word on this stop: the delay at the last stop before it carries
        # on, or else the trip's own.
        earlier_delay(update.stops, call) || if(update.delay, do: {:delay, update.delay})
    end
  end

  @doc "The state word's key for a train running `delay` seconds late."
  def status(delay) when delay >= @on_time, do: "late"
  def status(delay) when delay <= -@on_time, do: "early"
  def status(_delay), do: "on_time"

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
end
