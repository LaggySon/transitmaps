defmodule TransitmapsWeb.VehicleController do
  use TransitmapsWeb, :controller

  alias Transitmaps.Live

  # Live positions change every poll, so this endpoint is intentionally
  # uncached; clients poll it on a short interval while the layer is on.
  def index(conn, params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(Live.vehicles_geojson(params["region"]))
  end
end
