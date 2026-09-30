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

  describe "per-agency responses" do
    setup do
      southern = insert_feed("southern")
      scotrail = insert_feed("scotrail")
      insert_route(southern, "Southern", [[-0.2, 51.5], [0.0, 51.5]])
      insert_route(scotrail, "ScotRail", [[-4.2, 55.8], [-3.2, 55.9]])
      %{southern: southern}
    end

    test "serves only the requested agency's routes", %{conn: conn, southern: southern} do
      assert agencies(conn, to_string(southern.id)) == ["Southern"]
    end

    test "serves nothing for a feed that doesn't exist", %{conn: conn} do
      assert agencies(conn, "999999") == []
      assert agencies(conn, "not-a-feed") == []
      assert agencies(conn, nil) == []
    end
  end

  defp agencies(conn, feed) do
    params = if feed, do: [cats: "rail", feed: feed], else: [cats: "rail"]

    conn
    |> get(~p"/api/routes.geojson", params)
    |> json_response(200)
    |> Map.fetch!("features")
    |> Enum.map(& &1["properties"]["agency"])
    |> Enum.sort()
  end

  defp insert_feed(name) do
    Transitmaps.Repo.insert!(%Transitmaps.Gtfs.Feed{name: name})
  end

  defp insert_route(feed, agency, coordinates) do
    Transitmaps.Repo.insert!(%Transitmaps.Gtfs.Route{
      feed_id: feed.id,
      route_id: agency,
      agency_name: agency,
      route_type: 2,
      category: "rail",
      geometry: %{"type" => "MultiLineString", "coordinates" => [coordinates]}
    })
  end
end
