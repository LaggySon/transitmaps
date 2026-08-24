defmodule TransitmapsWeb.GeoControllerTest do
  use TransitmapsWeb.ConnCase, async: true

  alias Transitmaps.Gtfs.{Feed, Stop}
  alias Transitmaps.Repo

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

  test "colors station markers from the dominant requested service", %{conn: conn} do
    feed = Repo.insert!(%Feed{name: "station-colour", url: "test://station-colour"})

    Repo.insert!(%Stop{
      feed_id: feed.id,
      stop_id: "heathrow",
      name: "Heathrow",
      lat: 51.4719,
      lon: -0.4541,
      categories: ["rail", "metro"],
      lines: [
        %{name: "Piccadilly", agency: "TfL", category: "metro", color: "#2D65B0"},
        %{name: "Elizabeth", agency: "TfL", category: "rail", color: "#6950A1"},
        %{name: "Elizabeth", agency: "TfL Rail", category: "rail", color: "#6950A1"}
      ]
    })

    response = conn |> get(~p"/api/stops.geojson", cats: "rail") |> json_response(200)
    assert [%{"properties" => %{"color" => "#6950A1"}}] = response["features"]
  end
end
