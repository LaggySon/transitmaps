defmodule Mix.Tasks.Gtfs.Import do
  @shortdoc "Imports a GTFS feed: mix gtfs.import <name> <url-or-zip-path>"

  @moduledoc """
  Imports (or re-imports) a GTFS feed into the database.

      mix gtfs.import gb-rail https://storage.travelwhiz.app/generated-gtfs/gb-nationalrail.gtfs.zip
      mix gtfs.import london-busmetro priv/gtfs_cache/uk-busmetro-SE.gtfs.zip

  Re-running with the same name replaces that feed's data.
  """

  use Mix.Task

  @impl Mix.Task
  def run([name, source]) do
    Mix.Task.run("app.start")

    case Transitmaps.Gtfs.Importer.import_feed(name, source) do
      {:ok, feed} -> Mix.shell().info("Feed #{feed.name} imported successfully.")
      {:error, reason} -> Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix gtfs.import <name> <url-or-zip-path>")
  end
end
