defmodule Transitmaps.Gtfs.Timetable do
  @moduledoc """
  Each station's departures, read from a feed's `stop_times.txt` at import.

  A feed lists every trip it will ever run, often months of them, so only
  trips running in the `@days` days from two days before the import are
  kept: weekly refreshes keep that window ahead of today. Each trip carries
  the days it runs as a bit mask counted from the window's first day (the
  feed's `timetable_from`).

  Only stations of these modes get a timetable: a city's bus stops would
  outnumber its stations a hundred to one, and their timetables would
  outweigh the rest of the database.

  A station's departures are stored as one compressed binary
  (`stop_departures`): a table of its trips, lines, destinations, stops
  and platforms, and a packed record per departure. It is read whole when
  a visitor opens the station, so nothing else is ever loaded with it.

  A trip's last stop isn't a departure, and nor is a stop where it only
  sets passengers down. Trips run at a frequency (`frequencies.txt`) are
  expanded into their departures.

  Each trip's whole run is kept too, for a departure clicked open: every
  stop it calls at, in order, with its times and platforms. Trips go into
  buckets by a hash of their id (`trip_bucket/2`), about 256 to a bucket,
  each one compressed binary (`trip_calls`), so a lookup reads one small
  row and a national feed's 400,000 trips aren't 400,000 rows.
  """

  alias Transitmaps.Gtfs.Csv

  @days 64
  @categories ~w(metro tram rail intercity ferry)
  @trips_per_bucket 256

  # A time a stop doesn't give (GTFS lets stops between timepoints leave
  # theirs out).
  @no_time 0xFFFFFFFF

  # A call's flags: nobody boards there, nobody alights there.
  @no_pickup 1
  @no_drop_off 2

  @doc "The modes whose stations keep a timetable."
  def categories, do: @categories

  @doc "How many days a timetable covers."
  def days, do: @days

  @doc """
  Reads the timetable of the feed extracted in `dir` for `routes` (the
  route rows the import keeps), returning `%{timezone, from, stations,
  trips}`, where `stations` maps a station's stop id to its packed
  departures, and `trips` is `%{count, buckets}`, the number of trip
  buckets and each bucket's packed trips (nil without any timetabled
  route).

  Runs in its own process, so the garbage of reading millions of rows goes
  with it. `:today` sets the day the window is counted from (in tests).
  """
  def read(dir, routes, opts \\ []) do
    from = Date.add(Keyword.get(opts, :today, Date.utc_today()), -2)

    fn ->
      try do
        {:ok, build(dir, routes, from)}
      rescue
        error -> {:error, error, __STACKTRACE__}
      end
    end
    |> Task.async()
    |> Task.await(:infinity)
    |> case do
      {:ok, timetable} -> timetable
      {:error, error, stacktrace} -> reraise error, stacktrace
    end
  end

  defp build(dir, routes, from) do
    lines =
      for route <- routes, route.category in @categories, into: %{} do
        {route.route_id,
         Map.take(route, [:route_id, :short_name, :long_name, :agency_name, :category, :color])}
      end

    timezone = read_timezone(dir)

    {stations, trip_buckets} =
      if map_size(lines) == 0 do
        {%{}, nil}
      else
        services = read_services(dir, from)
        trips = read_trips(dir, lines, services)
        stops = read_stops(dir)
        frequencies = read_frequencies(dir, trips)
        scan = scan_stop_times(dir, trips, stops, frequencies)
        by_index = by_index(trips)

        {pack_stations(scan, by_index, lines, stops, frequencies),
         pack_trips(scan, by_index, lines, stops)}
      end

    %{timezone: timezone, from: from, stations: stations, trips: trip_buckets}
  end

  @doc "The bucket trip `trip_id` is kept in, of `count`."
  def trip_bucket(trip_id, count), do: rem(:erlang.crc32(trip_id), count)

  defp bucket_count(trips),
    do: max(1, div(map_size(trips) + @trips_per_bucket - 1, @trips_per_bucket))

  defp by_index(trips) do
    Map.new(trips, fn {trip_id, {index, route, days, headsign}} ->
      {index, {trip_id, route, days, headsign}}
    end)
  end

  # -- reading ------------------------------------------------------------------

  defp read_timezone(dir) do
    dir
    |> Csv.stream("agency.txt")
    |> Enum.find_value(fn row -> presence(row["agency_timezone"]) end)
    |> case do
      nil -> nil
      timezone -> :binary.copy(timezone)
    end
  end

  # service_id -> the window's days it runs, as a bit mask (bit 0 is `from`).
  # Services that don't run in the window are left out.
  defp read_services(dir, from) do
    last = Date.add(from, @days - 1)

    weekly =
      dir
      |> Csv.stream("calendar.txt")
      |> Enum.reduce(%{}, fn row, services ->
        with {:ok, first_day} <- parse_date(row["start_date"]),
             {:ok, last_day} <- parse_date(row["end_date"]) do
          running =
            Enum.map(
              ~w(monday tuesday wednesday thursday friday saturday sunday),
              &(row[&1] == "1")
            )

          mask = weekly_mask(from, max_date(first_day, from), min_date(last_day, last), running)

          if mask == 0,
            do: services,
            else: Map.put(services, :binary.copy(row["service_id"]), mask)
        else
          _ -> services
        end
      end)

    dir
    |> Csv.stream("calendar_dates.txt")
    |> Enum.reduce(weekly, fn row, services ->
      with {:ok, date} <- parse_date(row["date"]),
           day when day in 0..(@days - 1)//1 <- Date.diff(date, from) do
        bit = Bitwise.bsl(1, day)
        service_id = row["service_id"]

        case row["exception_type"] do
          "1" ->
            Map.update(services, :binary.copy(service_id), bit, &Bitwise.bor(&1, bit))

          "2" ->
            case services do
              %{^service_id => mask} ->
                %{services | service_id => Bitwise.band(mask, Bitwise.bnot(bit))}

              _ ->
                services
            end

          _ ->
            services
        end
      else
        _ -> services
      end
    end)
    |> Map.reject(fn {_service_id, mask} -> mask == 0 end)
  end

  defp weekly_mask(from, first_day, last_day, running) do
    if Date.compare(first_day, last_day) == :gt do
      0
    else
      Date.range(first_day, last_day)
      |> Enum.reduce(0, fn date, mask ->
        if Enum.at(running, Date.day_of_week(date) - 1),
          do: Bitwise.bor(mask, Bitwise.bsl(1, Date.diff(date, from))),
          else: mask
      end)
    end
  end

  # trip_id -> {index, route_id, days, headsign}, for the trips of
  # timetabled routes that run in the window. Every trip of a route shares
  # the route table's copy of its id.
  defp read_trips(dir, lines, services) do
    {trips, _count} =
      dir
      |> Csv.stream("trips.txt")
      |> Enum.reduce({%{}, 0}, fn row, {trips, count} ->
        with %{route_id: route_id} <- lines[row["route_id"]],
             {:ok, days} <- Map.fetch(services, row["service_id"]) do
          trip = {count, route_id, days, copy_presence(row["trip_headsign"])}
          {Map.put(trips, :binary.copy(row["trip_id"]), trip), count + 1}
        else
          _ -> {trips, count}
        end
      end)

    trips
  end

  # stop_id -> {station stop_id, platform, name}. A platform belongs to its
  # parent station, the same rule the importer rolls stations up by.
  defp read_stops(dir) do
    rows =
      dir
      |> Csv.stream("stops.txt")
      |> Map.new(fn row ->
        {:binary.copy(row["stop_id"]),
         {copy_presence(row["parent_station"]), copy_presence(row["platform_code"]),
          copy_presence(row["stop_name"])}}
      end)

    Map.new(rows, fn {stop_id, {parent, platform, name}} ->
      station = if parent && Map.has_key?(rows, parent), do: parent, else: stop_id
      {stop_id, {station, platform, name}}
    end)
  end

  # trip index -> [{start, end, headway}] in seconds.
  defp read_frequencies(dir, trips) do
    dir
    |> Csv.stream("frequencies.txt")
    |> Enum.reduce(%{}, fn row, frequencies ->
      with {index, _route, _days, _headsign} <- trips[row["trip_id"]],
           start when is_integer(start) <- parse_time(row["start_time"]),
           finish when is_integer(finish) <- parse_time(row["end_time"]),
           {headway, _} when headway > 0 <- Integer.parse(row["headway_secs"] || "") do
        Map.update(
          frequencies,
          index,
          [{start, finish, headway}],
          &[{start, finish, headway} | &1]
        )
      else
        _ -> frequencies
      end
    end)
  end

  # One pass over stop_times.txt. Each call becomes a 20-byte record under
  # its station: time, trip, sequence, stop and platform (the last two
  # interned), and a 25-byte record under its trip's bucket, with both its
  # times and who may board and alight. Each trip's last stop is noted, so
  # it can be dropped from the station's departures, and so is the first
  # time of a trip run at a frequency.
  defp scan_stop_times(dir, trips, stops, frequencies) do
    initial = %{
      calls: %{},
      trip_calls: %{},
      buckets: bucket_count(trips),
      last: %{},
      first: %{},
      stop_ids: %{},
      platforms: %{nil => 0}
    }

    dir
    |> Csv.stream("stop_times.txt")
    |> Enum.reduce(initial, fn row, acc ->
      with {index, _route, _days, _headsign} <- trips[row["trip_id"]],
           {station, stop_platform, _name} <- stops[row["stop_id"]],
           seq when is_integer(seq) <- parse_int(row["stop_sequence"]) do
        arrival = parse_time(row["arrival_time"])
        departure = parse_time(row["departure_time"])
        time = departure || arrival
        {stop_key, acc} = intern(acc, :stop_ids, row["stop_id"])

        {platform_key, acc} =
          intern(acc, :platforms, presence(row["platform_code"]) || stop_platform)

        acc = note_last(acc, index, seq, stop_key)
        acc = if is_map_key(frequencies, index), do: note_first(acc, index, seq, time), else: acc

        flags =
          if(row["pickup_type"] == "1", do: @no_pickup, else: 0) +
            if(row["drop_off_type"] == "1", do: @no_drop_off, else: 0)

        packed_arrival = arrival || @no_time
        packed_departure = departure || @no_time

        record =
          <<index::32, seq::32, stop_key::32, platform_key::32, packed_arrival::32,
            packed_departure::32, flags::8>>

        bucket = trip_bucket(row["trip_id"], acc.buckets)
        acc = %{acc | trip_calls: append(acc.trip_calls, bucket, record)}

        if time && row["pickup_type"] != "1" do
          %{acc | calls: add_call(acc.calls, station, time, index, seq, stop_key, platform_key)}
        else
          acc
        end
      else
        _ -> acc
      end
    end)
  end

  defp append(binaries, key, record) do
    case binaries do
      %{^key => records} -> %{binaries | key => <<records::binary, record::binary>>}
      _ -> Map.put(binaries, key, record)
    end
  end

  # A station's records are appended to one binary, which grows in place: a
  # list of millions of small binaries took three times the memory.
  defp add_call(calls, station, time, index, seq, stop_key, platform_key) do
    case calls do
      %{^station => records} ->
        %{
          calls
          | station =>
              <<records::binary, time::32, index::32, seq::32, stop_key::32, platform_key::32>>
        }

      _ ->
        Map.put(calls, station, <<time::32, index::32, seq::32, stop_key::32, platform_key::32>>)
    end
  end

  defp note_last(acc, index, seq, stop_key) do
    case acc.last do
      %{^index => {last_seq, _stop_key}} when last_seq >= seq -> acc
      _ -> %{acc | last: Map.put(acc.last, index, {seq, stop_key})}
    end
  end

  defp note_first(acc, _index, _seq, nil), do: acc

  defp note_first(acc, index, seq, time) do
    case acc.first do
      %{^index => {first_seq, _time}} when first_seq <= seq -> acc
      _ -> %{acc | first: Map.put(acc.first, index, {seq, time})}
    end
  end

  defp intern(acc, table, value) do
    values = Map.fetch!(acc, table)

    case values do
      %{^value => key} ->
        {key, acc}

      _ ->
        key = map_size(values)
        {key, Map.put(acc, table, Map.put(values, copy(value), key))}
    end
  end

  defp copy(nil), do: nil
  defp copy(value), do: :binary.copy(value)

  # -- packing --------------------------------------------------------------------

  defp pack_stations(scan, by_index, lines, stops, frequencies) do
    stop_ids = invert(scan.stop_ids)
    platforms = invert(scan.platforms)

    Map.new(scan.calls, fn {station, records} ->
      calls =
        for <<time::32, index::32, seq::32, stop_key::32, platform_key::32 <- records>>,
            not last_stop?(scan.last, index, seq),
            time <- times(time, index, scan.first, frequencies) do
          {time, index, seq, stop_key, platform_key}
        end

      {station, pack(calls, by_index, lines, stops, scan.last, stop_ids, platforms)}
    end)
    |> Map.reject(fn {_station, packed} -> is_nil(packed) end)
  end

  defp last_stop?(last, index, seq) do
    case last do
      %{^index => {last_seq, _stop_key}} -> seq >= last_seq
      _ -> false
    end
  end

  defp times(time, index, first, frequencies) do
    case {frequencies, first} do
      {%{^index => runs}, %{^index => {_first_seq, first_time}}} ->
        offset = time - first_time

        for {start, finish, headway} <- runs,
            departure <- Range.new(start, max(start, finish - 1), headway),
            departure < finish,
            do: departure + offset

      _ ->
        [time]
    end
  end

  defp pack([], _trips, _lines, _stops, _last, _stop_ids, _platforms), do: nil

  defp pack(calls, trips, lines, stops, last, stop_ids, platforms) do
    calls = Enum.sort(calls)
    {trip_keys, trip_table} = local_table(calls, &elem(&1, 1))
    {stop_keys, stop_table} = local_table(calls, &elem(&1, 3))
    {platform_keys, platform_table} = local_table(calls, &elem(&1, 4))

    trip_rows =
      Enum.map(trip_table, fn index ->
        {trip_id, route_id, days, headsign} = Map.fetch!(trips, index)
        {trip_id, route_id, days, headsign || destination(last, stops, stop_ids, index)}
      end)

    {line_keys, line_table} = local_table(trip_rows, &elem(&1, 1))
    {head_keys, head_table} = local_table(trip_rows, &elem(&1, 3))

    trip_tuple =
      trip_rows
      |> Enum.map(fn {trip_id, route_id, days, head} ->
        {trip_id, Map.fetch!(line_keys, route_id), Map.fetch!(head_keys, head), days}
      end)
      |> List.to_tuple()

    records =
      for {time, index, seq, stop_key, platform_key} <- calls, into: <<>> do
        <<time::24, Map.fetch!(trip_keys, index)::24, seq::32,
          Map.fetch!(stop_keys, stop_key)::16, Map.fetch!(platform_keys, platform_key)::16>>
      end

    :erlang.term_to_binary(
      %{
        version: 1,
        records: records,
        trips: trip_tuple,
        lines: line_table |> Enum.map(&Map.fetch!(lines, &1)) |> List.to_tuple(),
        destinations: List.to_tuple(head_table),
        stops: stop_table |> Enum.map(&Map.fetch!(stop_ids, &1)) |> List.to_tuple(),
        platforms: platform_table |> Enum.map(&Map.fetch!(platforms, &1)) |> List.to_tuple()
      },
      compressed: 6
    )
  end

  # Where a trip without a headsign goes: its last stop's station.
  defp destination(last, stops, stop_ids, index) do
    with {_seq, stop_key} <- last[index],
         {station, _platform, name} <- stops[Map.fetch!(stop_ids, stop_key)] do
      station_name(stops, station) || name
    else
      _ -> nil
    end
  end

  # Each bucket's trips: a table of its stops (with their station and the
  # station's name), platforms and lines, and per trip its line, headsign,
  # days and calls, packed 17 bytes a call in stop order.
  defp pack_trips(scan, by_index, lines, stops) do
    stop_ids = invert(scan.stop_ids)
    platforms = invert(scan.platforms)

    buckets =
      Map.new(scan.trip_calls, fn {bucket, records} ->
        {bucket, pack_bucket(records, by_index, lines, stops, stop_ids, platforms)}
      end)

    %{count: scan.buckets, buckets: buckets}
  end

  defp pack_bucket(records, by_index, lines, stops, stop_ids, platforms) do
    calls =
      Enum.sort(
        for <<index::32, seq::32, stop_key::32, platform_key::32, arrival::32, departure::32,
              flags::8 <- records>>,
            do: {index, seq, stop_key, platform_key, arrival, departure, flags}
      )

    {stop_keys, stop_table} = local_table(calls, &elem(&1, 2))
    {platform_keys, platform_table} = local_table(calls, &elem(&1, 3))

    trip_rows =
      calls
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn [{index, _, _, _, _, _, _} | _] = trip_calls ->
        {trip_id, route_id, days, headsign} = Map.fetch!(by_index, index)

        packed =
          for {_index, seq, stop_key, platform_key, arrival, departure, flags} <- trip_calls,
              into: <<>> do
            <<seq::32, Map.fetch!(stop_keys, stop_key)::16,
              Map.fetch!(platform_keys, platform_key)::16, arrival::32, departure::32, flags::8>>
          end

        {trip_id, route_id, days, headsign, packed}
      end)

    {line_keys, line_table} = local_table(trip_rows, &elem(&1, 1))

    :erlang.term_to_binary(
      %{
        version: 1,
        trips:
          Map.new(trip_rows, fn {trip_id, route_id, days, headsign, packed} ->
            {trip_id, {Map.fetch!(line_keys, route_id), headsign, days, packed}}
          end),
        lines: line_table |> Enum.map(&Map.fetch!(lines, &1)) |> List.to_tuple(),
        stops:
          stop_table
          |> Enum.map(fn key ->
            stop_id = Map.fetch!(stop_ids, key)
            {station, _platform, name} = Map.fetch!(stops, stop_id)
            {stop_id, station, station_name(stops, station) || name}
          end)
          |> List.to_tuple(),
        platforms: platform_table |> Enum.map(&Map.fetch!(platforms, &1)) |> List.to_tuple()
      },
      compressed: 6
    )
  end

  defp station_name(stops, station) do
    case stops[station] do
      {_station, _platform, name} when is_binary(name) -> name
      _ -> nil
    end
  end

  # The distinct values `fun` picks out, in order of first use, and each
  # one's position.
  defp local_table(items, fun) do
    values = items |> Enum.map(fun) |> Enum.uniq()
    {values |> Enum.with_index() |> Map.new(), values}
  end

  defp invert(map), do: Map.new(map, fn {value, key} -> {key, value} end)

  # -- reading a station's timetable ----------------------------------------------

  @doc """
  The departures in `packed` on window day `day` (0 is the feed's
  `timetable_from`), as `{seconds, trip, seq, stop, platform}` with
  `seconds` counted from noon minus 12 hours on that day, the way GTFS
  counts them, and the trip as `{trip_id, line, destination}`.
  """
  def departures(%{records: records} = timetable, day) when day in 0..(@days - 1)//1 do
    bit = Bitwise.bsl(1, day)

    for <<time::24, trip_key::24, seq::32, stop_key::16, platform_key::16 <- records>>,
        {trip_id, line_key, head_key, days} = elem(timetable.trips, trip_key),
        Bitwise.band(days, bit) != 0 do
      {time, {trip_id, elem(timetable.lines, line_key), elem(timetable.destinations, head_key)},
       seq, elem(timetable.stops, stop_key), elem(timetable.platforms, platform_key)}
    end
  end

  def departures(_timetable, _day), do: []

  @doc "Unpacks a station's stored departures."
  def unpack(binary), do: :erlang.binary_to_term(binary, [:safe])

  @doc """
  Trip `trip_id` from its bucket's stored binary, or nil when the bucket
  doesn't hold it: `%{line, headsign, days, calls}`, its calls in stop
  order as `%{seq, stop_id, station, name, platform, arrival, departure,
  pickup, drop_off}`, with times in seconds as in `departures/2` (nil where
  the feed gives none) and `pickup`/`drop_off` whether riders may board and
  alight there.
  """
  def trip(bucket, trip_id) do
    %{trips: trips} = bucket = unpack(bucket)

    case trips do
      %{^trip_id => {line_key, headsign, days, packed}} ->
        %{
          line: elem(bucket.lines, line_key),
          headsign: headsign,
          days: days,
          calls:
            for <<seq::32, stop_key::16, platform_key::16, arrival::32, departure::32,
                  flags::8 <- packed>> do
              {stop_id, station, name} = elem(bucket.stops, stop_key)

              %{
                seq: seq,
                stop_id: stop_id,
                station: station,
                name: name,
                platform: elem(bucket.platforms, platform_key),
                arrival: time_or_nil(arrival),
                departure: time_or_nil(departure),
                pickup: Bitwise.band(flags, @no_pickup) == 0,
                drop_off: Bitwise.band(flags, @no_drop_off) == 0
              }
            end
        }

      _ ->
        nil
    end
  end

  defp time_or_nil(@no_time), do: nil
  defp time_or_nil(seconds), do: seconds

  # -- parsing helpers ------------------------------------------------------------

  @doc false
  # "25:10:00" is ten past one the next morning: GTFS counts past midnight.
  def parse_time(nil), do: nil

  def parse_time(value) do
    case String.split(String.trim(value), ":") do
      [h, m, s] ->
        with {h, ""} <- Integer.parse(h),
             {m, ""} <- Integer.parse(m),
             {s, ""} <- Integer.parse(s) do
          h * 3600 + m * 60 + s
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_date(<<y::binary-4, m::binary-2, d::binary-2>>) do
    with {y, ""} <- Integer.parse(y),
         {m, ""} <- Integer.parse(m),
         {d, ""} <- Integer.parse(d) do
      Date.new(y, m, d)
    else
      _ -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
  defp min_date(a, b), do: if(Date.compare(a, b) == :gt, do: b, else: a)

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp copy_presence(value) do
    if value = presence(value), do: :binary.copy(value)
  end
end
