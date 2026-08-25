defmodule Transitmaps.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @gb_rail_url "https://storage.travelwhiz.app/generated-gtfs/gb-nationalrail.gtfs.zip"
  @gb_refresh_delay :timer.minutes(10)
  @tfl_refresh_delay :timer.minutes(15)
  @tfl_preview_refresh_delay :timer.seconds(1)

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
      Supervisor.child_spec(
        {Task, &refresh_gb_rail_on_railway/0},
        id: :railway_gb_rail_refresh
      ),
      Supervisor.child_spec({Task, &refresh_tfl_on_railway/0}, id: :railway_tfl_refresh)
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Transitmaps.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp refresh_gb_rail_on_railway do
    if System.get_env("RAILWAY_ENVIRONMENT_NAME") do
      # Serve the persisted data and let the GeoJSON cache warm before a
      # large download/import consumes CPU and invalidates that cache.
      Process.sleep(@gb_refresh_delay)
      Logger.info("Refreshing Great Britain rail data after Railway startup")

      try do
        Transitmaps.Gtfs.Importer.import_feed("gb-rail", @gb_rail_url)
      rescue
        error ->
          Logger.error(
            "Great Britain rail startup refresh failed; keeping existing map data:\n" <>
              Exception.format(:error, error, __STACKTRACE__)
          )
      catch
        kind, reason ->
          Logger.error(
            "Great Britain rail startup refresh failed; keeping existing map data:\n" <>
              Exception.format(kind, reason, __STACKTRACE__)
          )
      end
    end
  end

  defp refresh_tfl_on_railway do
    if System.get_env("RAILWAY_ENVIRONMENT_NAME") do
      geometry_source = Transitmaps.Gtfs.TflImporter.configured_geometry_source!()

      # Stagger this behind the national feed so the two imports never fight
      # each other in production. PR previews use TfL's inexpensive line
      # strings and import immediately so the preview is useful when ready.
      Process.sleep(tfl_refresh_delay(geometry_source))
      Logger.info("Refreshing TfL data after Railway startup using #{geometry_source} geometry")

      try do
        Transitmaps.Gtfs.TflImporter.import(cache: false, geometry_source: geometry_source)
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

  defp tfl_refresh_delay(:tfl), do: @tfl_preview_refresh_delay
  defp tfl_refresh_delay(:osm), do: @tfl_refresh_delay

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TransitmapsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
