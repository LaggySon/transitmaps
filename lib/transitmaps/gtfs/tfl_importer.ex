defmodule Transitmaps.Gtfs.TflImporter do
  @moduledoc """
  Imports London's rail-family transit lines from the TfL Unified API.

  The public API works without credentials at its anonymous rate limit. Set
  `TFL_APP_KEY` to use a registered key when importing frequently.
  """

  alias Transitmaps.Gtfs.Importer

  @api "https://api.tfl.gov.uk"
  @modes "tube,dlr,tram,overground,elizabeth-line"
  @overpass "https://overpass.private.coffee/api/interpreter"
  @overpass_user_agent "transitmaps/0.1 (https://github.com/LaggySon/transitmaps)"
  @geometry_cache Path.join(["priv", "gtfs_cache", "tfl-osm-routes.json"])
  @tram_geometry_cache Path.join(["priv", "gtfs_cache", "tfl-osm-tram.json"])

  # OSM route relations are made from short way members. Their endpoints
  # should coincide, but allow for small edits made independently on either
  # side of a join.
  @member_join_km 0.075

  # TfL's station list is the authority for a line's extent. The margin
  # keeps terminal sidings and approaches while rejecting a mislabeled OSM
  # relation elsewhere in Britain.
  @station_margin_degrees 0.08

  @colors %{
    "bakerloo" => "#B36305",
    "central" => "#E32017",
    "circle" => "#FFD300",
    "district" => "#00782A",
    "dlr" => "#00A4A7",
    "elizabeth" => "#6950A1",
    "hammersmith-city" => "#F3A9BB",
    "jubilee" => "#A0A5A9",
    "liberty" => "#61686B",
    "lioness" => "#FFA600",
    "metropolitan" => "#9B0056",
    "mildmay" => "#006FE6",
    "northern" => "#000000",
    "piccadilly" => "#003688",
    "suffragette" => "#18A95B",
    "tram" => "#84B817",
    "victoria" => "#0098D4",
    "waterloo-city" => "#95CDBA",
    "weaver" => "#9B0058",
    "windrush" => "#DC241F"
  }

  def import(opts \\ []) do
    lines = get!("/Line/Mode/#{@modes}/Route")

    details =
      Task.async_stream(lines, &line_detail/1,
        max_concurrency: 4,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, detail} -> detail end)

    osm_relations = osm_relations!(Keyword.get(opts, :cache, true))
    routes = Enum.map(details, &route_row(&1, osm_relations))
    stations = station_rows(details)

    Importer.persist_rows("tfl", @api, routes, stations)
  end

  defp line_detail(line) do
    detail = get!("/Line/#{line["id"]}/Route/Sequence/all")
    %{line: line, detail: detail}
  end

  defp route_row(%{line: line, detail: detail}, osm_relations) do
    mode = detail["mode"] || line["modeName"]
    coordinates = line_coordinates(line, mode, osm_relations, detail["stations"] || [])

    if coordinates == [] do
      raise "No geographic OSM geometry found for TfL line #{line["name"]}"
    end

    %{
      route_id: "tfl:" <> line["id"],
      agency_name: "Transport for London",
      short_name: line["name"],
      long_name: line["name"],
      route_type: route_type(mode),
      category: category(mode),
      color: Map.get(@colors, line["id"], default_color(mode)),
      text_color: if(line["id"] == "circle", do: "#111827", else: "#FFFFFF"),
      geometry: %{
        "type" => "MultiLineString",
        "coordinates" => coordinates
      }
    }
  end

  defp osm_relations!(false) do
    download_osm_relations!()
    |> Jason.decode!()
    |> Map.fetch!("elements")
  end

  defp osm_relations!(true) do
    case File.read(@geometry_cache) do
      {:ok, body} ->
        Jason.decode!(body)["elements"] ++ cached_tram_relations()

      {:error, _} ->
        File.mkdir_p!(Path.dirname(@geometry_cache))
        body = download_osm_relations!()
        File.write!(@geometry_cache, body)
        Jason.decode!(body)["elements"] ++ cached_tram_relations()
    end
  end

  defp download_osm_relations! do
    line_pattern =
      "Bakerloo|Central|Circle|District|DLR|Elizabeth|Hammersmith|Jubilee|Liberty|" <>
        "Lioness|Metropolitan|Mildmay|Northern|Piccadilly|Suffragette|Victoria|" <>
        "Waterloo|Weaver|Windrush|Tramlink"

    query = """
    [out:json][timeout:180];
    (
      relation[route~"subway|train|light_rail|tram"][ref~"#{line_pattern}",i](51.2,-0.65,51.8,0.4);
      relation[route~"subway|train|light_rail|tram"][name~"#{line_pattern}",i](51.2,-0.65,51.8,0.4);
      relation[route~"light_rail|tram"](51.2,-0.65,51.8,0.4);
    );
    out geom;
    """

    response =
      Req.post!(@overpass,
        form: [data: query],
        headers: [{"user-agent", @overpass_user_agent}],
        receive_timeout: 240_000,
        retry: false,
        decode_body: false
      )

    if response.status != 200 do
      raise "OSM geometry download failed with HTTP #{response.status}"
    end

    response.body
  end

  defp cached_tram_relations do
    case File.read(@tram_geometry_cache) do
      {:ok, body} -> Jason.decode!(body)["elements"]
      {:error, _} -> []
    end
  end

  @doc false
  def line_coordinates(line, mode, relations, stations) do
    bounds = station_bounds(stations)

    relations
    |> Enum.filter(&relation_for_line?(&1, line, mode))
    |> Enum.flat_map(fn relation ->
      relation["members"]
      |> Enum.flat_map(&member_lines(&1, bounds))
      |> stitch_ordered_members(@member_join_km)
    end)
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.uniq()
  end

  defp member_lines(%{"type" => "way", "geometry" => geometry}, bounds)
       when is_list(geometry) do
    geometry
    |> Enum.map(&[&1["lon"], &1["lat"]])
    |> split_inside_bounds(bounds)
  end

  defp member_lines(_member, _bounds), do: []

  defp station_bounds([]), do: nil

  defp station_bounds(stations) do
    points =
      for %{"lon" => lon, "lat" => lat} <- stations,
          is_number(lon) and is_number(lat),
          do: {lon, lat}

    case points do
      [] ->
        nil

      _ ->
        {longitudes, latitudes} = Enum.unzip(points)

        %{
          west: Enum.min(longitudes) - @station_margin_degrees,
          east: Enum.max(longitudes) + @station_margin_degrees,
          south: Enum.min(latitudes) - @station_margin_degrees,
          north: Enum.max(latitudes) + @station_margin_degrees
        }
    end
  end

  defp split_inside_bounds(line, nil), do: [line]

  defp split_inside_bounds(line, bounds) do
    {lines, current} =
      Enum.reduce(line, {[], []}, fn point, {lines, current} ->
        if inside_bounds?(point, bounds) do
          {lines, [point | current]}
        else
          {[Enum.reverse(current) | lines], []}
        end
      end)

    [Enum.reverse(current) | lines]
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.reverse()
  end

  defp inside_bounds?([lon, lat], bounds) do
    lon >= bounds.west and lon <= bounds.east and lat >= bounds.south and lat <= bounds.north
  end

  # Relation member order records the route traversal. Join consecutive ways
  # on that evidence alone; the display cleanup's heading-aware stitcher is
  # deliberately more conservative because it operates on unrelated strands.
  defp stitch_ordered_members([], _epsilon_km), do: []

  defp stitch_ordered_members([first | rest], epsilon_km) do
    {stitched, current} =
      Enum.reduce(rest, {[], first}, fn next, {stitched, current} ->
        case join_ordered(current, next, epsilon_km) do
          nil -> {[current | stitched], next}
          joined -> {stitched, joined}
        end
      end)

    Enum.reverse([current | stitched])
  end

  defp join_ordered(current, next, epsilon_km) do
    cond do
      close?(List.last(current), hd(next), epsilon_km) ->
        current ++ tl(next)

      close?(List.last(current), List.last(next), epsilon_km) ->
        current ++ tl(Enum.reverse(next))

      close?(hd(current), List.last(next), epsilon_km) ->
        next ++ tl(current)

      close?(hd(current), hd(next), epsilon_km) ->
        Enum.reverse(next) ++ tl(current)

      true ->
        nil
    end
  end

  defp close?([lon1, lat1], [lon2, lat2], epsilon_km) do
    latitude = (lat1 + lat2) / 2
    kx = 111.320 * :math.cos(latitude * :math.pi() / 180)
    dx = (lon2 - lon1) * kx
    dy = (lat2 - lat1) * 110.574
    :math.sqrt(dx * dx + dy * dy) <= epsilon_km
  end

  # A relation only contributes geometry to a line when all three hold: OSM
  # tags it as part of a TfL network, its route type matches the line's
  # mode, and its label names the line itself. Loose substring matching on
  # names alone previously glued National Rail services into TfL lines —
  # "Slough => Windsor & Eton Central" into the Central line, London
  # Victoria services into the Victoria line — painting TfL colours far
  # outside their real extents.
  defp relation_for_line?(relation, line, mode) do
    tags = relation["tags"] || %{}

    tfl_relation?(tags) and route_matches_mode?(tags["route"], mode) and
      labels_line?(tags, line, mode)
  end

  @tfl_networks [
    "london underground",
    "london overground",
    "elizabeth line",
    "dlr",
    "docklands light railway",
    "tramlink",
    "london trams",
    "crossrail",
    "tfl rail"
  ]

  @tfl_operators [
    "transport for london",
    "london underground",
    "rail for london",
    "mtr",
    "arriva rail london",
    "docklands light railway",
    "tram operations",
    "london tramlink"
  ]

  defp tfl_relation?(tags) do
    network = String.downcase(tags["network"] || "")
    # Elizabeth line routes use `National Rail` as their broad network and
    # identify the TfL service in the more specific `network:metro` tag.
    metro_network = String.downcase(tags["network:metro"] || "")
    operator = String.downcase(tags["operator"] || "")

    String.contains?(network, @tfl_networks) or
      String.contains?(metro_network, @tfl_networks) or
      String.contains?(operator, @tfl_operators)
  end

  defp route_matches_mode?(route, "tube"), do: route == "subway"
  defp route_matches_mode?(route, "dlr"), do: route == "light_rail"
  defp route_matches_mode?(route, "tram"), do: route == "tram"
  defp route_matches_mode?(route, _rail_mode), do: route == "train"

  defp labels_line?(tags, line, mode) do
    label = String.downcase("#{tags["ref"]} #{tags["name"]}")
    name = String.downcase(line["name"] || "")

    cond do
      # The network gate already isolates the tram and DLR systems, whose
      # relations are not consistently named after the TfL line.
      mode == "tram" or line["id"] == "dlr" -> true
      line["id"] == "elizabeth" -> String.contains?(label, "elizabeth")
      true -> String.contains?(label, "#{name} line") or String.downcase(tags["ref"] || "") == name
    end
  end

  defp station_rows(details) do
    details
    |> Enum.reduce(%{}, fn %{line: line, detail: detail}, stations ->
      route_id = "tfl:" <> line["id"]

      Enum.reduce(detail["stations"] || [], stations, fn station, acc ->
        row = %{
          stop_id: station["id"],
          name: clean_station_name(station["name"]),
          lat: station["lat"],
          lon: station["lon"],
          location_type: 1,
          route_ids: [route_id]
        }

        Map.update(acc, row.stop_id, row, fn existing ->
          %{existing | route_ids: Enum.uniq([route_id | existing.route_ids])}
        end)
      end)
    end)
    |> Map.values()
    |> Enum.filter(&(&1.lat && &1.lon))
  end

  defp get!(path) do
    options =
      case System.get_env("TFL_APP_KEY") do
        nil -> []
        key -> [params: [app_key: key]]
      end

    Req.get!(@api <> path, options).body
  end

  defp clean_station_name(name) do
    String.replace(name || "Station", ~r/ (Underground|Rail|DLR|Tram) Station$/, "")
  end

  defp category("tram"), do: "tram"
  defp category("overground"), do: "rail"
  defp category("elizabeth-line"), do: "rail"
  defp category(_), do: "metro"

  defp route_type("tram"), do: 0
  defp route_type("overground"), do: 2
  defp route_type("elizabeth-line"), do: 2
  defp route_type(_), do: 1

  defp default_color("tram"), do: "#84B817"
  defp default_color("overground"), do: "#EE7C0E"
  defp default_color("elizabeth-line"), do: "#6950A1"
  defp default_color(_), do: "#E32017"
end
