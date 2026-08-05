defmodule Transitmaps.Gtfs do
  @moduledoc """
  Query context for imported GTFS data, serving map-ready GeoJSON.

  Route display work — which lines exist, their geometry, and how
  corridor-sharing lines bundle — lives in `Transitmaps.Display`; this
  module queries the database and shapes the results into GeoJSON.
  """

  import Ecto.Query

  alias Transitmaps.Display
  alias Transitmaps.Display.Identity
  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs.{Route, RouteTypes, Stop}
  alias Transitmaps.Repo

  @doc """
  Parses a comma-separated category list (`"rail,metro"`), keeping only
  known categories. Unknown or empty input yields `[]`.
  """
  def sanitize_categories(param) when is_binary(param) do
    param
    |> String.split(",", trim: true)
    |> Enum.filter(&(&1 in RouteTypes.categories()))
    |> Enum.uniq()
  end

  def sanitize_categories(_), do: []

  @doc "Categories that actually have routes in the database, with route counts."
  def category_counts do
    Route
    |> group_by([r], r.category)
    |> select([r], {r.category, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  def route_feature_collection(categories) do
    Route
    |> where([r], r.category in ^categories)
    |> where([r], not is_nil(r.geometry))
    |> Repo.all()
    |> Display.drawn_lines()
    |> Enum.map(&line_feature/1)
    |> feature_collection()
  end

  def corridor_feature_collection(categories) do
    Route
    |> where([r], r.category in ^categories)
    |> where([r], not is_nil(r.geometry))
    |> Repo.all()
    |> Display.corridor_ribbons()
    |> Enum.map(&corridor_feature/1)
    |> feature_collection()
  end

  def stop_feature_collection(categories) do
    Stop
    |> Repo.all()
    |> merge_colocated_stops()
    |> Enum.filter(fn stop -> Enum.any?(stop.categories, &(&1 in categories)) end)
    |> Enum.map(&stop_feature/1)
    |> feature_collection()
  end

  # How far apart two stops can be and still be one place. A big interchange
  # spreads its entrances over a couple of hundred metres — King's Cross St
  # Pancras arrives as three stations a block apart and should be drawn as
  # the one place a passenger changes at.
  #
  # Only rail-family stations reach that far. Because clustering chains
  # (A merges with C through B), a radius that generous applied to bus stops
  # would swallow a whole high street's worth of them into one marker.
  @station_merge_km 0.25
  @stop_merge_km 0.05

  @station_categories ~w(rail metro intercity tram)

  @doc false
  def merge_colocated_stops(stops) do
    stops
    |> cluster_colocated(@station_merge_km)
    |> Enum.map(&merge_stops/1)
  end

  # Stops chain into a station while each hop stays inside the radius. The
  # obvious alternative — rounding coordinates onto a fixed grid — splits a
  # complex in half whenever it happens to straddle a cell boundary, which
  # is exactly how King's Cross ended up drawn as three separate dots.
  defp cluster_colocated(stops, radius_km) do
    indexed = stops |> Enum.with_index() |> Map.new(fn {stop, index} -> {index, stop} end)
    cells = Enum.group_by(indexed, fn {_i, stop} -> cell(stop, radius_km) end, &elem(&1, 0))

    {clusters, _visited} =
      indexed
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, fn index, {clusters, visited} ->
        if MapSet.member?(visited, index) do
          {clusters, visited}
        else
          {members, visited} =
            flood([index], indexed, cells, radius_km, MapSet.put(visited, index), [])

          {[Enum.map(members, &Map.fetch!(indexed, &1)) | clusters], visited}
        end
      end)

    Enum.reverse(clusters)
  end

  defp flood([], _indexed, _cells, _radius_km, visited, members), do: {members, visited}

  defp flood([index | queue], indexed, cells, radius_km, visited, members) do
    stop = Map.fetch!(indexed, index)

    {found, visited} =
      stop
      |> neighbouring_indexes(cells, radius_km)
      |> Enum.reduce({[], visited}, fn other, {found, visited} ->
        if MapSet.member?(visited, other) or not within?(stop, Map.fetch!(indexed, other)) do
          {found, visited}
        else
          {[other | found], MapSet.put(visited, other)}
        end
      end)

    flood(found ++ queue, indexed, cells, radius_km, visited, [index | members])
  end

  # Cells are one radius across, so every stop within the radius is in this
  # cell or one touching it.
  defp cell(stop, radius_km) do
    {kx, ky} = Geometry.km_scale([stop.lon, stop.lat])
    {trunc(stop.lon * kx / radius_km), trunc(stop.lat * ky / radius_km)}
  end

  defp neighbouring_indexes(stop, cells, radius_km) do
    {cx, cy} = cell(stop, radius_km)

    for dx <- -1..1,
        dy <- -1..1,
        index <- Map.get(cells, {cx + dx, cy + dy}, []),
        do: index
  end

  defp within?(one, other) do
    {kx, ky} = Geometry.km_scale([one.lon, one.lat])
    dx = (one.lon - other.lon) * kx
    dy = (one.lat - other.lat) * ky
    radius_km = merge_radius_km(one, other)

    dx * dx + dy * dy <= radius_km * radius_km
  end

  defp merge_radius_km(one, other) do
    if station?(one) and station?(other), do: @station_merge_km, else: @stop_merge_km
  end

  defp station?(stop), do: Enum.any?(stop.categories, &(&1 in @station_categories))

  defp merge_stops([representative | _rest] = stops) do
    %{
      representative
      | categories: stops |> Enum.flat_map(& &1.categories) |> Enum.uniq(),
        lines: stops |> Enum.flat_map(& &1.lines) |> Enum.uniq_by(&line_identity/1),
        name: preferred_station_name(stops),
        # Sit the marker in the middle of the complex rather than on whichever
        # entrance happened to come first, so the dot lands between the
        # platforms it stands for instead of off to one side of them.
        lon: mean(stops, & &1.lon),
        lat: mean(stops, & &1.lat)
    }
  end

  defp mean(stops, fun), do: Enum.sum(Enum.map(stops, fun)) / length(stops)

  defp line_identity(line) do
    {line_value(line, :name), line_value(line, :agency)}
  end

  # Counts the lines a passenger sees drawn, which is what makes a station feel
  # like an interchange. Feeds do not count that way: a national-rail operator
  # lists every timetabled service separately, so London Bridge arrives with
  # over two hundred "lines" where the map draws about six. Rail operators
  # collapse to one line each — the same rule `Identity` draws them by — while
  # metro-style lines stay individual.
  defp drawn_line_count(stop) do
    stop.lines
    |> Enum.map(&drawn_line_key/1)
    |> Enum.uniq()
    |> length()
  end

  defp drawn_line_key(line) do
    agency = line_value(line, :agency)

    if Identity.brand_color(agency, line_value(line, :category)),
      do: {:operator, agency},
      else: line_identity(line)
  end

  defp line_value(line, key), do: Map.get(line, key) || Map.get(line, Atom.to_string(key))

  # The merged complex takes the name of whichever stop carries the most
  # services, so Bank and Monument come out as "Bank". Preferring the longest
  # name instead would answer "Monument", naming the interchange after its
  # quieter half.
  defp preferred_station_name(stops) do
    stops
    |> Enum.max_by(&{drawn_line_count(&1), String.length(&1.name || "")})
    |> Map.get(:name)
  end

  # Names a ribbon can carry before the label stops being read and starts
  # being scenery. A trunk route runs ten operators over one pair of tracks;
  # set out in full along the line that is a sentence, and the map has to find
  # room for it at every repeat.
  @label_names 3

  # What a ribbon calls itself. Repeats are dropped — a corridor can carry two
  # drawn lines of the same name, and "Mildmay · Suffragette · Mildmay" reads
  # as a mistake wherever it lands.
  defp corridor_label(names) do
    case Enum.uniq(names) do
      few when length(few) <= @label_names ->
        Enum.join(few, " · ")

      many ->
        Enum.join(Enum.take(many, @label_names), " · ") <> " +#{length(many) - @label_names}"
    end
  end

  # Stripe colours go out as `stripe_0`, `stripe_1`, … rather than one list:
  # a GeoJSON source flattens list properties to strings on the way into the
  # renderer, leaving no way to index them from a style expression.
  defp corridor_feature(corridor) do
    stripes =
      corridor.colors
      |> Enum.with_index()
      |> Map.new(fn {color, index} -> {:"stripe_#{index}", color} end)

    # Each band's own name, beside its own colour and in the same order, so a
    # band can be labelled for the line it stands for rather than the ribbon
    # carrying one list of names for all of them.
    band_names =
      corridor.names
      |> Enum.with_index()
      |> Map.new(fn {name, index} -> {:"name_#{index}", name} end)

    %{
      type: "Feature",
      geometry: %{type: "LineString", coordinates: corridor.coordinates},
      properties:
        stripes
        |> Map.merge(band_names)
        |> Map.merge(%{
          name: corridor_label(corridor.names),
          category: corridor.category,
          # How many colours the ribbon carries: it sets the ribbon's thickness
          # and where each stripe sits across it.
          stripes: length(corridor.colors)
        })
    }
  end

  defp line_feature(line) do
    %{
      type: "Feature",
      geometry: line.geometry,
      properties: %{
        name: line.name,
        long_name: line.long_name,
        agency: line.agency,
        category: line.category,
        color: line.color,
        text_color: line.text_color
      }
    }
  end

  defp stop_feature(%Stop{} = stop) do
    %{
      type: "Feature",
      geometry: %{type: "Point", coordinates: [stop.lon, stop.lat]},
      properties: %{
        name: stop.name,
        categories: stop.categories,
        lines: Enum.map(stop.lines, &present_line/1),
        # Stations serving rail-family modes get the larger "station" marker.
        station: station?(stop),
        # How many services meet here, so the map can draw Bank at the size of
        # the interchange it is rather than as one more dot on the Northern.
        interchange: drawn_line_count(stop)
      }
    }
  end

  # Stored line entries may be atom- or string-keyed (structs vs jsonb);
  # normalize the shape and apply operator brand colours, matching what
  # `route_feature_collection/1` serves for the lines themselves.
  defp present_line(line) do
    agency = line_value(line, :agency)
    category = line_value(line, :category)

    %{
      name: line_value(line, :name),
      agency: agency,
      category: category,
      color: Identity.brand_color(agency, category) || line_value(line, :color)
    }
  end

  defp feature_collection(features) do
    %{type: "FeatureCollection", features: features}
  end
end
