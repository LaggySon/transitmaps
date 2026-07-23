defmodule TransitmapsWeb.VehicleControllerTest do
  use TransitmapsWeb.ConnCase, async: true

  test "serves a live vehicle FeatureCollection for a known region", %{conn: conn} do
    conn = get(conn, ~p"/api/vehicles.geojson?#{[region: "great-britain"]}")

    # The poller is disabled in test, so the collection is present but empty.
    assert %{"type" => "FeatureCollection", "features" => []} = json_response(conn, 200)
  end

  test "defaults an unknown or missing region instead of erroring", %{conn: conn} do
    conn = get(conn, ~p"/api/vehicles.geojson")

    assert %{"type" => "FeatureCollection", "features" => []} = json_response(conn, 200)
  end
end
