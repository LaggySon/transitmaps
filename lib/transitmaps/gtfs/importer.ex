defmodule Transitmaps.Gtfs.Importer do
  @moduledoc """
  Imports a GTFS feed (zip URL or local path) into the database.

  The importer is intentionally schedule-free: it keeps only what the map
  needs — routes with a representative geometry per service pattern, and
  stations tagged with the categories of the routes that serve them.

  Lines are drawn only from the feed's `shapes.txt`, and only from shapes
  that follow the track: some feeds' shapes merely join each route's stops
  (see `Transitmaps.Geometry.stop_to_stop?/1`). A feed with nothing else
  to draw, or whose shapes mostly join stops, is refused: its stops joined
  by straight lines would cut across cities and countries.

  Large files (`stop_times.txt`, `shapes.txt`) are streamed, never loaded
  wholesale. Geometries are simplified at import time so API payloads stay
  small.
  """

  require Logger

  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs.{Csv, RouteTypes}
  alias Transitmaps.Repo

  @cache_dir Path.join(["priv", "gtfs_cache"])

  # Most-used service patterns kept per route; more adds branches, but too
  # many just re-draws the same track and bloats memory/payloads.
  @max_shapes_per_route 6

  # ~2.5 m at UK latitudes. Keeping close-zoom geometry this precise avoids
  # long angular chords through bends while remaining compact enough to serve
  # country-wide route collections.
  @simplify_tolerance 0.000025

  @insert_batch 500

  # What the agency list calls the hand-curated feeds. Any other feed is
  # labelled by its name unless the caller passes a label.
  @known_labels %{
    "gb-rail" => "National Rail",
    "tfl" => "Transport for London",
    "amtrak" => "Amtrak",
    "mbta-commuter" => "MBTA Commuter Rail",
    "mbta-rapid" => "MBTA Subway",
    "metro-north" => "Metro-North Railroad",
    "nyc-subway" => "NYC Subway",
    "nj-transit-rail" => "NJ Transit Rail",
    "path" => "PATH",
    "septa-regional-rail" => "SEPTA Regional Rail",
    "septa-rapid" => "SEPTA Metro",
    "marc" => "MARC Train",
    "baltimore-metro" => "Baltimore Metro SubwayLink",
    "baltimore-light-rail" => "Baltimore Light RailLink",
    "wmata-rapid" => "WMATA Metrorail"
  }

  @doc """
  Imports feed `name` from `source` (a zip URL or local path), replacing any
  previous import under that name. Returns `{:error, :no_shapes}`, and
  removes any previous import, when the feed has no route shapes that
  follow the track.

  Options:

    * `:feed` — extra feed attributes to store (`country_code`,
      `subdivision`, `catalog_id`)
    * `:max_bytes` — refuse a download larger than this
    * `:keep_download` — keep the downloaded zip in the cache (default
      `true`); on-demand region imports throw theirs away
    * `:invalidate` — mark cached GeoJSON stale afterwards (default
      `true`); a region import does it once when all its feeds are in
  """
  def import_feed(name, source, opts \\ []) do
    dir = fetch_and_extract!(name, source, opts)

    try do
      routes = read_routes(dir, read_agencies(dir))
      trip_index = index_trips(dir, routes)
      shape_geometries = read_selected_shapes(dir, trip_index.selected_shape_ids)

      route_rows =
        build_route_rows(routes, trip_index, shape_geometries)
        |> normalize_feed_categories(name)
        |> Enum.map(&amtrak_as_intercity/1)

      if drawable?(route_rows) do
        stations = read_stations(dir, scan_stop_times(dir, trip_index))

        persist_rows(name, source, route_rows, station_rows(stations, route_rows), opts)
      else
        remove_feed(name)
        {:error, :no_shapes}
      end
    after
      File.rm_rf!(dir)
    end
  end

  # A feed is drawn when shapes that follow the track outweigh shapes that
  # only join stops. Where most of its shapes are straight hops, the few
  # that pass the test are short or straight hops too (Germany's
  # long-distance feed keeps a 3 km border crossing, BreizhGo's coaches
  # hop 12 km at a time), so the whole feed is untrustworthy.
  defp drawable?(route_rows) do
    {drawn_km, stop_to_stop_km} =
      Enum.reduce(route_rows, {0.0, 0.0}, fn route, {drawn, dropped} ->
        if route.geometry,
          do: {drawn + route.shape_km, dropped},
          else: {drawn, dropped + route.shape_km}
      end)

    drawn_km > 0 and drawn_km >= stop_to_stop_km
  end

  # A feed without shapes that follow the track can only be drawn by
  # joining its stops with straight lines, which cut across cities and
  # countries, so it isn't supported. An earlier import of it goes too.
  defp remove_feed(name) do
    import Ecto.Query, only: [from: 2]

    {removed, _} = Repo.delete_all(from f in Transitmaps.Gtfs.Feed, where: f.name == ^name)
    if removed > 0, do: Transitmaps.Gtfs.GeoJsonCache.invalidate()
  end

  # Amtrak files its long-distance trains as ordinary rail, in its own feed
  # and in the regional feeds that carry some of its services.
  defp amtrak_as_intercity(route) do
    if String.contains?(route.agency_name || "", "Amtrak"),
      do: Map.put(route, :category, "intercity"),
      else: route
  end

  defp normalize_feed_categories(routes, name)
       when name in ~w(mbta-commuter septa-regional-rail) do
    Enum.filter(routes, &(&1.category == "rail"))
  end

  # PATH reports itself as conventional rail in GTFS even though it operates
  # as the New York region's high-frequency rapid-transit system.
  defp normalize_feed_categories(routes, "path") do
    Enum.map(routes, &Map.put(&1, :category, "metro"))
  end

  defp normalize_feed_categories(routes, name)
       when name in ~w(mbta-rapid nyc-subway septa-rapid baltimore-metro baltimore-light-rail) do
    Enum.filter(routes, &(&1.category in ~w(metro tram)))
  end

  defp normalize_feed_categories(routes, _name), do: routes

  # -- download / extract ----------------------------------------------------

  defp fetch_and_extract!(name, source, opts) do
    zip_path = ensure_local_zip!(name, source)
    extract_dir = Path.join(System.tmp_dir!(), "gtfs_#{name}")

    try do
      check_size!(zip_path, opts[:max_bytes])

      File.rm_rf!(extract_dir)
      File.mkdir_p!(extract_dir)

      {:ok, _files} =
        :zip.extract(String.to_charlist(zip_path), cwd: String.to_charlist(extract_dir))
    after
      if opts[:keep_download] == false and zip_path != source, do: File.rm(zip_path)
    end

    extract_nested_feed!(extract_dir, name)

    Logger.info("Extracted #{name} to #{extract_dir}")
    extract_dir
  end

  defp extract_nested_feed!(dir, name) do
    if not File.exists?(Path.join(dir, "routes.txt")) do
      nested_zips = Path.wildcard(Path.join(dir, "*.zip"))

      selected =
        case name do
          "septa-regional-rail" ->
            Path.join(dir, "google_rail.zip")

          "septa-rapid" ->
            Path.join(dir, "google_bus.zip")

          _ ->
            List.first(nested_zips)
        end

      if selected && File.exists?(selected) do
        {:ok, _files} =
          :zip.extract(String.to_charlist(selected), cwd: String.to_charlist(dir))
      end
    end
  end

  defp check_size!(_zip_path, nil), do: :ok

  defp check_size!(zip_path, max_bytes) do
    %{size: size} = File.stat!(zip_path)

    if size > max_bytes do
      raise "#{Path.basename(zip_path)} is #{div(size, 1_048_576)} MB, over the import limit"
    end
  end

  defp ensure_local_zip!(name, source) do
    if String.starts_with?(source, "http") do
      File.mkdir_p!(@cache_dir)
      zip_path = Path.join(@cache_dir, "#{name}.zip")

      Logger.info("Downloading #{source}")

      request_options =
        if name == "wmata-rapid" && String.contains?(source, "api.wmata.com") do
          [headers: [{"api_key", System.fetch_env!("WMATA_API_KEY")}]]
        else
          []
        end

      %{status: 200} =
        Req.get!(source, [into: File.stream!(zip_path), raw: true] ++ request_options)

      zip_path
    else
      source
    end
  end

  # -- routes & agencies -----------------------------------------------------

  defp read_agencies(dir) do
    dir
    |> Csv.stream("agency.txt")
    |> Map.new(fn row -> {row["agency_id"] || "", row["agency_name"]} end)
  end

  defp read_routes(dir, agencies) do
    dir
    |> Csv.stream("routes.txt")
    |> Map.new(fn row ->
      route_type = parse_int(row["route_type"], 3)
      route_id = :binary.copy(row["route_id"])

      {route_id,
       %{
         route_id: route_id,
         agency_name: agencies[row["agency_id"] || ""] || row["agency_id"],
         short_name: presence(row["route_short_name"]),
         long_name: presence(row["route_long_name"]),
         route_type: route_type,
         category: RouteTypes.category(route_type),
         color: normalize_color(row["route_color"]),
         text_color: normalize_color(row["route_text_color"])
       }}
    end)
  end

  # -- trips -----------------------------------------------------------------

  # One pass over trips.txt yields everything later passes need:
  #   * trip_id -> route_id (to tag stops with route categories)
  #   * the most-used shape_ids per route (its display geometry)
  #
  # A national feed runs millions of trips, so this is the import's biggest
  # table. Each trip id is copied out of the CSV line it was parsed from
  # (a parsed field otherwise keeps its whole line alive), every trip of a
  # route shares routes.txt's one copy of the route id, and trips of routes
  # the feed doesn't define are skipped: nothing could list or draw them.
  defp index_trips(dir, routes) do
    initial = %{trip_to_route: %{}, shape_counts: %{}}

    index =
      dir
      |> Csv.stream("trips.txt")
      |> Enum.reduce(initial, fn row, acc ->
        case routes[row["route_id"]] do
          nil ->
            acc

          %{route_id: route_id} ->
            acc = put_in(acc.trip_to_route[:binary.copy(row["trip_id"])], route_id)

            case presence(row["shape_id"]) do
              nil -> acc
              shape_id -> update_in(acc.shape_counts[route_id], &increment_count(&1, shape_id))
            end
        end
      end)

    selected = select_shapes_per_route(index.shape_counts)

    %{
      trip_to_route: index.trip_to_route,
      route_shape_ids: selected,
      selected_shape_ids: selected |> Map.values() |> List.flatten() |> MapSet.new()
    }
  end

  defp increment_count(nil, shape_id), do: %{:binary.copy(shape_id) => 1}

  defp increment_count(counts, shape_id) do
    case counts do
      %{^shape_id => count} -> %{counts | shape_id => count + 1}
      _ -> Map.put(counts, :binary.copy(shape_id), 1)
    end
  end

  defp select_shapes_per_route(shape_counts) do
    Map.new(shape_counts, fn {route_id, counts} ->
      top_shapes =
        counts
        |> Enum.sort_by(fn {_shape_id, count} -> -count end)
        |> Enum.take(@max_shapes_per_route)
        |> Enum.map(fn {shape_id, _count} -> shape_id end)

      {route_id, top_shapes}
    end)
  end

  # -- shapes ------------------------------------------------------------------

  # shapes.txt holds every point of every shape (tens of millions of rows in
  # a national feed), so each wanted shape is simplified as soon as its rows
  # end and only the simplified line is kept. Feeds list a shape's rows
  # together, but GTFS doesn't promise it: a shape whose rows turn up again
  # after another wanted shape's is set aside and read whole in a second
  # pass, so its line comes out the same either way.
  #
  # The reading runs in its own short-lived process, so the garbage of
  # parsing gigabytes of rows goes with it, and each line it keeps is packed
  # (see `pack_line/1`), so passing them back copies nothing. A file that
  # can't be read raises here, in the caller, as it would without the task,
  # so the import is marked failed rather than taking its worker down.
  @doc false
  def read_selected_shapes(dir, selected_shape_ids) do
    fn ->
      try do
        {lines, scattered} = read_grouped_shapes(dir, selected_shape_ids)

        if MapSet.size(scattered) == 0,
          do: {:ok, lines},
          else: {:ok, Map.merge(lines, read_whole_shapes(dir, scattered))}
      rescue
        error -> {:error, error, __STACKTRACE__}
      end
    end
    |> Task.async()
    |> Task.await(:infinity)
    |> case do
      {:ok, lines} -> lines
      {:error, error, stacktrace} -> reraise error, stacktrace
    end
  end

  defp read_grouped_shapes(dir, selected_shape_ids) do
    {lines, scattered, current} =
      dir
      |> Csv.stream("shapes.txt")
      |> Stream.filter(&MapSet.member?(selected_shape_ids, &1["shape_id"]))
      |> Enum.reduce({%{}, MapSet.new(), nil}, fn row, {lines, scattered, current} ->
        shape_id = row["shape_id"]

        case current do
          {^shape_id, points} ->
            {lines, scattered, {shape_id, [shape_point(row) | points]}}

          _ ->
            {lines, scattered} = finish_shape(current, lines, scattered)
            {lines, scattered, {:binary.copy(shape_id), [shape_point(row)]}}
        end
      end)

    finish_shape(current, lines, scattered)
  end

  defp finish_shape(nil, lines, scattered), do: {lines, scattered}

  defp finish_shape({shape_id, points}, lines, scattered) do
    if Map.has_key?(lines, shape_id) or MapSet.member?(scattered, shape_id),
      do: {Map.delete(lines, shape_id), MapSet.put(scattered, shape_id)},
      else: {Map.put(lines, shape_id, points_to_simplified_line(points)), scattered}
  end

  defp read_whole_shapes(dir, shape_ids) do
    dir
    |> Csv.stream("shapes.txt")
    |> Stream.filter(&MapSet.member?(shape_ids, &1["shape_id"]))
    |> Enum.reduce(%{}, fn row, acc ->
      shape_id = row["shape_id"]
      point = shape_point(row)

      if is_map_key(acc, shape_id),
        do: Map.update!(acc, shape_id, &[point | &1]),
        else: Map.put(acc, :binary.copy(shape_id), [point])
    end)
    |> Map.new(fn {shape_id, points} -> {shape_id, points_to_simplified_line(points)} end)
  end

  defp shape_point(row) do
    {parse_int(row["shape_pt_sequence"], 0), parse_float(row["shape_pt_lon"]),
     parse_float(row["shape_pt_lat"])}
  end

  defp points_to_simplified_line(points) do
    points
    |> Enum.sort()
    |> Enum.map(fn {_seq, lon, lat} -> [lon, lat] end)
    |> Geometry.simplify(@simplify_tolerance)
    |> pack_line()
  end

  # A national feed keeps millions of simplified points until they're saved.
  # As `[lon, lat]` lists they take about 80 bytes each; packed as two
  # 64-bit floats, 16, and a float comes back out exactly as it went in. A
  # line with a coordinate that didn't parse stays a list, as it always was.
  defp pack_line(line) do
    if Enum.all?(line, fn [lon, lat] -> is_float(lon) and is_float(lat) end),
      do: for([lon, lat] <- line, into: <<>>, do: <<lon::float-64, lat::float-64>>),
      else: line
  end

  @doc false
  def unpack_line(packed) when is_binary(packed),
    do: for(<<lon::float-64, lat::float-64 <- packed>>, do: [lon, lat])

  def unpack_line(line) when is_list(line), do: line

  defp line_length(packed) when is_binary(packed), do: div(byte_size(packed), 16)
  defp line_length(line) when is_list(line), do: length(line)

  # -- stop_times ---------------------------------------------------------------

  # One streaming pass over the (potentially huge) stop_times.txt collects
  # stop_id -> the routes serving it. A stop is called at by the same route
  # over and over, so the set is only rebuilt for a route it hasn't seen.
  defp scan_stop_times(dir, trip_index) do
    dir
    |> Csv.stream("stop_times.txt")
    |> Enum.reduce(%{}, fn row, stop_route_ids ->
      stop_id = row["stop_id"]

      case {trip_index.trip_to_route[row["trip_id"]], stop_route_ids} do
        {nil, _} ->
          stop_route_ids

        {route_id, %{^stop_id => route_ids}} ->
          if MapSet.member?(route_ids, route_id),
            do: stop_route_ids,
            else: %{stop_route_ids | stop_id => MapSet.put(route_ids, route_id)}

        {route_id, _} ->
          Map.put(stop_route_ids, :binary.copy(stop_id), MapSet.new([route_id]))
      end
    end)
  end

  # -- stops --------------------------------------------------------------------

  # Categories roll up from platforms to their parent station so the map
  # shows one marker per station, the way Apple Maps does.
  defp read_stations(dir, stop_route_ids) do
    all_stops =
      dir
      |> Csv.stream("stops.txt")
      |> Map.new(fn row ->
        stop_id = :binary.copy(row["stop_id"])

        {stop_id,
         %{
           stop_id: stop_id,
           name: copy_presence(row["stop_name"]),
           lat: parse_float(row["stop_lat"]),
           lon: parse_float(row["stop_lon"]),
           location_type: parse_int(row["location_type"], 0),
           parent_station: copy_presence(row["parent_station"])
         }}
      end)

    stop_route_ids
    |> Enum.reduce(%{}, fn {stop_id, route_ids}, station_routes ->
      case station_for(all_stops, stop_id) do
        nil ->
          station_routes

        station_id ->
          Map.update(station_routes, station_id, route_ids, &MapSet.union(&1, route_ids))
      end
    end)
    |> Map.new(fn {station_id, route_ids} ->
      {station_id, Map.put(all_stops[station_id], :route_ids, route_ids)}
    end)
  end

  defp station_for(all_stops, stop_id) do
    case all_stops[stop_id] do
      nil -> nil
      %{parent_station: nil} -> stop_id
      %{parent_station: parent} -> if Map.has_key?(all_stops, parent), do: parent, else: stop_id
    end
  end

  # -- assembling rows ------------------------------------------------------------

  # Every route that runs is kept, so its stations list it, but only a route
  # with a shape that follows the track is drawn: joining stops with
  # straight lines cuts across cities and countries.
  defp build_route_rows(routes, trip_index, shape_geometries) do
    running = trip_index.trip_to_route |> Map.values() |> MapSet.new()

    routes
    |> Map.values()
    |> Enum.map(fn route ->
      {geometry, shape_km} = shape_multiline(route, trip_index.route_shape_ids, shape_geometries)
      Map.merge(route, %{geometry: geometry, shape_km: shape_km})
    end)
    |> Enum.filter(&(&1.geometry || MapSet.member?(running, &1.route_id)))
  end

  # The route's drawn geometry, or nil when it has no shape or its shapes
  # only join its stops, and the length of its shapes either way.
  defp shape_multiline(route, route_shape_ids, shape_geometries) do
    packed =
      route_shape_ids
      |> Map.get(route.route_id, [])
      |> Enum.map(&shape_geometries[&1])
      |> Enum.reject(&(&1 == nil or line_length(&1) < 2))

    lines = Enum.map(packed, &unpack_line/1)

    geometry =
      if packed == [] or stop_to_stop?(route, lines),
        do: nil,
        else: %{type: "MultiLineString", coordinates: packed}

    {geometry, Geometry.length_km(lines)}
  end

  # Ferries and cable cars really do run straight between their stops.
  defp stop_to_stop?(%{category: category}, _lines) when category in ~w(ferry other), do: false
  defp stop_to_stop?(_route, lines), do: Geometry.stop_to_stop?(lines)

  defp station_rows(stations, route_rows) do
    retained_route_ids = MapSet.new(route_rows, & &1.route_id)

    stations
    |> Map.values()
    |> Enum.filter(&(&1.lat && &1.lon))
    |> Enum.map(&Map.take(&1, [:stop_id, :name, :lat, :lon, :location_type, :route_ids]))
    |> Enum.map(fn station ->
      Map.update!(
        station,
        :route_ids,
        &Enum.filter(&1, fn id -> MapSet.member?(retained_route_ids, id) end)
      )
    end)
    |> Enum.reject(&Enum.empty?(&1.route_ids))
  end

  # -- persistence -------------------------------------------------------------

  @doc false
  def persist_rows(name, source, route_rows, station_rows, opts \\ []) do
    now = DateTime.utc_now(:second)

    routes_by_id = Map.new(route_rows, fn route -> {route.route_id, route} end)

    result =
      Repo.transaction(
        fn ->
          attrs =
            opts
            |> Keyword.get(:feed, %{})
            |> Map.merge(service_area(station_rows))

          feed = upsert_feed!(name, source, now, attrs)

          Repo.delete_all(feed_scope(Transitmaps.Gtfs.Route, feed.id))
          Repo.delete_all(feed_scope(Transitmaps.Gtfs.Stop, feed.id))

          insert_batched!(
            Transitmaps.Gtfs.Route,
            Stream.map(route_rows, &route_insert(&1, feed.id, now))
          )

          insert_batched!(
            Transitmaps.Gtfs.Stop,
            Enum.map(station_rows, &stop_insert(&1, feed.id, now, routes_by_id))
          )

          Logger.info(
            "Imported #{length(route_rows)} routes, #{length(station_rows)} stops for feed #{name}"
          )

          feed
        end,
        timeout: :infinity
      )

    if Keyword.get(opts, :invalidate, true), do: Transitmaps.Gtfs.GeoJsonCache.invalidate()
    result
  end

  defp feed_scope(schema, feed_id) do
    import Ecto.Query, only: [from: 2]
    from(r in schema, where: r.feed_id == ^feed_id)
  end

  # The box the map tests against what is on screen. Percentiles rather
  # than extremes, so one stop geocoded to 0,0 can't stretch the feed over
  # half the planet.
  defp service_area([]), do: %{}

  defp service_area(stations) do
    lons = stations |> Enum.map(& &1.lon) |> Enum.sort() |> List.to_tuple()
    lats = stations |> Enum.map(& &1.lat) |> Enum.sort() |> List.to_tuple()
    low = div(tuple_size(lons), 100)
    high = tuple_size(lons) - 1 - low

    %{
      min_lon: elem(lons, low),
      min_lat: elem(lats, low),
      max_lon: elem(lons, high),
      max_lat: elem(lats, high)
    }
  end

  defp upsert_feed!(name, source, now, attrs) do
    attrs =
      %{label: Map.get(@known_labels, name, name)}
      |> Map.merge(Map.take(attrs, [:label, :catalog_id, :min_lon, :min_lat, :max_lon, :max_lat]))

    Repo.insert!(
      struct(
        %Transitmaps.Gtfs.Feed{
          name: name,
          url: source,
          imported_at: now,
          inserted_at: now,
          updated_at: now
        },
        attrs
      ),
      on_conflict: [set: [url: source, imported_at: now, updated_at: now] ++ Map.to_list(attrs)],
      conflict_target: :name,
      returning: true
    )
  end

  defp route_insert(route, feed_id, now) do
    route
    |> Map.take([
      :route_id,
      :agency_name,
      :short_name,
      :long_name,
      :route_type,
      :category,
      :color,
      :text_color,
      :geometry
    ])
    |> Map.merge(%{feed_id: feed_id, inserted_at: now, updated_at: now})
    |> Map.replace_lazy(:geometry, &unpack_geometry/1)
  end

  defp unpack_geometry(%{coordinates: lines} = geometry),
    do: %{geometry | coordinates: Enum.map(lines, &unpack_line/1)}

  defp unpack_geometry(geometry), do: geometry

  defp stop_insert(station, feed_id, now, routes_by_id) do
    lines =
      station.route_ids
      |> Enum.map(&routes_by_id[&1])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn route ->
        %{
          name: route.short_name || route.long_name || route.route_id,
          color: route.color || RouteTypes.default_color(route.category),
          category: route.category,
          agency: route.agency_name
        }
      end)
      |> Enum.uniq_by(&{&1.name, &1.agency})
      |> Enum.sort_by(&{&1.category, &1.name})

    categories =
      lines
      |> Enum.map(& &1.category)
      |> Enum.uniq()
      |> Enum.sort()

    station
    |> Map.take([:stop_id, :name, :lat, :lon, :location_type])
    |> Map.merge(%{
      feed_id: feed_id,
      categories: categories,
      lines: lines,
      inserted_at: now,
      updated_at: now
    })
  end

  # Rows may be a stream, so a batch is only built just before it's inserted.
  defp insert_batched!(schema, rows) do
    rows
    |> Stream.chunk_every(@insert_batch)
    |> Enum.each(&Repo.insert_all(schema, &1))
  end

  # -- parsing helpers -----------------------------------------------------------

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # For values kept past their CSV line, which would otherwise stay alive.
  defp copy_presence(value) do
    if value = presence(value), do: :binary.copy(value)
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(""), do: nil

  defp parse_float(value) do
    case Float.parse(value) do
      {float, _rest} -> float
      :error -> nil
    end
  end

  defp normalize_color(nil), do: nil
  defp normalize_color(""), do: nil
  defp normalize_color("#" <> hex), do: normalize_color(hex)
  defp normalize_color(hex) when byte_size(hex) == 6, do: "#" <> String.upcase(hex)
  defp normalize_color(_), do: nil
end
