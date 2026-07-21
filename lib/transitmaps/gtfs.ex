defmodule Transitmaps.Gtfs do
  @moduledoc """
  Query context for imported GTFS data, serving map-ready GeoJSON.
  """

  import Ecto.Query

  alias Transitmaps.Gtfs.{DisplayGeometry, OffsetSlots, OperatorColors, Route, RouteTypes, Stop}
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
    |> Repo.all()
    |> group_display_lines()
    |> OffsetSlots.assign()
    |> Enum.map(fn {line, slot} -> line_feature(line, slot) end)
    |> feature_collection()
  end

  @doc """
  Collapses raw GTFS routes into the lines the map actually draws.

  National rail feeds describe one operator as dozens of route entries that
  all share the operator's colour and corridor; drawn separately they stack
  into dozens of parallel offset strands. Routes are grouped by category,
  agency, and displayed colour — one feature per visual line — and the
  group's merged geometry is cleaned as a single network, so re-traced
  track collapses to one strand while genuine branches survive. Groups keep
  their own name (a TfL line) when every member shares it, and fall back to
  the agency name (a national operator's many timetabled routes).
  """
  def group_display_lines(routes) do
    routes
    |> Enum.group_by(fn route -> {route.category, route.agency_name, display_color(route)} end)
    |> Enum.map(fn {{category, agency, color}, group} ->
      display_line(category, agency, color, group)
    end)
    |> Enum.sort_by(&{&1.category, &1.agency_name, &1.short_name})
  end

  defp display_line(category, agency, color, group) do
    coordinates = Enum.flat_map(group, &geometry_coordinates(&1.geometry))

    %{
      route_id: group |> Enum.map(& &1.route_id) |> Enum.min(),
      category: category,
      agency_name: agency,
      short_name: shared_value(group, & &1.short_name) || agency,
      long_name: shared_value(group, & &1.long_name),
      color: color,
      text_color: shared_value(group, & &1.text_color) || "#FFFFFF",
      geometry:
        DisplayGeometry.prepare(%{type: "MultiLineString", coordinates: coordinates})
    }
  end

  defp display_color(route) do
    OperatorColors.color_for(route.agency_name, route.category) ||
      route.color || RouteTypes.default_color(route.category)
  end

  # The single value every route in the group shares, or nil when members
  # disagree (then the caller falls back to something group-wide).
  defp shared_value(group, fun) do
    case group |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [value] -> value
      _values -> nil
    end
  end

  defp geometry_coordinates(%{"type" => "MultiLineString", "coordinates" => lines}), do: lines
  defp geometry_coordinates(%{type: "MultiLineString", coordinates: lines}), do: lines
  defp geometry_coordinates(_geometry), do: []

  def stop_feature_collection(categories) do
    Stop
    |> Repo.all()
    |> merge_colocated_stops()
    |> Enum.filter(fn stop -> Enum.any?(stop.categories, &(&1 in categories)) end)
    |> Enum.map(&stop_feature/1)
    |> feature_collection()
  end

  @doc false
  def merge_colocated_stops(stops) do
    stops
    |> Enum.group_by(&station_grid_key/1)
    |> Enum.map(fn {_key, grouped_stops} -> merge_stops(grouped_stops) end)
  end

  # A 0.001-degree grid is roughly one city block. Separate GTFS publishers
  # commonly place the same platforms a few metres apart, so this gives NEC
  # interchanges one marker and one complete service list.
  defp station_grid_key(stop) do
    {round(stop.lon * 1_000), round(stop.lat * 1_000)}
  end

  defp merge_stops([representative | rest]) do
    Enum.reduce(rest, representative, fn stop, merged ->
      %{
        merged
        | categories: Enum.uniq(merged.categories ++ stop.categories),
          lines: Enum.uniq_by(merged.lines ++ stop.lines, &line_identity/1),
          name: preferred_station_name(merged.name, stop.name)
      }
    end)
  end

  defp line_identity(line) do
    {line_value(line, :name), line_value(line, :agency)}
  end

  defp line_value(line, key), do: Map.get(line, key) || Map.get(line, Atom.to_string(key))

  defp preferred_station_name(left, right) do
    Enum.max_by([left, right], &String.length(&1 || ""))
  end

  defp line_feature(line, offset_slot) do
    %{
      type: "Feature",
      geometry: line.geometry,
      properties: %{
        name: line.short_name,
        long_name: line.long_name,
        agency: line.agency_name,
        category: line.category,
        color: line.color,
        text_color: line.text_color,
        offset: offset_slot
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
        station: Enum.any?(stop.categories, &(&1 in ~w(rail metro intercity tram)))
      }
    }
  end

  # Stored line entries may be atom- or string-keyed (structs vs jsonb);
  # normalize the shape and apply operator brand colours, matching what
  # `route_feature/2` serves for the lines themselves.
  defp present_line(line) do
    agency = line_value(line, :agency)
    category = line_value(line, :category)

    %{
      name: line_value(line, :name),
      agency: agency,
      category: category,
      color: OperatorColors.color_for(agency, category) || line_value(line, :color)
    }
  end

  defp feature_collection(features) do
    %{type: "FeatureCollection", features: features}
  end
end
