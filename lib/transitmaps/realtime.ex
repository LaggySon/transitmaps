defmodule Transitmaps.Realtime do
  @moduledoc """
  Live delays and cancellations for agencies that publish GTFS Realtime
  trip updates without a key: the feeds the catalog lists for them
  (`Transitmaps.Catalog.realtime/1`).

  A feed is fetched when a visitor opens one of its stations, and again
  when a station asks after `@fresh_ms`; nobody looking means no requests.
  While a refresh runs, the previous copy (up to `@usable_ms` old) is used,
  and a copy nobody has read for `@idle_ms` is dropped.

  Each fetch is indexed by trip (`Transitmaps.Realtime.GtfsRt.index/1`)
  into an ETS table under a new generation, which then replaces the old
  one, so a reader never sees a half-written feed. A trip's update is only
  read when a station shows that trip.

  With the cache off (in tests), each call fetches in the calling process.
  """

  use GenServer

  require Logger

  alias Transitmaps.{Agencies, Catalog}
  alias Transitmaps.Realtime.GtfsRt

  @trips __MODULE__.Trips
  @feeds __MODULE__.Feeds
  @tasks __MODULE__.Tasks

  @fresh_ms :timer.seconds(30)
  @usable_ms :timer.minutes(5)
  @idle_ms :timer.minutes(10)
  @retry_ms :timer.seconds(30)
  @wait_ms :timer.seconds(10)
  @sweep_ms :timer.minutes(1)

  # Agencies whose live trip ids are the tail of the timetable's: the NYC
  # Subway's timetable says "AFA25GEN-1092-Weekday-00_000600_1..S03R" for
  # the train its live feed calls "000600_1..S03R".
  @trip_id_tails ~w(mdb-516)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The supervisor fetches run under; start it before the cache."
  def tasks, do: @tasks

  @doc "The GTFS Realtime trip update URLs for `feed`, if its agency has any."
  def sources(feed) do
    case Agencies.catalog_id(feed) do
      nil -> []
      catalog_id -> Catalog.realtime(catalog_id)
    end
  end

  @doc """
  The key `feed`'s live updates file a timetable trip under.
  """
  def trip_key(feed, trip_id) do
    if Agencies.catalog_id(feed) in @trip_id_tails do
      case String.split(trip_id, "_", parts: 2) do
        [_prefix, tail] -> tail
        [whole] -> whole
      end
    else
      trip_id
    end
  end

  @doc """
  `feed`'s live updates for the trips `trip_ids` (timetable ids):
  `{:ok, updates, fetched_at}`, where `updates` maps each trip id that has
  any to its updates (`Transitmaps.Realtime.GtfsRt.trip_update/1`) and
  `fetched_at` is a Unix time; `:none` when the agency publishes no live
  feed; `:unavailable` when it couldn't be fetched.
  """
  def updates(feed, trip_ids) do
    case sources(feed) do
      [] -> :none
      urls -> if enabled?(), do: cached(feed, urls, trip_ids), else: direct(feed, urls, trip_ids)
    end
  end

  defp enabled? do
    Application.get_env(:transitmaps, :realtime_cache, true) and
      Process.whereis(__MODULE__) != nil
  end

  defp direct(feed, urls, trip_ids) do
    case fetch(urls) do
      {:ok, index} ->
        by_key = Enum.group_by(index, &elem(&1, 0), &Tuple.delete_at(&1, 0))
        {:ok, pick(feed, trip_ids, &Map.get(by_key, &1, [])), System.os_time(:second)}

      :error ->
        :unavailable
    end
  end

  defp cached(feed, urls, trip_ids) do
    now = System.monotonic_time(:millisecond)

    entry =
      case :ets.lookup(@feeds, feed.id) do
        [{_id, _gen, fetched_at, _fetched_unix, _used} = entry]
        when now - fetched_at < @fresh_ms ->
          entry

        [{_id, _gen, fetched_at, _fetched_unix, _used} = entry]
        when now - fetched_at < @usable_ms ->
          GenServer.cast(__MODULE__, {:refresh, feed.id, urls})
          entry

        _missing_or_old ->
          wait_for_fetch(feed.id, urls)
      end

    case entry do
      {id, gen, _fetched_at, fetched_unix, _used} ->
        :ets.update_element(@feeds, id, {5, now})

        lookup = fn key ->
          for {_key, start_date, update} <- :ets.lookup(@trips, {id, gen, key}),
              do: {start_date, update}
        end

        {:ok, pick(feed, trip_ids, lookup), fetched_unix}

      nil ->
        :unavailable
    end
  catch
    # A table dropped mid-read (the cache restarting) is a feed not
    # fetched yet.
    :error, :badarg -> :unavailable
    :exit, _reason -> :unavailable
  end

  defp wait_for_fetch(feed_id, urls) do
    case GenServer.call(__MODULE__, {:fetch, feed_id, urls}, @wait_ms + 1_000) do
      :ok ->
        case :ets.lookup(@feeds, feed_id) do
          [entry] -> entry
          [] -> nil
        end

      :error ->
        nil
    end
  end

  # Each trip's updates (one per day it runs, in a feed that files several),
  # read from the binary they were indexed as.
  defp pick(feed, trip_ids, lookup) do
    trip_ids
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn trip_id, acc ->
      case lookup.(trip_key(feed, trip_id)) do
        [] ->
          acc

        found ->
          Map.put(
            acc,
            trip_id,
            Enum.map(found, fn {_start_date, update} -> GtfsRt.trip_update(update) end)
          )
      end
    end)
  end

  # Every URL an agency publishes (the NYC Subway splits its lines across
  # eight), as one index. One failing doesn't hide the others.
  defp fetch(urls) do
    results =
      urls
      |> Task.async_stream(&fetch_one/1,
        timeout: @wait_ms,
        on_timeout: :kill_task,
        max_concurrency: 8
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, index}} -> [index]
        _failed -> []
      end)

    if results == [], do: :error, else: {:ok, Enum.concat(results)}
  end

  defp fetch_one(url) do
    options =
      [receive_timeout: @wait_ms - 1_000, retry: false, decode_body: false]
      |> Keyword.merge(Application.get_env(:transitmaps, __MODULE__, [])[:req_options] || [])

    case Req.get(url, options) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, GtfsRt.index(body)}

      other ->
        Logger.info(
          "Live trip updates not fetched from #{redact(url)}: #{inspect(other, limit: 3)}"
        )

        :error
    end
  rescue
    error ->
      Logger.info("Live trip updates unreadable from #{redact(url)}: #{Exception.message(error)}")
      :error
  end

  # Some listed URLs carry a public token; logs don't need it.
  defp redact(url), do: String.replace(url, ~r/\?.*$/, "")

  # -- the cache --------------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@trips, [:bag, :public, :named_table, read_concurrency: true])
    :ets.new(@feeds, [:set, :public, :named_table, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{running: %{}, waiting: %{}, failed: %{}, generation: 0}}
  end

  @impl true
  def handle_call({:fetch, feed_id, urls}, from, state) do
    if recently_failed?(state, feed_id) do
      {:reply, :error, state}
    else
      state = update_in(state.waiting[feed_id], &[from | &1 || []])
      {:noreply, start_fetch(state, feed_id, urls)}
    end
  end

  @impl true
  def handle_cast({:refresh, feed_id, urls}, state) do
    if recently_failed?(state, feed_id),
      do: {:noreply, state},
      else: {:noreply, start_fetch(state, feed_id, urls)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_fetch(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, finish_fetch(state, ref, :error)}
  end

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    for {feed_id, gen, _fetched_at, _fetched_unix, used} <- :ets.tab2list(@feeds),
        now - used > @idle_ms do
      :ets.delete(@feeds, feed_id)
      :ets.match_delete(@trips, {{feed_id, gen, :_}, :_, :_})
    end

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  defp recently_failed?(state, feed_id) do
    case state.failed do
      %{^feed_id => at} -> System.monotonic_time(:millisecond) - at < @retry_ms
      _ -> false
    end
  end

  defp start_fetch(state, feed_id, urls) do
    if Enum.any?(state.running, fn {_ref, {id, _gen}} -> id == feed_id end) do
      state
    else
      gen = state.generation + 1

      task =
        Task.Supervisor.async_nolink(@tasks, fn ->
          case fetch(urls) do
            {:ok, index} ->
              :ets.insert(
                @trips,
                for(
                  {trip_id, start_date, update} <- index,
                  do: {{feed_id, gen, trip_id}, start_date, update}
                )
              )

              :ok

            :error ->
              :error
          end
        end)

      %{state | generation: gen, running: Map.put(state.running, task.ref, {feed_id, gen})}
    end
  end

  defp finish_fetch(state, ref, result) do
    {{feed_id, gen}, running} = Map.pop(state.running, ref)
    {waiting, all_waiting} = Map.pop(state.waiting, feed_id, [])

    state =
      case result do
        :ok ->
          now = System.monotonic_time(:millisecond)

          previous = :ets.lookup(@feeds, feed_id)
          :ets.insert(@feeds, {feed_id, gen, now, System.os_time(:second), now})

          for {_id, old_gen, _fetched_at, _unix, _used} <- previous,
              do: :ets.match_delete(@trips, {{feed_id, old_gen, :_}, :_, :_})

          %{state | failed: Map.delete(state.failed, feed_id)}

        _error ->
          :ets.match_delete(@trips, {{feed_id, gen, :_}, :_, :_})
          %{state | failed: Map.put(state.failed, feed_id, System.monotonic_time(:millisecond))}
      end

    reply = if result == :ok, do: :ok, else: :error
    Enum.each(waiting, &GenServer.reply(&1, reply))
    %{state | running: running, waiting: all_waiting}
  end
end
