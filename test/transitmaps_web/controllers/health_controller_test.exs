defmodule TransitmapsWeb.HealthControllerTest do
  use TransitmapsWeb.ConnCase, async: true

  test "reports health and the deployed Railway commit", %{conn: conn} do
    response = conn |> get(~p"/health") |> json_response(200)

    assert response["status"] == "ok"
    assert Map.has_key?(response, "commit")
  end
end
