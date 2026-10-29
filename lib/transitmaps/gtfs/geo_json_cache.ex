defmodule Transitmaps.Gtfs.GeoJsonCache do
  @moduledoc """
  Serves the GeoJSON API from an ETS cache of pre-encoded response bodies.

  Building a feature collection walks every route's geometry and encodes
  megabytes of JSON; doing that on every request dominates the map's time
  to first paint. Each distinct request is built once, stored as encoded
  JSON alongside a gzipped variant and a strong ETag, and served straight
  from ETS from then on.

  Responses are also kept in the database
  (`Transitmaps.Gtfs.GeoJsonStore`), so after a restart they are served
  from there rather than built again while a visitor waits.

  Once a response has been built, no visitor waits for it to be built
  again. When an entry ages out or an import invalidates it, requests keep
  getting the previous body while a rebuild runs in the background. Rebuilds
  run one at a time, so a burst of stale entries after an import never
  stacks several country-sized builds on top of each other.
  """

  use GenServer

  alias Transitmaps.Gtfs.GeoJsonStore

  @table __MODULE__
  @terms Module.concat(__MODULE__, Terms)

  # The categories the map loads by default (see MapLive).
  @warm_categories ~w(rail metro tram intercity ferry)

  # The map opens zoomed out, where it asks for low-detail lines and no
  # stations yet (see `detailForZoom` and `STOPS_MIN_ZOOM` in transit_map.js).
  @opening_detail :low

  # Imports usually run in their own VM against the shared database, where
  # this process's invalidation can't be reached, so entries also age out.
  @ttl_ms :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Where the map opens (see `DEFAULT_VIEW` in transit_map.js), as
  # [west, south, east, north]: the agencies it loads first.
  @opening_view {-8.8, 49.7, 2.1, 59.2}

  @doc """
  Pre-builds the responses the map requests on a default page load, so the
  first visitor after boot is served from cache too.
  """
  def warm do
    if enabled?() do
      GeoJsonStore.prune()

      {west, south, east, north} = @opening_view

      for %{id: feed_id, bounds: [[min_lon, min_lat], [max_lon, max_lat]]} <-
            Transitmaps.Agencies.list_feeds(),
          min_lon <= east and max_lon >= west and min_lat <= north and max_lat >= south,
          category <- @warm_categories do
        fetch({{:routes, @opening_detail}, feed_id, [category]}, fn ->
          Transitmaps.Gtfs.route_feature_collection([category], feed_id, @opening_detail)
        end)
      end
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
          case GeoJsonStore.get(key) do
            {entry, age_ms} ->
              GenServer.call(__MODULE__, {:put, key, entry, builder, age_ms})
              if age_ms >= @ttl_ms, do: GenServer.cast(__MODULE__, {:refresh, key})
              entry

            nil ->
              entry = build_and_keep(key, builder)
              GenServer.call(__MODULE__, {:put, key, entry, builder, 0})
              entry
          end
      end
    else
      build(builder)
    end
  end

  @doc "Whether a response for `key` is cached, fresh or not."
  def cached?(key), do: enabled?() and :ets.member(@table, key)

  @doc """
  Returns the term `builder.()` makes for `key`, kept as it is rather than
  encoded, for responses cut from it (`Transitmaps.Gtfs.Cells`). Large
  binaries inside it are shared with the table, not copied. A term older
  than the TTL, or invalidated, is built again by the next caller; callers
  arriving meanwhile wait for that build rather than repeat it.
  """
  def fetch_term(key, builder) do
    if enabled?() do
      case :ets.lookup(@terms, key) do
        [{^key, term, built_at}] when is_integer(built_at) ->
          if fresh?(built_at), do: term, else: build_term(key, builder)

        _ ->
          build_term(key, builder)
      end
    else
      builder.()
    end
  end

  # A first visit to a new area can ask for a dozen agencies' collections
  # at once, each a big query and seconds of work. Built all together they
  # starve each other of database connections until queries time out, so
  # only this many build at a time and the rest wait their turn.
  @concurrent_builds 2

  defp build_term(key, builder) do
    lock = {:building, key}

    if :ets.insert_new(@terms, {lock, nil, :building}) do
      try do
        term = with_build_slot(builder)
        :ets.insert(@terms, {key, term, System.monotonic_time(:millisecond)})
        term
      after
        :ets.delete(@terms, lock)
      end
    else
      await_term(key, builder, 600)
    end
  end

  defp with_build_slot(builder) do
    if :ets.update_counter(@terms, :builds, {3, 1}, {:builds, nil, 0}) <= @concurrent_builds do
      try do
        builder.()
      after
        :ets.update_counter(@terms, :builds, {3, -1})
      end
    else
      :ets.update_counter(@terms, :builds, {3, -1})
      Process.sleep(100)
      with_build_slot(builder)
    end
  end

  # Another process is building this term: wait for it, up to a minute,
  # then build it here after all.
  defp await_term(_key, builder, 0), do: with_build_slot(builder)

  defp await_term(key, builder, tries) do
    Process.sleep(100)

    case :ets.lookup(@terms, {:building, key}) do
      [] ->
        case :ets.lookup(@terms, key) do
          [{^key, term, built_at}] when is_integer(built_at) -> term
          _ -> build_term(key, builder)
        end

      _building ->
        await_term(key, builder, tries - 1)
    end
  end

  defp fresh?(:stale), do: false
  defp fresh?(built_at), do: System.monotonic_time(:millisecond) - built_at < @ttl_ms

  @doc """
  Marks cached responses stale after a feed import rewrites data — every
  one, or those whose key satisfies `affected?`. Visitors keep the
  previous responses until their rebuilds land.
  """
  def invalidate(affected? \\ fn _key -> true end) do
    if enabled?(), do: GenServer.call(__MODULE__, {:invalidate, affected?})
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

  # Builds the response, and keeps it in the database too. Storing runs on
  # its own, so no one waits for it (in tests it runs in place, so it
  # finishes inside the test's database sandbox).
  defp build_and_keep(key, builder) do
    entry = build(builder)

    if Application.get_env(:transitmaps, :geojson_store_async, true),
      do: Task.start(fn -> GeoJsonStore.put(key, entry) end),
      else: GeoJsonStore.put(key, entry)

    entry
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@terms, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{queue: [], rebuilding: nil}}
  end

  @impl true
  # `age_ms` is how long ago the entry was built: 0 unless it was kept in
  # the database from before.
  def handle_call({:put, key, entry, builder, age_ms}, _from, state) do
    :ets.insert(@table, {key, entry, System.monotonic_time(:millisecond) - age_ms, builder})
    {:reply, :ok, state}
  end

  def handle_call({:invalidate, affected?}, _from, state) do
    keys = @table |> :ets.select([{{:"$1", :_, :_, :_}, [], [:"$1"]}]) |> Enum.filter(affected?)
    Enum.each(keys, &:ets.update_element(@table, &1, {3, :stale}))

    # Kept terms go: the next cell built from one builds it again.
    @terms
    |> :ets.select([{{:"$1", :_, :"$2"}, [{:is_integer, :"$2"}], [:"$1"]}])
    |> Enum.reject(&(&1 == :builds))
    |> Enum.filter(affected?)
    |> Enum.each(&:ets.delete(@terms, &1))

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
        {_pid, monitor} =
          spawn_monitor(fn ->
            entry = build_and_keep(key, builder)
            GenServer.call(__MODULE__, {:put, key, entry, builder, 0}, :infinity)
          end)

        %{state | queue: queue, rebuilding: {key, monitor}}

      [] ->
        rebuild_next(%{state | queue: queue})
    end
  end

  defp rebuild_next(state), do: state
end
