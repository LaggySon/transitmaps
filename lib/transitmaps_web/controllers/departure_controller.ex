defmodule TransitmapsWeb.DepartureController do
  use TransitmapsWeb, :controller

  alias Transitmaps.Departures

  @doc """
  `/api/departures?stops=12,34&limit=10`: the next departures from the
  stops under one station marker (see `Transitmaps.Departures.list/2`).
  """
  def index(conn, params) do
    stop_ids = parse_ids(params["stops"])

    if stop_ids == [] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Name the stops to list departures from, as stops=12,34."})
    else
      result = Departures.list(stop_ids, limit: parse_limit(params["limit"]))

      conn
      # Live times change by the minute; the map asks again on its own.
      |> put_resp_header("cache-control", "no-store")
      |> json(result)
    end
  end

  defp parse_ids(param) when is_binary(param) do
    param
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn id ->
      case Integer.parse(id) do
        {id, ""} when id > 0 -> [id]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp parse_ids(_param), do: []

  defp parse_limit(param) when is_binary(param) do
    case Integer.parse(param) do
      {limit, ""} -> limit
      _ -> 10
    end
  end

  defp parse_limit(_param), do: 10
end
