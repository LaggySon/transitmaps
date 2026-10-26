defmodule TransitmapsWeb.ServiceControllerTest do
  use TransitmapsWeb.ConnCase, async: true

  test "asks for the feed, trip and day", %{conn: conn} do
    for query <- [
          "",
          "?feed=1&trip=T1",
          "?feed=x&trip=T1&date=2026-03-02",
          "?feed=1&date=2026-03-02"
        ] do
      assert %{"error" => _} = conn |> get("/api/service" <> query) |> json_response(400)
    end
  end

  test "says a service it can't find is not found", %{conn: conn} do
    assert %{"error" => "Service T1 not found."} =
             conn |> get("/api/service?feed=1&trip=T1&date=2026-03-02") |> json_response(404)
  end
end
