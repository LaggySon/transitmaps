defmodule TransitmapsWeb.TileProxyController do
  @moduledoc """
  Proxies basemap resources (style, tiles, glyphs, sprites) from the upstream
  tile server through this app, with a disk cache.

  Browsers on some networks fail to fetch tile binaries directly (blocked or
  stalled by local web-protection software), while server-side HTTP is fine.
  Routing everything through localhost sidesteps that entirely and makes the
  map work offline once tiles are cached.
  """

  use TransitmapsWeb, :controller

  @upstream "https://tiles.openfreemap.org"
  @cache_dir Path.join(["priv", "tile_cache"])

  @content_types %{
    ".pbf" => "application/x-protobuf",
    ".png" => "image/png",
    ".json" => "application/json"
  }
  @default_content_type "application/json"

  def proxy(conn, %{"path" => segments}) do
    path = Enum.join(segments, "/")

    case fetch_cached(path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type(content_type_for(path))
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, body)

      {:error, status} ->
        send_resp(conn, status, "upstream error")
    end
  end

  defp fetch_cached(path) do
    cache_path = Path.join(@cache_dir, cache_key(path))

    case File.read(cache_path) do
      {:ok, body} -> {:ok, body}
      {:error, _} -> fetch_and_cache(path, cache_path)
    end
  end

  defp fetch_and_cache(path, cache_path) do
    # Wildcard route segments are already URI-decoded by Plug. Encode them
    # again before constructing the upstream URL (font names contain spaces).
    upstream_url = @upstream <> "/" <> URI.encode(path)

    case Req.get(upstream_url, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        File.mkdir_p!(Path.dirname(cache_path))
        File.write!(cache_path, body)
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        # Req auto-decodes JSON responses; re-encode for pass-through.
        encoded = Jason.encode!(body)
        File.mkdir_p!(Path.dirname(cache_path))
        File.write!(cache_path, encoded)
        {:ok, encoded}

      {:ok, %{status: status}} ->
        {:error, status}

      {:error, _reason} ->
        {:error, 502}
    end
  end

  # Flatten the path into one cache filename, keeping the extension so
  # content types survive the round trip.
  defp cache_key(path), do: String.replace(path, "/", "_")

  defp content_type_for(path) do
    Map.get(@content_types, Path.extname(path), @default_content_type)
  end
end
