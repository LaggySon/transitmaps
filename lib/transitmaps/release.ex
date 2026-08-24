defmodule Transitmaps.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :transitmaps
  @preview_feeds ~w(gb-rail tfl)

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

  @doc """
  Populates an isolated Railway PR database before its web service starts.

  PR environments keep their database for subsequent pushes, so feeds that
  already imported successfully are left untouched. A brand-new environment
  imports the same Great Britain and TfL data used in production instead of
  serving an empty map until the delayed background refresh runs.
  """
  def bootstrap_preview do
    with_import_repo(fn ->
      existing_feeds =
        Transitmaps.Gtfs.Feed
        |> Transitmaps.Repo.all()
        |> Enum.map(& &1.name)

      existing_feeds
      |> missing_preview_feeds()
      |> Enum.each(&import_preview_feed/1)
    end)
  end

  @doc false
  def missing_preview_feeds(existing_feeds) do
    Enum.reject(@preview_feeds, &(&1 in existing_feeds))
  end

  @doc ~S|Imports one GTFS feed: eval "Transitmaps.Release.import_gtfs(\"amtrak\", \"https://...zip\")"|
  def import_gtfs(name, source) do
    with_import_repo(fn -> Transitmaps.Gtfs.Importer.import_feed(name, source) end)
  end

  @doc ~S|Imports TfL lines from the TfL API and OSM: eval "Transitmaps.Release.import_tfl()"|
  def import_tfl do
    with_import_repo(fn -> Transitmaps.Gtfs.TflImporter.import(cache: false) end)
  end

  defp import_preview_feed("gb-rail") do
    {:ok, _feed} = Transitmaps.Gtfs.Importer.import_feed("gb-rail", @gb_rail_url)
  end

  defp import_preview_feed("tfl") do
    {:ok, _feed} = Transitmaps.Gtfs.TflImporter.import(cache: false)
  end

  # `with_repo/3` starts every application the adapter requires, starts a
  # temporary Repo, and shuts it down after the import. Starting Repo directly
  # in a release skips those dependencies and makes pre-deploy imports fail.
  defp with_import_repo(importer) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:req)
    {:ok, result, _apps} = Ecto.Migrator.with_repo(Transitmaps.Repo, fn _repo -> importer.() end)
    result
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
