defmodule Mix.Tasks.Tfl.Import do
  use Mix.Task

  @shortdoc "Imports TfL Tube, DLR, Overground, Elizabeth line, and tram data"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Transitmaps.Gtfs.TflImporter.import() do
      {:ok, feed} -> Mix.shell().info("Feed #{feed.name} imported successfully.")
      {:error, reason} -> Mix.raise("TfL import failed: #{inspect(reason)}")
    end
  end
end
