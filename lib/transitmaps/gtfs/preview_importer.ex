defmodule Transitmaps.Gtfs.PreviewImporter do
  @moduledoc """
  Hydrates an isolated preview database from the public production GeoJSON.

  A snapshot keeps pull-request deployments independent from production's
  database while avoiding long, failure-prone GTFS and Overpass imports in the
  deployment gate. The preview still runs its own renderer over the copied
  route and station data.
  """

  require Logger

  alias Transitmaps.Gtfs.{Feed, Route, RouteTypes, Stop}
  alias Transitmaps.Repo

  @default_seed_url "https://transitmaps.laggi.sh"
  @feed_name "preview-snapshot"
  @insert_batch 500

  def import(opts \\ []) do
    seed_url = Keyword.get(opts, :seed_url) || System.get_env("RAILWAY_PREVIEW_SEED_URL")
    seed_url = String.trim_trailing(seed_url || @default_seed_url, "/")
    categories = Enum.join(RouteTypes.categories(), ",")

    [route_features, stop_features] =
      ["routes", "stops"]
      |> Task.async_stream(&fetch_features!(seed_url, &1, categories),
        max_concurrency: 2,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, features} -> features end)

    persist_snapshot(seed_url, route_rows(route_features), stop_rows(stop_features))
  end

  @doc false
  def route_rows(features) do
    features
    |> Enum.with_index()
    |> Enum.map(fn {feature, index} ->
      properties = feature["properties"] || %{}
      category = properties["category"] || "other"

      %{
        route_id: "snapshot-route-#{index}",
        agency_name: properties["agency"],
        short_name: properties["name"],
        long_name: properties["long_name"],
        route_type: route_type(category),
        category: category,
        color: properties["color"],
        text_color: properties["text_color"],
        geometry: feature["geometry"]
      }
    end)
  end

  @doc false
  def stop_rows(features) do
    features
    |> Enum.with_index()
    |> Enum.map(fn {feature, index} ->
      properties = feature["properties"] || %{}
      [lon, lat] = get_in(feature, ["geometry", "coordinates"])

      %{
        stop_id: "snapshot-stop-#{index}",
        name: properties["name"],
        lat: lat,
        lon: lon,
        location_type: if(properties["station"], do: 1, else: 0),
        categories: properties["categories"] || [],
        lines: properties["lines"] || []
      }
    end)
  end

  defp fetch_features!(seed_url, kind, categories) do
    %{status: 200, body: %{"features" => features}} =
      Req.get!("#{seed_url}/api/#{kind}.geojson",
        params: [cats: categories],
        receive_timeout: 120_000
      )

    features
  end

  defp persist_snapshot(seed_url, route_rows, stop_rows) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(
        fn ->
          # This database belongs only to the ephemeral PR environment. Replace
          # a partial delayed import from an older deploy with one coherent
          # production snapshot instead of layering duplicate routes over it.
          Repo.delete_all(Feed)

          feed =
            Repo.insert!(%Feed{
              name: @feed_name,
              url: seed_url,
              imported_at: now
            })

          insert_batched(Route, route_rows, feed.id, now)
          insert_batched(Stop, stop_rows, feed.id, now)

          Logger.info(
            "Imported #{length(route_rows)} routes and #{length(stop_rows)} stops for Railway preview"
          )

          feed
        end,
        timeout: :infinity
      )

    Transitmaps.Gtfs.GeoJsonCache.invalidate()
    result
  end

  defp insert_batched(schema, rows, feed_id, now) do
    rows
    |> Enum.map(&Map.merge(&1, %{feed_id: feed_id, inserted_at: now, updated_at: now}))
    |> Enum.chunk_every(@insert_batch)
    |> Enum.each(&Repo.insert_all(schema, &1))
  end

  defp route_type("tram"), do: 0
  defp route_type("metro"), do: 1
  defp route_type("rail"), do: 2
  defp route_type("bus"), do: 3
  defp route_type("ferry"), do: 4
  defp route_type("intercity"), do: 101
  defp route_type("coach"), do: 200
  defp route_type(_category), do: 6
end
