defmodule TransitmapsWeb.GeoController do
  use TransitmapsWeb, :controller

  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.GeoJsonCache

  def routes(conn, params) do
    send_cached_geojson(conn, :routes, params, &Gtfs.route_feature_collection/1)
  end

  def stops(conn, params) do
    send_cached_geojson(conn, :stops, params, &Gtfs.stop_feature_collection/1)
  end

  defp send_cached_geojson(conn, kind, params, builder) do
    categories = requested_categories(params)
    key = {kind, Enum.sort(categories)}
    {body, gzipped, etag} = GeoJsonCache.fetch(key, fn -> builder.(categories) end)

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

  defp gzip_accepted?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(&1, "gzip"))
  end

  defp requested_categories(params), do: Gtfs.sanitize_categories(params["cats"])
end
