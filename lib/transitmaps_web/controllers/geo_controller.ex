defmodule TransitmapsWeb.GeoController do
  use TransitmapsWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.{Cells, Feed, GeoJsonCache}
  alias Transitmaps.Repo

  @empty %{type: "FeatureCollection", features: []}

  # The detail and the cell ride in the kind, so a cache key keeps its
  # {kind, feed, categories} shape for invalidation.
  def routes(conn, params) do
    detail = Gtfs.sanitize_detail(params["detail"])

    case {detail, Cells.parse(params["cell"])} do
      {detail, {_x, _y} = cell} when detail != :low ->
        send_cached_geojson(
          conn,
          {:routes, detail, cell},
          params,
          &Cells.routes(&1, &2, detail, cell)
        )

      {:full, _cell} ->
        send_cached_geojson(conn, :routes, params, &Gtfs.route_feature_collection/2)

      {detail, _cell} ->
        send_cached_geojson(
          conn,
          {:routes, detail},
          params,
          &Gtfs.route_feature_collection(&1, &2, detail)
        )
    end
  end

  def stops(conn, params) do
    case Cells.parse(params["cell"]) do
      nil ->
        send_cached_geojson(conn, :stops, params, &Gtfs.stop_feature_collection/2)

      cell ->
        send_cached_geojson(conn, {:stops, cell}, params, &Cells.stops(&1, &2, cell))
    end
  end

  defp send_cached_geojson(conn, kind, params, builder) do
    categories = Gtfs.sanitize_categories(params["cats"])

    # Only real feeds are cached, so arbitrary query strings can't grow the
    # cache without bound.
    {body, gzipped, etag} =
      case feed_id(params["feed"]) do
        nil ->
          GeoJsonCache.fetch({kind, :unknown}, fn -> @empty end)

        feed_id ->
          GeoJsonCache.fetch({kind, feed_id, Enum.sort(categories)}, fn ->
            builder.(categories, feed_id)
          end)
      end

    conn =
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_header("vary", "accept-encoding")

    cond do
      etag in get_req_header(conn, "if-none-match") ->
        send_resp(conn, 304, "")

      gzip_accepted?(conn) ->
        conn
        |> put_resp_header("content-encoding", "gzip")
        |> send_resp(200, gzipped)

      true ->
        send_resp(conn, 200, body)
    end
  end

  defp feed_id(param) when is_binary(param) do
    with {id, ""} <- Integer.parse(param),
         true <- Repo.exists?(from f in Feed, where: f.id == ^id) do
      id
    else
      _ -> nil
    end
  end

  defp feed_id(_param), do: nil

  defp gzip_accepted?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(&1, "gzip"))
  end
end
