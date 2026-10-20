defmodule TransitmapsWeb.DepartureControllerTest do
  use TransitmapsWeb.ConnCase, async: true

  test "asks for the stops to list", %{conn: conn} do
    for query <- ["", "?stops=", "?stops=abc,-3"] do
      assert %{"error" => _} = conn |> get("/api/departures" <> query) |> json_response(400)
    end
  end

  test "lists departures, never from a cache", %{conn: conn} do
    conn = get(conn, "/api/departures?stops=1,2,x&limit=5")

    assert %{
             "departures" => [],
             "more" => false,
             "timezone" => "Etc/UTC",
             "live" => "none",
             "updated_at" => nil,
             "timetable" => "none"
           } = json_response(conn, 200)

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
