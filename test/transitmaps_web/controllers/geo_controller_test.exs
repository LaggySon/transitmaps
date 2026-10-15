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

    test "simplifies lines for a zoomed-out map", %{conn: conn} do
      feed = insert_feed("wiggly")
      # A line that wobbles by about 50 m on its way east.
      wiggle = for i <- 0..20, do: [i * 0.01 + 0.0000123, 52.0 + rem(i, 2) * 0.0005]
      insert_route(feed, "Wiggly", wiggle)

      points = fn detail ->
        conn
        |> get(~p"/api/routes.geojson", cats: "rail", feed: to_string(feed.id), detail: detail)
        |> json_response(200)
        |> get_in(["features", Access.at(0), "geometry", "coordinates"])
        |> List.flatten()
      end

      full = points.("full")
      low = points.("low")
      mid = points.("mid")

      # Full detail is the stored line; low detail drops the wobble and rounds
      # to 4 places, mid detail keeps it at 5.
      assert length(full) == 42
      assert length(low) == 4
      assert length(mid) == 42
      assert Enum.all?(low, &(Float.round(&1, 4) == &1))
      assert Enum.all?(mid, &(Float.round(&1, 5) == &1))
      assert points.("nonsense") == full
    end

    test "serves a zoomed-in map only what crosses its cell", %{conn: conn} do
      feed = insert_feed("long")
      # A line running east across four 1° cells, one point every 0.1°.
      insert_route(feed, "Long", for(i <- 5..35, do: [i / 10, 52.5]))

      Transitmaps.Repo.insert!(%Transitmaps.Gtfs.Stop{
        feed_id: feed.id,
        stop_id: "in",
        name: "Inside",
        lon: 1.5,
        lat: 52.5,
        categories: ["rail"],
        lines: []
      })

      Transitmaps.Repo.insert!(%Transitmaps.Gtfs.Stop{
        feed_id: feed.id,
        stop_id: "out",
        name: "Outside",
        lon: 3.4,
        lat: 52.5,
        categories: ["rail"],
        lines: []
      })

      cell = fn kind, cell, extra ->
        conn
        |> get(
          "/api/#{kind}.geojson",
          [cats: "rail", feed: to_string(feed.id), cell: cell] ++ extra
        )
        |> json_response(200)
        |> Map.fetch!("features")
      end

      [line] = cell.("routes", "1,52", detail: "full")
      longitudes = line["geometry"]["coordinates"] |> List.flatten() |> Enum.take_every(2)
      # The stretch inside the cell, plus the segments that leave it.
      assert Enum.min(longitudes) == 0.9 and Enum.max(longitudes) == 2.1
      assert line["properties"]["agency"] == "Long"

      assert cell.("routes", "10,10", detail: "full") == []
      assert [%{"properties" => %{"name" => "Inside"}}] = cell.("stops", "1,52", [])
      assert cell.("stops", "2,52", []) == []

      # A malformed cell serves the whole agency, as before.
      assert [_line] = cell.("routes", "nonsense", detail: "full")
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
