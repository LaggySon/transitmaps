defmodule Transitmaps.Gtfs.TflImporter do
  @moduledoc """
  Imports London's rail-family transit lines from the TfL Unified API.

  The public API works without credentials at its anonymous rate limit. Set
  `TFL_APP_KEY` to use a registered key when importing frequently.
  """

  alias Transitmaps.Gtfs.Importer

  @api "https://api.tfl.gov.uk"
  @modes "tube,dlr,tram,overground,elizabeth-line"
  @overpass "https://overpass.kumi.systems/api/interpreter"
  @geometry_cache Path.join(["priv", "gtfs_cache", "tfl-osm-routes.json"])
  @tram_geometry_cache Path.join(["priv", "gtfs_cache", "tfl-osm-tram.json"])

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

  def import do
    lines = get!("/Line/Mode/#{@modes}/Route")

    details =
      Task.async_stream(lines, &line_detail/1,
        max_concurrency: 4,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, detail} -> detail end)

    osm_relations = osm_relations!()
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
    coordinates = osm_coordinates(line, mode, osm_relations)

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

  defp osm_relations! do
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

  defp osm_coordinates(line, mode, relations) do
    relations
    |> Enum.filter(&relation_for_line?(&1, line, mode))
    |> Enum.flat_map(fn relation ->
      relation["members"]
      |> Enum.filter(&(&1["type"] == "way" && is_list(&1["geometry"])))
      |> Enum.map(fn member ->
        Enum.map(member["geometry"], &[&1["lon"], &1["lat"]])
      end)
    end)
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.uniq()
  end

  defp relation_for_line?(relation, line, mode) do
    tags = relation["tags"] || %{}
    label = String.downcase("#{tags["ref"]} #{tags["name"]}")
    id = line["id"]
    name = String.downcase(line["name"])

    cond do
      mode == "tram" -> String.contains?(label, ["tramlink", "london trams"])
      id == "dlr" -> String.contains?(label, ["dlr", "docklands light railway"])
      id == "elizabeth" -> String.contains?(label, "elizabeth")
      true -> String.contains?(label, [String.downcase(id), name])
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
