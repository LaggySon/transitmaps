defmodule Transitmaps.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :transitmaps

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @gb_rail_url "https://storage.travelwhiz.app/generated-gtfs/gb-nationalrail.gtfs.zip"

  @doc """
  Re-imports the Great Britain data set (national rail GTFS plus TfL)
  from the deployed release, e.g.:

      bin/transitmaps eval "Transitmaps.Release.import_gb()"

  The running web VM serves cached GeoJSON; it picks up a re-import when
  the hourly cache age-out fires, or immediately after a restart.
  """
  def import_gb do
    import_gtfs("gb-rail", @gb_rail_url)
    import_tfl()
  end

  @doc ~S|Imports one GTFS feed: eval "Transitmaps.Release.import_gtfs(\"amtrak\", \"https://...zip\")"|
  def import_gtfs(name, source) do
    start_import_deps()
    Transitmaps.Gtfs.Importer.import_feed(name, source)
  end

  @doc ~S|Imports TfL lines from the TfL API and OSM: eval "Transitmaps.Release.import_tfl()"|
  def import_tfl do
    start_import_deps()
    Transitmaps.Gtfs.TflImporter.import()
  end

  # Importers need the repo and an HTTP client but not the web endpoint.
  defp start_import_deps do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:req)

    case Transitmaps.Repo.start_link(pool_size: 2) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
