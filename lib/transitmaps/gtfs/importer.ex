defmodule Transitmaps.Gtfs.Importer do
  @moduledoc """
  Imports a GTFS feed (zip URL or local path) into the database.

  The importer is intentionally schedule-free: it keeps only what the map
  needs — routes with a representative geometry per service pattern, and
  stations tagged with the categories of the routes that serve them.

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

  def import_feed(name, source) do
    dir = fetch_and_extract!(name, source)

    try do
      routes = read_routes(dir, read_agencies(dir))
      trip_index = index_trips(dir, routes)
      shape_geometries = read_selected_shapes(dir, trip_index.selected_shape_ids)
      {stop_route_ids, fallback_paths} = scan_stop_times(dir, trip_index)
      {stations, stop_coords} = read_stations(dir, stop_route_ids)

      route_rows =
        build_route_rows(routes, trip_index, shape_geometries, fallback_paths, stop_coords)
        |> normalize_feed_categories(name)

      persist_rows(name, source, route_rows, station_rows(stations, route_rows))
    after
      File.rm_rf!(dir)
    end
  end

  defp normalize_feed_categories(routes, "amtrak") do
    Enum.map(routes, fn route ->
      if String.contains?(route.agency_name || "", "Amtrak") do
        Map.put(route, :category, "intercity")
      else
        route
      end
    end)
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

  defp fetch_and_extract!(name, source) do
    zip_path = ensure_local_zip!(name, source)
    extract_dir = Path.join(System.tmp_dir!(), "gtfs_#{name}")

    File.rm_rf!(extract_dir)
    File.mkdir_p!(extract_dir)

    {:ok, _files} =
      :zip.extract(String.to_charlist(zip_path), cwd: String.to_charlist(extract_dir))

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

      {row["route_id"],
       %{
         route_id: row["route_id"],
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
  #   * one representative trip per route+direction for shapeless routes,
  #     whose stop sequence becomes the fallback geometry
  defp index_trips(dir, routes) do
    initial = %{trip_to_route: %{}, shape_counts: %{}, fallback_trip_ids: %{}}

    index =
      dir
      |> Csv.stream("trips.txt")
      |> Enum.reduce(initial, fn row, acc ->
        trip_id = row["trip_id"]
        route_id = row["route_id"]
        shape_id = presence(row["shape_id"])

        acc = put_in(acc.trip_to_route[trip_id], route_id)

        if shape_id do
          update_in(acc.shape_counts[route_id], &increment_count(&1, shape_id))
        else
          direction_key = {route_id, row["direction_id"] || "0"}
          update_in(acc.fallback_trip_ids, &Map.put_new(&1, direction_key, trip_id))
        end
      end)

    selected = select_shapes_per_route(index.shape_counts)

    %{
      trip_to_route: index.trip_to_route,
      route_shape_ids: selected,
      selected_shape_ids: selected |> Map.values() |> List.flatten() |> MapSet.new(),
      fallback_trip_ids: fallback_trips_for_shapeless_routes(index, routes)
    }
  end

  defp increment_count(nil, shape_id), do: %{shape_id => 1}
  defp increment_count(counts, shape_id), do: Map.update(counts, shape_id, 1, &(&1 + 1))

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

  # Only routes with no shape at all fall back to stop-sequence geometry.
  defp fallback_trips_for_shapeless_routes(index, routes) do
    index.fallback_trip_ids
    |> Enum.filter(fn {{route_id, _direction}, _trip_id} ->
      Map.has_key?(routes, route_id) and not Map.has_key?(index.shape_counts, route_id)
    end)
    |> Map.new(fn {{route_id, _direction}, trip_id} -> {trip_id, route_id} end)
  end

  # -- shapes ------------------------------------------------------------------

  defp read_selected_shapes(dir, selected_shape_ids) do
    dir
    |> Csv.stream("shapes.txt")
    |> Stream.filter(&MapSet.member?(selected_shape_ids, &1["shape_id"]))
    |> Enum.reduce(%{}, fn row, acc ->
      point =
        {parse_int(row["shape_pt_sequence"], 0), parse_float(row["shape_pt_lon"]),
         parse_float(row["shape_pt_lat"])}

      Map.update(acc, row["shape_id"], [point], &[point | &1])
    end)
    |> Map.new(fn {shape_id, points} -> {shape_id, points_to_simplified_line(points)} end)
  end

  defp points_to_simplified_line(points) do
    points
    |> Enum.sort()
    |> Enum.map(fn {_seq, lon, lat} -> [lon, lat] end)
    |> Geometry.simplify(@simplify_tolerance)
  end

  # -- stop_times ---------------------------------------------------------------

  # One streaming pass over the (potentially huge) stop_times.txt collects:
  #   * stop_id -> categories of routes serving it
  #   * ordered stop sequences for the fallback trips
  defp scan_stop_times(dir, trip_index) do
    dir
    |> Csv.stream("stop_times.txt")
    |> Enum.reduce({%{}, %{}}, fn row, {stop_route_ids, fallback_paths} ->
      trip_id = row["trip_id"]
      stop_id = row["stop_id"]
      route_id = trip_index.trip_to_route[trip_id]

      stop_route_ids =
        case route_id do
          nil ->
            stop_route_ids

          _ ->
            Map.update(stop_route_ids, stop_id, MapSet.new([route_id]), &MapSet.put(&1, route_id))
        end

      fallback_paths =
        case trip_index.fallback_trip_ids[trip_id] do
          nil ->
            fallback_paths

          fallback_route_id ->
            point = {parse_int(row["stop_sequence"], 0), stop_id, fallback_route_id}
            Map.update(fallback_paths, trip_id, [point], &[point | &1])
        end

      {stop_route_ids, fallback_paths}
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
        {row["stop_id"],
         %{
           stop_id: row["stop_id"],
           name: presence(row["stop_name"]),
           lat: parse_float(row["stop_lat"]),
           lon: parse_float(row["stop_lon"]),
           location_type: parse_int(row["location_type"], 0),
           parent_station: presence(row["parent_station"])
         }}
      end)

    stations =
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

    stop_coords =
      all_stops
      |> Enum.filter(fn {_id, stop} -> stop.lat && stop.lon end)
      |> Map.new(fn {stop_id, stop} -> {stop_id, [stop.lon, stop.lat]} end)

    {stations, stop_coords}
  end

  defp station_for(all_stops, stop_id) do
    case all_stops[stop_id] do
      nil -> nil
      %{parent_station: nil} -> stop_id
      %{parent_station: parent} -> if Map.has_key?(all_stops, parent), do: parent, else: stop_id
    end
  end

  # -- assembling rows ------------------------------------------------------------

  defp build_route_rows(routes, trip_index, shape_geometries, fallback_paths, stop_coords) do
    fallback_geometries = fallback_geometries_by_route(fallback_paths, stop_coords)

    routes
    |> Map.values()
    |> Enum.map(fn route ->
      lines =
        shape_multiline(route.route_id, trip_index.route_shape_ids, shape_geometries) ||
          fallback_geometries[route.route_id]

      Map.put(route, :geometry, lines && %{type: "MultiLineString", coordinates: lines})
    end)
    |> Enum.filter(& &1.geometry)
  end

  defp shape_multiline(route_id, route_shape_ids, shape_geometries) do
    lines =
      route_shape_ids
      |> Map.get(route_id, [])
      |> Enum.map(&shape_geometries[&1])
      |> Enum.reject(&(&1 == nil or length(&1) < 2))

    if lines == [], do: nil, else: lines
  end

  defp fallback_geometries_by_route(fallback_paths, stop_coords) do
    fallback_paths
    |> Enum.group_by(
      fn {_trip_id, [{_seq, _stop, route_id} | _]} -> route_id end,
      fn {_trip_id, points} -> stop_sequence_to_line(points, stop_coords) end
    )
    |> Map.new(fn {route_id, lines} ->
      {route_id, lines |> Enum.reject(&(length(&1) < 2)) |> non_empty_or_nil()}
    end)
  end

  defp stop_sequence_to_line(points, stop_coords) do
    points
    |> Enum.sort()
    |> Enum.map(fn {_seq, stop_id, _route} -> stop_coords[stop_id] end)
    |> Enum.reject(&is_nil/1)
  end

  defp non_empty_or_nil([]), do: nil
  defp non_empty_or_nil(lines), do: lines

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
  def persist_rows(name, source, route_rows, station_rows) do
    now = DateTime.utc_now(:second)

    routes_by_id = Map.new(route_rows, fn route -> {route.route_id, route} end)

    result =
      Repo.transaction(
        fn ->
          feed = upsert_feed!(name, source, now)

          Repo.delete_all(feed_scope(Transitmaps.Gtfs.Route, feed.id))
          Repo.delete_all(feed_scope(Transitmaps.Gtfs.Stop, feed.id))

          insert_batched!(
            Transitmaps.Gtfs.Route,
            Enum.map(route_rows, &route_insert(&1, feed.id, now))
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

    Transitmaps.Gtfs.GeoJsonCache.invalidate()
    result
  end

  defp feed_scope(schema, feed_id) do
    import Ecto.Query, only: [from: 2]
    from(r in schema, where: r.feed_id == ^feed_id)
  end

  defp upsert_feed!(name, source, now) do
    Repo.insert!(
      %Transitmaps.Gtfs.Feed{
        name: name,
        url: source,
        imported_at: now,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [url: source, imported_at: now, updated_at: now]],
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
  end

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

  defp insert_batched!(schema, rows) do
    rows
    |> Enum.chunk_every(@insert_batch)
    |> Enum.each(&Repo.insert_all(schema, &1))
  end

  # -- parsing helpers -----------------------------------------------------------

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

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
