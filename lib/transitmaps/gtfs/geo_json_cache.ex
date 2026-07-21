defmodule Transitmaps.Gtfs.GeoJsonCache do
  @moduledoc """
  Serves the GeoJSON API from an ETS cache of pre-encoded response bodies.

  Building a feature collection walks every route's geometry (display
  cleanup, offset slots) and encodes megabytes of JSON; doing that on every
  request dominates the map's time to first paint. Each distinct request is
  built once, stored as encoded JSON alongside a gzipped variant and a
  strong ETag, and served straight from ETS until the next feed import
  invalidates the cache.
  """

  use GenServer

  @table __MODULE__

  # The categories the map loads by default (see MapLive).
  @warm_categories ~w(metro tram rail intercity ferry)

  # Imports usually run in their own VM against the shared database, where
  # this process's invalidation can't be reached, so entries also age out.
  @ttl_ms :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Pre-builds the responses the map requests on a default page load, so the
  first visitor after boot or import is served from cache too.
  """
  def warm do
    if enabled?() do
      Enum.each(@warm_categories, fn category ->
        fetch({:routes, [category]}, fn ->
          Transitmaps.Gtfs.route_feature_collection([category])
        end)

        fetch({:stops, [category]}, fn ->
          Transitmaps.Gtfs.stop_feature_collection([category])
        end)
      end)
    end

    :ok
  end

  @doc """
  Returns `{body, gzipped_body, etag}` for `key`, building the term to
  encode with `builder.()` on first use. The build runs in the calling
  process, so database ownership behaves as if the controller queried
  directly (which also keeps sandboxed tests working).
  """
  def fetch(key, builder) do
    if enabled?() do
      case :ets.lookup(@table, key) do
        [{^key, entry, inserted_at}] ->
          if fresh?(inserted_at), do: entry, else: rebuild(key, builder)

        [] ->
          rebuild(key, builder)
      end
    else
      build(builder)
    end
  end

  defp fresh?(inserted_at) do
    System.monotonic_time(:millisecond) - inserted_at < @ttl_ms
  end

  defp rebuild(key, builder) do
    entry = build(builder)
    GenServer.call(__MODULE__, {:put, key, entry})
    entry
  end

  @doc "Drops every cached response; called after a feed import rewrites data."
  def invalidate do
    if enabled?(), do: GenServer.call(__MODULE__, :invalidate)
    :ok
  end

  defp enabled? do
    Application.get_env(:transitmaps, :geojson_cache, true) and
      Process.whereis(__MODULE__) != nil
  end

  defp build(builder) do
    body = builder.() |> Jason.encode_to_iodata!() |> IO.iodata_to_binary()
    etag = Base.encode16(:erlang.md5(body), case: :lower)
    {body, :zlib.gzip(body), ~s("#{etag}")}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, key, entry}, _from, state) do
    :ets.insert(@table, {key, entry, System.monotonic_time(:millisecond)})
    {:reply, :ok, state}
  end

  def handle_call(:invalidate, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
