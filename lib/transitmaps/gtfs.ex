defmodule Transitmaps.Gtfs do
  @moduledoc """
  Query context for imported GTFS data, serving map-ready GeoJSON.
  """

  import Ecto.Query

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
    |> Repo.all()
    |> Enum.map(&route_feature/1)
    |> feature_collection()
  end

  def stop_feature_collection(categories) do
    Stop
    |> where([s], fragment("? && ?", s.categories, type(^categories, {:array, :string})))
    |> Repo.all()
    |> Enum.map(&stop_feature/1)
    |> feature_collection()
  end

  defp route_feature(%Route{} = route) do
    %{
      type: "Feature",
      geometry: route.geometry,
      properties: %{
        name: route.short_name || route.long_name || route.route_id,
        long_name: route.long_name,
        agency: route.agency_name,
        category: route.category,
        color: route.color || RouteTypes.default_color(route.category),
        text_color: route.text_color || "#FFFFFF"
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
        # Stations serving rail-family modes get the larger "station" marker.
        station: Enum.any?(stop.categories, &(&1 in ~w(rail metro intercity tram)))
      }
    }
  end

  defp feature_collection(features) do
    %{type: "FeatureCollection", features: features}
  end
end
