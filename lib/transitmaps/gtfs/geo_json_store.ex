defmodule Transitmaps.Gtfs.GeoJsonStore do
  @moduledoc """
  Keeps the map's GeoJSON responses in the database, so a restart (every
  deploy) doesn't send the first visitors to each area back to waiting
  seconds for them to be built (`Transitmaps.Gtfs.GeoJsonCache` keeps
  responses in memory only).

  Every response is kept, however quickly it was built: a cell of a city's
  lines takes milliseconds once the agency's lines are in memory, but
  after a restart they aren't, and the first cell asked for waits for
  them. A response is stored gzipped, as most visitors take it. Rows not
  built again for `@keep_days` (no one has looked there) are pruned.

  `@format` is part of every key: change it when the responses change
  shape, so a deploy doesn't serve the old shape to the new map.
  """

  import Ecto.Query

  require Logger

  alias Transitmaps.Gtfs.GeoJsonResponse
  alias Transitmaps.Repo

  @format 1
  @keep_days 14

  @doc """
  The stored response for cache key `key`, as `{body, gzipped, etag}` and
  how old it is in milliseconds, or nil.
  """
  def get(key) do
    from(r in GeoJsonResponse,
      where: r.key == ^hash(key),
      select: {r.gzipped, r.etag, r.built_at}
    )
    |> Repo.one()
    |> case do
      {gzipped, etag, built_at} ->
        age_ms = DateTime.diff(DateTime.utc_now(), built_at, :millisecond)
        {{:zlib.gunzip(gzipped), gzipped, etag}, max(age_ms, 0)}

      nil ->
        nil
    end
  rescue
    # A store that can't be read is a cache miss, not a failed request.
    error ->
      Logger.warning("GeoJSON store not read: #{Exception.message(error)}")
      nil
  end

  @doc "Stores response `{body, gzipped, etag}` for cache key `key`."
  def put(key, {_body, gzipped, etag}) do
    Repo.insert_all(
      GeoJsonResponse,
      [%{key: hash(key), gzipped: gzipped, etag: etag, built_at: DateTime.utc_now(:second)}],
      on_conflict: {:replace, [:gzipped, :etag, :built_at]},
      conflict_target: :key
    )

    :ok
  rescue
    error ->
      Logger.warning("GeoJSON store not written: #{Exception.message(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("GeoJSON store not written: #{inspect(reason, limit: 5)}")
      :error
  end

  @doc "Deletes responses no one has asked to be built again for a while."
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@keep_days, :day)
    {count, _} = Repo.delete_all(from r in GeoJsonResponse, where: r.built_at < ^cutoff)
    count
  end

  defp hash(key),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({@format, key}, [:deterministic]))
end
