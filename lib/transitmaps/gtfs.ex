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
    |> OffsetSlots.assign()
    |> Enum.map(fn {route, slot} -> route_feature(route, slot) end)
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

  defp route_feature(%Route{} = route, offset_slot) do
    %{
      type: "Feature",
      geometry: DisplayGeometry.prepare(route.geometry),
      properties: %{
        name: route.short_name || route.long_name || route.route_id,
        long_name: route.long_name,
        agency: route.agency_name,
        category: route.category,
        color:
          OperatorColors.color_for(route.agency_name, route.category) ||
            route.color || RouteTypes.default_color(route.category),
        text_color: route.text_color || "#FFFFFF",
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
