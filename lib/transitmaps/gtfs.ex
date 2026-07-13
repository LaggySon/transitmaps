defmodule Transitmaps.Gtfs do
  @moduledoc """
  Query context for imported GTFS data, serving map-ready GeoJSON.
  """

  import Ecto.Query

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
    |> Repo.all()
    |> assign_offset_slots()
    |> Enum.map(fn {route, slot} -> route_feature(route, slot) end)
    |> feature_collection()
  end

  # Routes that share a corridor (Circle/District/Hammersmith through central
  # London, NEC operators, ...) are near-identical polylines that would
  # overpaint each other. Each route gets a stable offset slot; the client
  # renders slots as side-by-side parallel strands, Apple Maps style. Slots
  # cycle within a category sorted by agency+name, so corridor-sharing
  # siblings (usually same agency, adjacent names) land on distinct slots.
  @offset_slots 5

  defp assign_offset_slots(routes) do
    routes
    |> Enum.group_by(& &1.category)
    |> Enum.flat_map(fn {_category, group} ->
      group
      |> Enum.sort_by(&{&1.agency_name, &1.short_name || &1.long_name || &1.route_id})
      |> Enum.with_index()
      |> Enum.map(fn {route, index} ->
        {route, rem(index, @offset_slots) - div(@offset_slots, 2)}
      end)
    end)
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
      geometry: prepare_geometry(route.geometry),
      properties: %{
        name: route.short_name || route.long_name || route.route_id,
        long_name: route.long_name,
        agency: route.agency_name,
        category: route.category,
        color: route.color || RouteTypes.default_color(route.category),
        text_color: route.text_color || "#FFFFFF",
        offset: offset_slot
      }
    }
  end

  defp prepare_geometry(%{"type" => "MultiLineString", "coordinates" => lines}) do
    %{"type" => "MultiLineString", "coordinates" => prepare_lines(lines)}
  end

  defp prepare_geometry(%{type: "MultiLineString", coordinates: lines}) do
    %{type: "MultiLineString", coordinates: prepare_lines(lines)}
  end

  defp prepare_geometry(geometry), do: geometry

  # A route's service-pattern strands (up to 6, see Importer) mostly re-trace
  # the same track; where they reverse or pick different platforms they paint
  # loops and tangles around stations. Splitting reversal hairpins and
  # dropping strands that stay within a platform's width of kept geometry
  # leaves one clean line per genuine branch.
  @near_duplicate_km 0.15

  defp prepare_lines(lines) do
    lines
    |> Enum.flat_map(&Geometry.split_long_segments(&1, 25))
    |> Enum.flat_map(&Geometry.split_at_reversals/1)
    |> Geometry.drop_redundant_lines(@near_duplicate_km)
    |> Enum.map(&normalize_direction/1)
  end

  # MapLibre's line-offset shifts perpendicular to travel direction, so a
  # route's opposite-direction shape variants would fan out to opposite
  # sides. Give every part one canonical direction so a route's strands all
  # offset the same way.
  defp normalize_direction([first | _rest] = line) do
    if List.last(line) < first, do: Enum.reverse(line), else: line
  end

  defp normalize_direction(line), do: line

  defp stop_feature(%Stop{} = stop) do
    %{
      type: "Feature",
      geometry: %{type: "Point", coordinates: [stop.lon, stop.lat]},
      properties: %{
        name: stop.name,
        categories: stop.categories,
        lines: stop.lines,
        # Stations serving rail-family modes get the larger "station" marker.
        station: Enum.any?(stop.categories, &(&1 in ~w(rail metro intercity tram)))
      }
    }
  end

  defp feature_collection(features) do
    %{type: "FeatureCollection", features: features}
  end
end
