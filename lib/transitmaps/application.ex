defmodule Transitmaps.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      TransitmapsWeb.Telemetry,
      Transitmaps.Repo,
      Transitmaps.Gtfs.GeoJsonCache,
      {DNSCluster, query: Application.get_env(:transitmaps, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Transitmaps.PubSub},
      # Start a worker by calling: Transitmaps.Worker.start_link(arg)
      # {Transitmaps.Worker, arg},
      # Start to serve requests, typically the last entry
      TransitmapsWeb.Endpoint,
      # Pre-build the default map responses so the first visit is cached too
      Supervisor.child_spec(
        {Task, &Transitmaps.Gtfs.GeoJsonCache.warm/0},
        id: :geo_json_cache_warm
      ),
      # Railway data refreshes depend on live third-party APIs, so run them
      # after startup instead of making them a deployment gate.
      Supervisor.child_spec({Task, &refresh_tfl_on_railway/0}, id: :railway_tfl_refresh)
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Transitmaps.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp refresh_tfl_on_railway do
    if System.get_env("RAILWAY_ENVIRONMENT_NAME") do
      Logger.info("Refreshing TfL data after Railway startup")

      try do
        Transitmaps.Gtfs.TflImporter.import(cache: false)
      rescue
        error ->
          Logger.error(
            "TfL startup refresh failed; keeping existing map data:\n" <>
              Exception.format(:error, error, __STACKTRACE__)
          )
      catch
        kind, reason ->
          Logger.error(
            "TfL startup refresh failed; keeping existing map data:\n" <>
              Exception.format(kind, reason, __STACKTRACE__)
          )
      end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TransitmapsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
