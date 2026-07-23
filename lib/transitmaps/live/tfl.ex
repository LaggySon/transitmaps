defmodule Transitmaps.Live.Tfl do
  @moduledoc """
  Derives real-time London train positions from the TfL Unified API.

  TfL does not publish vehicle coordinates. It does publish, per line, live
  arrival predictions — each says a given train will reach a station
  (`naptanId`) in `timeToStation` seconds, travelling `inbound`/`outbound`.
  Combined with the ordered station geometry from a line's route sequence,
  that is enough to place trains on the track: a train is drawn interpolated
  back from its next station by how close it is to arriving.

  The pure `station_graph/1` and `vehicles/3` functions carry all of the
  derivation and are exercised directly in tests; `fetch_*` perform the live
  HTTP calls against the same API the importer already uses.
  """

  @api "https://api.tfl.gov.uk"
  @modes "tube,dlr,tram,overground,elizabeth-line"

  # Nominal time a train spends travelling between two adjacent stations.
  # Only predictions within this window are drawn (one train per platform
  # approach), and the value sets how far back from the platform an
  # approaching train is placed.
  @segment_seconds 105

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

  @doc "The TfL lines to track, each as `%{id, name, color, category}`."
  def fetch_lines do
    case get("/Line/Mode/#{@modes}/Route") do
      {:ok, lines} when is_list(lines) -> {:ok, Enum.map(lines, &line_meta/1)}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetches and builds the station graph for a single line id."
  def fetch_graph(line_id) do
    case get("/Line/#{line_id}/Route/Sequence/all") do
      {:ok, detail} when is_map(detail) -> {:ok, station_graph(detail)}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fetches live arrivals for a line and derives train position features."
  def fetch_vehicles(line, graph) do
    case get("/Line/#{line.id}/Arrivals") do
      {:ok, arrivals} -> {:ok, vehicles(arrivals, graph, line)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a station graph from a `/Route/Sequence/all` response: a map of
  `naptanId => {lon, lat, name}` coordinates and, per direction, the station
  that precedes each stop, so an approaching train can be drawn between them.
  """
  def station_graph(detail) when is_map(detail) do
    coords =
      for station <- detail["stations"] || [],
          is_number(station["lon"]) and is_number(station["lat"]),
          into: %{} do
        {station["id"], {station["lon"], station["lat"], clean_name(station["name"])}}
      end

    predecessors =
      Enum.reduce(detail["stopPointSequences"] || [], %{}, fn seq, acc ->
        direction = seq["direction"]

        (seq["stopPoint"] || [])
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reduce(acc, fn [prev, curr], inner ->
          Map.put_new(inner, {direction, curr["id"]}, prev["id"])
        end)
      end)

    %{coords: coords, predecessors: predecessors}
  end

  def station_graph(_detail), do: %{coords: %{}, predecessors: %{}}

  @doc """
  Derives one point feature per approaching train from a line's arrivals.

  Predictions are grouped per station and direction — the soonest arrival in
  each group is the next train to reach that platform — then placed on the
  track between the previous station and the platform.
  """
  def vehicles(arrivals, graph, line) when is_list(arrivals) do
    arrivals
    |> Enum.filter(&in_range?/1)
    |> Enum.group_by(fn arrival -> {arrival["direction"], arrival["naptanId"]} end)
    |> Enum.flat_map(fn {_key, group} ->
      group
      |> Enum.min_by(& &1["timeToStation"])
      |> place(graph, line)
    end)
  end

  def vehicles(_arrivals, _graph, _line), do: []

  defp in_range?(%{"timeToStation" => tts, "naptanId" => naptan})
       when is_number(tts) and is_binary(naptan),
       do: tts <= @segment_seconds

  defp in_range?(_arrival), do: false

  defp place(arrival, graph, line) do
    naptan = arrival["naptanId"]

    case Map.fetch(graph.coords, naptan) do
      {:ok, {lon, lat, name}} ->
        {x, y} = interpolate(arrival, naptan, {lon, lat}, graph)
        [feature(arrival, line, x, y, name)]

      :error ->
        []
    end
  end

  defp interpolate(arrival, naptan, {lon, lat}, graph) do
    frac = min(arrival["timeToStation"] / @segment_seconds, 1.0)

    with prev when is_binary(prev) <- Map.get(graph.predecessors, {arrival["direction"], naptan}),
         {:ok, {plon, plat, _name}} <- Map.fetch(graph.coords, prev) do
      {lon + (plon - lon) * frac, lat + (plat - lat) * frac}
    else
      _ -> {lon, lat}
    end
  end

  defp feature(arrival, line, lon, lat, name) do
    %{
      type: "Feature",
      geometry: %{type: "Point", coordinates: [lon, lat]},
      properties: %{
        id: "#{line.id}:#{arrival["direction"]}:#{arrival["naptanId"]}",
        color: line.color,
        category: line.category,
        line: line.name,
        station: name,
        towards: arrival["towards"],
        seconds: arrival["timeToStation"]
      }
    }
  end

  defp line_meta(line) do
    mode = line["modeName"]

    %{
      id: line["id"],
      name: line["name"],
      color: Map.get(@colors, line["id"], default_color(mode)),
      category: category(mode)
    }
  end

  defp get(path) do
    params =
      case System.get_env("TFL_APP_KEY") do
        key when is_binary(key) and key != "" -> [app_key: key]
        _ -> []
      end

    case Req.get(@api <> path, params: params, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clean_name(name) do
    String.replace(name || "Station", ~r/ (Underground|Rail|DLR|Tram) Station$/, "")
  end

  defp category("tram"), do: "tram"
  defp category("overground"), do: "rail"
  defp category("elizabeth-line"), do: "rail"
  defp category(_mode), do: "metro"

  defp default_color("tram"), do: "#84B817"
  defp default_color("overground"), do: "#EE7C0E"
  defp default_color("elizabeth-line"), do: "#6950A1"
  defp default_color(_mode), do: "#E32017"
end
