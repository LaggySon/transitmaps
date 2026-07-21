defmodule TransitmapsWeb.GeoControllerTest do
  use TransitmapsWeb.ConnCase, async: true

  test "serves routes GeoJSON with validators and cache headers", %{conn: conn} do
    conn = get(conn, ~p"/api/routes.geojson", cats: "rail")

    assert %{"type" => "FeatureCollection", "features" => _} = json_response(conn, 200)
    assert [etag] = get_resp_header(conn, "etag")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]

    revalidated =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/api/routes.geojson", cats: "rail")

    assert revalidated.status == 304
  end

  test "serves gzipped stops GeoJSON when the client accepts it", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-encoding", "gzip")
      |> get(~p"/api/stops.geojson", cats: "rail")

    assert get_resp_header(conn, "content-encoding") == ["gzip"]
    assert get_resp_header(conn, "vary") == ["accept-encoding"]

    body = conn.resp_body |> :zlib.gunzip() |> Jason.decode!()
    assert %{"type" => "FeatureCollection"} = body
  end
end
