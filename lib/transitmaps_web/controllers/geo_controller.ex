defmodule TransitmapsWeb.GeoController do
  use TransitmapsWeb, :controller

  alias Transitmaps.Gtfs

  def routes(conn, params) do
    json(conn, Gtfs.route_feature_collection(requested_categories(params)))
  end

  def stops(conn, params) do
    json(conn, Gtfs.stop_feature_collection(requested_categories(params)))
  end

  defp requested_categories(params), do: Gtfs.sanitize_categories(params["cats"])
end
