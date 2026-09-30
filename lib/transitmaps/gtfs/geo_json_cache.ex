defmodule Transitmaps.Gtfs.GeoJsonCache do
  @moduledoc """
  Serves the GeoJSON API from an ETS cache of pre-encoded response bodies.

  Building a feature collection walks every route's geometry and encodes
  megabytes of JSON; doing that on every request dominates the map's time
  to first paint. Each distinct request is built once, stored as encoded
  JSON alongside a gzipped variant and a strong ETag, and served straight
  from ETS from then on.

  Once a response has been built, no visitor waits for it to be built
  again. When an entry ages out or an import invalidates it, requests keep
  getting the previous body while a rebuild runs in the background. Rebuilds
  run one at a time, so a burst of stale entries after an import never
  stacks several country-sized builds on top of each other.
  """

  use GenServer

  @table __MODULE__

  # The categories the map loads by default (see MapLive).
  @warm_categories ~w(rail metro tram intercity ferry)

  # Imports usually run in their own VM against the shared database, where
  # this process's invalidation can't be reached, so entries also age out.
  @ttl_ms :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Pre-builds the responses the map requests on a default page load, so the
  first visitor after boot is served from cache too.
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
  encode with `builder.()` on first use. That first build runs in the
  calling process, so database ownership behaves as if the controller
  queried directly (which also keeps sandboxed tests working). A stale
  entry is returned as-is and rebuilt in the background.
  """
  def fetch(key, builder) do
    if enabled?() do
      case :ets.lookup(@table, key) do
        [{^key, entry, built_at, _builder}] ->
          if not fresh?(built_at), do: GenServer.cast(__MODULE__, {:refresh, key})
          entry

        [] ->
          entry = build(builder)
          GenServer.call(__MODULE__, {:put, key, entry, builder})
          entry
      end
    else
      build(builder)
    end
  end

  defp fresh?(:stale), do: false
  defp fresh?(built_at), do: System.monotonic_time(:millisecond) - built_at < @ttl_ms

  @doc """
  Marks every cached response stale after a feed import rewrites data.
  Visitors keep the previous responses until their rebuilds land.
  """
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
    {:ok, %{queue: [], rebuilding: nil}}
  end

  @impl true
  def handle_call({:put, key, entry, builder}, _from, state) do
    :ets.insert(@table, {key, entry, System.monotonic_time(:millisecond), builder})
    {:reply, :ok, state}
  end

  def handle_call(:invalidate, _from, state) do
    keys = :ets.select(@table, [{{:"$1", :_, :_, :_}, [], [:"$1"]}])
    Enum.each(keys, &:ets.update_element(@table, &1, {3, :stale}))

    # A rebuild already under way may have read the data this import
    # replaced, so its key queues again too.
    {:reply, :ok, rebuild_next(%{state | queue: Enum.uniq(state.queue ++ keys)})}
  end

  @impl true
  def handle_cast({:refresh, key}, state) do
    {:noreply, key |> enqueue(state) |> rebuild_next()}
  end

  # The rebuild task stores its own result before exiting, so by the time
  # it is down the fresh entry is already being served.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{rebuilding: {_key, ref}} = state) do
    {:noreply, rebuild_next(%{state | rebuilding: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp enqueue(key, %{queue: queue, rebuilding: rebuilding} = state) do
    if key in queue or match?({^key, _ref}, rebuilding),
      do: state,
      else: %{state | queue: queue ++ [key]}
  end

  defp rebuild_next(%{rebuilding: nil, queue: [key | queue]} = state) do
    case :ets.lookup(@table, key) do
      [{^key, _entry, _built_at, builder}] ->
        {_pid, ref} =
          spawn_monitor(fn ->
            GenServer.call(__MODULE__, {:put, key, build(builder), builder}, :infinity)
          end)

        %{state | queue: queue, rebuilding: {key, ref}}

      [] ->
        rebuild_next(%{state | queue: queue})
    end
  end

  defp rebuild_next(state), do: state
end
