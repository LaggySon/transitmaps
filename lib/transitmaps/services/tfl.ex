defmodule Transitmaps.Services.Tfl do
  @moduledoc """
  A TfL train's run, opened from one of its live arrivals. TfL's feed has
  no timetable, so the run is built live from TfL's API
  (`Transitmaps.Realtime.Tfl`): its stops are the line's stations from the
  one it was opened at to the train's destination, in the order the line
  runs them, and its times are TfL's predictions for that train, which
  reach about half an hour ahead. Stops further on have no time. The DLR
  names no trains, so its runs show only the time at the station they were
  opened from.

  The service's `trip` is `"tfl:<line>:<station>:<destination>:<train>"`
  (`Transitmaps.Departures`).
  """

  import Ecto.Query

  alias Transitmaps.Gtfs.{Cells, Route, Stop}
  alias Transitmaps.Realtime.Tfl
  alias Transitmaps.Repo
  alias Transitmaps.Services.Path

  @timezone "Europe/London"

  @doc "Whether `trip` names a TfL train's run."
  def trip?("tfl:" <> _rest), do: true
  def trip?(_trip), do: false

  @doc "As `Transitmaps.Services.show/1`, for a TfL train."
  def show(feed, %{trip: trip, date: date} = service) do
    with {:ok, run} <- parse(trip),
         %Route{} = route <- route(feed, run.line) do
      sequences = sequences(run.line)
      stop_ids = stop_ids(run, sequences)
      stations = stations(feed, stop_ids, sequences)
      {predictions, live, updated_at} = predictions(run)

      calls =
        Enum.map(stop_ids, fn stop_id ->
          prediction = Map.get(predictions, stop_id)
          time = (prediction && prediction.time) || (stop_id == run.origin && service[:at]) || nil
          call(stop_id, Map.get(stations, stop_id), prediction, time)
        end)

      {:ok,
       %{
         line: line(route),
         destination: List.last(calls).name,
         date: Date.to_iso8601(date),
         timezone: @timezone,
         live: live,
         updated_at: updated_at,
         cancelled: false,
         calls: calls
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "As `Transitmaps.Services.path/1`, for a TfL train."
  def path(feed, %{trip: trip}) do
    with {:ok, run} <- parse(trip),
         %Route{} = route <- route(feed, run.line) do
      sequences = sequences(run.line)
      stop_ids = stop_ids(run, sequences)
      stations = stations(feed, stop_ids, sequences)

      points =
        stop_ids
        |> Enum.map(&Map.get(stations, &1))
        |> Enum.filter(&match?(%{lng: lng, lat: lat} when is_number(lng) and is_number(lat), &1))

      features =
        case track(feed, route, Enum.map(points, &{&1.lng, &1.lat})) do
          [] ->
            []

          strands ->
            [
              %{
                type: "Feature",
                geometry: %{type: "MultiLineString", coordinates: strands},
                properties: line(route)
              }
            ]
        end

      last = length(points) - 1

      stops =
        points
        |> Enum.with_index()
        |> Enum.map(fn {station, index} ->
          %{
            type: "Feature",
            geometry: %{type: "Point", coordinates: [station.lng, station.lat]},
            properties: %{name: station.name, terminus: index in [0, last]}
          }
        end)

      {:ok, %{type: "FeatureCollection", features: features, stops: stops}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse("tfl:" <> rest) do
    with [line, origin, destination, train] <- String.split(rest, ":"),
         true <- String.match?(line, ~r/^[a-z0-9-]+$/),
         true <- Enum.all?([origin, destination], &String.match?(&1, ~r/^[A-Za-z0-9]+$/)),
         true <- String.match?(train, ~r/^[A-Za-z0-9]*$/) do
      {:ok,
       %{
         line: line,
         origin: origin,
         destination: destination,
         train: if(train == "", do: nil, else: train)
       }}
    else
      _ -> :error
    end
  end

  defp parse(_trip), do: :error

  defp route(feed, line_id),
    do:
      Repo.one(from r in Route, where: r.feed_id == ^feed.id and r.route_id == ^"tfl:#{line_id}")

  # The line's board name and colour, as its departures show them.
  defp line(route) do
    %{
      name: route.short_name || route.long_name,
      agency: route.agency_name,
      category: route.category,
      color: route.color
    }
  end

  # The stations from `origin` to `destination` on the shortest of the
  # line's stop orders that runs between them (a branch, or a short
  # working). Without one, just the two.
  defp stop_ids(%{origin: origin, destination: destination}, %{orders: orders}) do
    orders
    |> Enum.flat_map(fn sequence ->
      with from when is_integer(from) <- Enum.find_index(sequence, &(&1 == origin)),
           offset when is_integer(offset) <-
             sequence |> Enum.drop(from + 1) |> Enum.find_index(&(&1 == destination)) do
        [Enum.slice(sequence, from, offset + 2)]
      else
        _ -> []
      end
    end)
    |> Enum.min_by(&length/1, fn -> Enum.uniq([origin, destination]) end)
  end

  defp sequences(line) do
    case Tfl.route_sequences(line) do
      {:ok, sequences, _at} -> sequences
      :unavailable -> %{orders: [], stations: %{}}
    end
  end

  # TfL's predictions for the train, by station. Another line's train can
  # share its number, so only this line's count, and only those heading
  # where it is.
  defp predictions(%{train: nil}), do: {%{}, "none", nil}

  defp predictions(%{train: train, line: line, destination: destination}) do
    case Tfl.vehicle_arrivals(train) do
      {:ok, predictions, at} ->
        by_stop =
          predictions
          |> Enum.filter(&(&1.line_id == line and &1.destination_id in [destination, nil]))
          |> Enum.reduce(%{}, fn prediction, acc ->
            Map.put_new(acc, prediction.stop_id, prediction)
          end)

        {by_stop, "live", at}

      :unavailable ->
        {%{}, "unavailable", nil}
    end
  end

  # The map's station for each stop: at an interchange, its hub.
  defp stations(feed, stop_ids, %{stations: parents}) do
    station_ids = Map.new(stop_ids, &{&1, Map.get(parents, &1, &1)})

    rows =
      from(s in Stop,
        where: s.feed_id == ^feed.id and s.stop_id in ^Enum.uniq(Map.values(station_ids)),
        select: {s.stop_id, %{id: s.id, name: s.name, lng: s.lon, lat: s.lat}}
      )
      |> Repo.all()
      |> Map.new()

    for {stop_id, station_id} <- station_ids,
        row = rows[station_id],
        into: %{},
        do: {stop_id, row}
  end

  defp call(stop_id, station, prediction, time) do
    %{
      name: (station && station.name) || (prediction && prediction.name) || stop_id,
      station: station && station.id,
      lng: station && station.lng,
      lat: station && station.lat,
      platform: prediction && prediction.platform,
      arrival: time,
      departure: time,
      scheduled: time,
      time: time,
      delay: nil,
      status: if(time, do: "live", else: "scheduled"),
      pickup: true,
      drop_off: true
    }
  end

  # The track along the line's own drawing where it joins the stops, else
  # along any TfL line in its mode.
  defp track(feed, route, stops) do
    lines = Cells.lines([route.category], feed.id, :full)
    name = route.short_name

    own =
      Enum.filter(lines, fn {properties, _strands} ->
        Jason.decode!(properties)["name"] == name
      end)

    case Path.along(own, route.agency_name, stops) do
      [] ->
        Path.build(feed.id, %{category: route.category, agency_name: route.agency_name}, stops)

      strands ->
        strands
    end
  end
end
