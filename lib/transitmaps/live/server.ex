defmodule Transitmaps.Live.Server do
  @moduledoc """
  Background poller for real-time train positions.

  On start it loads each tracked line's station graph (refreshed rarely), then
  polls live arrivals on a short interval, derives positions, and publishes the
  latest features per region into the `Transitmaps.Live` ETS cache. Every live
  call is wrapped so a flaky upstream feed degrades to the last known positions
  (or nothing) instead of taking the process down.

  Currently only the London (TfL) provider is wired, feeding the
  `great-britain` region. National Rail needs a credentialed upstream and
  slots in here alongside TfL once configured.
  """

  use GenServer
  require Logger

  alias Transitmaps.Live
  alias Transitmaps.Live.Tfl

  @region "great-britain"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(Live.table(), [:named_table, :public, :set, read_concurrency: true])

    config = Application.get_env(:transitmaps, __MODULE__, [])

    state = %{
      enabled: Keyword.get(config, :enabled, true),
      poll_interval: Keyword.get(config, :poll_interval, :timer.seconds(15)),
      graph_interval: Keyword.get(config, :graph_interval, :timer.hours(6)),
      lines: [],
      graphs: %{}
    }

    if state.enabled, do: send(self(), :refresh_graphs)

    {:ok, state}
  end

  @impl true
  def handle_info(:refresh_graphs, state) do
    state = refresh_graphs(state)
    Process.send_after(self(), :refresh_graphs, state.graph_interval)
    send(self(), :poll)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    poll(state)
    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, state}
  end

  defp refresh_graphs(state) do
    case safely(&Tfl.fetch_lines/0) do
      {:ok, lines} when is_list(lines) ->
        graphs =
          lines
          |> Task.async_stream(
            fn line -> {line.id, safely(fn -> Tfl.fetch_graph(line.id) end)} end,
            max_concurrency: 4,
            timeout: 30_000,
            on_timeout: :kill_task
          )
          |> Enum.reduce(%{}, fn
            {:ok, {id, {:ok, graph}}}, acc -> Map.put(acc, id, graph)
            _other, acc -> acc
          end)

        %{state | lines: lines, graphs: graphs}

      other ->
        Logger.warning("TfL live station graph refresh failed: #{inspect(other)}")
        state
    end
  end

  defp poll(%{lines: []}), do: :ok

  defp poll(state) do
    features =
      state.lines
      |> Task.async_stream(&line_vehicles(&1, state.graphs),
        max_concurrency: 6,
        timeout: 20_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, features} -> features
        _other -> []
      end)

    Live.put(@region, features)
    :ok
  end

  defp line_vehicles(line, graphs) do
    case Map.fetch(graphs, line.id) do
      {:ok, graph} ->
        case safely(fn -> Tfl.fetch_vehicles(line, graph) end) do
          {:ok, features} -> features
          _other -> []
        end

      :error ->
        []
    end
  end

  # Any upstream call can raise (transport error, unexpected shape); keep the
  # poller alive and treat a failure as "no update" for that line.
  defp safely(fun) do
    try do
      fun.()
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
