defmodule TransitmapsWeb.ServiceController do
  use TransitmapsWeb, :controller

  alias Transitmaps.Services

  @doc """
  `/api/service?feed=12&trip=T1&date=2026-10-26&seq=4&at=1793030000`: a
  departure's whole run, every stop it calls at that day (see
  `Transitmaps.Services.show/1`). The parameters are the departure's
  `service`; `seq` and `at` are optional.
  """
  def show(conn, params) do
    with {:ok, feed} <- positive_int(params["feed"]),
         trip when is_binary(trip) and trip != "" <- params["trip"],
         {:ok, date} <- Date.from_iso8601(params["date"] || "") do
      service = %{
        feed: feed,
        trip: trip,
        date: date,
        seq: optional_int(params["seq"]),
        at: optional_int(params["at"])
      }

      case Services.show(service) do
        {:ok, result} ->
          conn
          # Live times change by the minute; the map asks again on its own.
          |> put_resp_header("cache-control", "no-store")
          |> json(result)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Service #{trip} not found."})
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Name the service as feed=12&trip=T1&date=2026-10-26."})
    end
  end

  @doc """
  `/api/service/path?feed=12&trip=T1`: the track a service runs, as GeoJSON
  (see `Transitmaps.Services.path/1`), for the map to pick it out.
  """
  def path(conn, params) do
    with {:ok, feed} <- positive_int(params["feed"]),
         trip when is_binary(trip) and trip != "" <- params["trip"] do
      case Services.path(%{feed: feed, trip: trip}) do
        {:ok, collection} ->
          conn
          # A trip's track only changes with an import.
          |> put_resp_header("cache-control", "public, max-age=3600")
          |> json(collection)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Service #{trip} not found."})
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Name the service as feed=12&trip=T1."})
    end
  end

  defp positive_int(value) do
    case optional_int(value) do
      int when is_integer(int) and int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp optional_int(_value), do: nil
end
