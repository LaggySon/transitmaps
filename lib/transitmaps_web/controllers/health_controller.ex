defmodule TransitmapsWeb.HealthController do
  use TransitmapsWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      commit: System.get_env("RAILWAY_GIT_COMMIT_SHA")
    })
  end
end
