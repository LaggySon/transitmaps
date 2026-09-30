defmodule Transitmaps.Agencies.Worker do
  @moduledoc """
  Runs queued agency downloads one at a time, in the background.

  The queue lives in the `feed_imports` table, so a restart mid-download
  picks the agency back up instead of losing it. Each download runs in its
  own monitored process: a feed that crashes the importer fails that
  agency, not this worker. Every six hours the worker also queues agencies
  due their weekly refresh.
  """

  use GenServer
  require Logger

  alias Transitmaps.Agencies

  @refresh_check_ms :timer.hours(6)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Tells the worker an agency was queued. A no-op when it isn't running."
  def poke do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :poke)
    :ok
  end

  @impl true
  def init(nil), do: {:ok, %{running: nil}, {:continue, :start}}

  @impl true
  def handle_continue(:start, state) do
    Agencies.requeue_interrupted()
    Process.send_after(self(), :refresh_check, @refresh_check_ms)
    {:noreply, run_next(state)}
  end

  @impl true
  def handle_cast(:poke, state), do: {:noreply, run_next(state)}

  @impl true
  def handle_info(:refresh_check, state) do
    Agencies.queue_stale()
    Process.send_after(self(), :refresh_check, @refresh_check_ms)
    {:noreply, run_next(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: {key, ref}} = state) do
    if reason != :normal do
      Logger.error("Agency download #{key} crashed: #{inspect(reason, limit: 5)}")
      Agencies.mark_failed(key, "The import stopped unexpectedly")
    end

    {:noreply, run_next(%{state | running: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp run_next(%{running: nil} = state) do
    case Agencies.next_queued() do
      nil ->
        state

      feed_import ->
        {_pid, ref} = spawn_monitor(fn -> Agencies.run_import(feed_import.catalog_id) end)
        %{state | running: {feed_import.catalog_id, ref}}
    end
  end

  defp run_next(state), do: state
end
