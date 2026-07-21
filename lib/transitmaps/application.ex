defmodule Transitmaps.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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
      {Task, &Transitmaps.Gtfs.GeoJsonCache.warm/0}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Transitmaps.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TransitmapsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
