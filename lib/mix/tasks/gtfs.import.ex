defmodule Mix.Tasks.Gtfs.Import do
  @shortdoc "Imports a GTFS feed: mix gtfs.import <name> <url-or-zip-path> [--label NAME]"

  @moduledoc """
  Imports (or re-imports) a GTFS feed into the database.

      mix gtfs.import gb-rail https://storage.travelwhiz.app/generated-gtfs/gb-nationalrail.gtfs.zip
      mix gtfs.import london-busmetro priv/gtfs_cache/uk-busmetro-SE.gtfs.zip --label "London Buses"

  Re-running with the same name replaces that feed's data. `--label` is what
  the map's agency list calls the feed; it defaults to the name (the curated
  feeds listed in the README have labels of their own). The map draws the
  feed wherever its stops are.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: [label: :string])

    case positional do
      [name, source] -> import_feed(name, source, opts)
      _ -> Mix.raise("Usage: mix gtfs.import <name> <url-or-zip-path> [--label NAME]")
    end
  end

  defp import_feed(name, source, opts) do
    Mix.Task.run("app.start")

    feed = if opts[:label], do: %{label: opts[:label]}, else: %{}

    case Transitmaps.Gtfs.Importer.import_feed(name, source, feed: feed) do
      {:ok, feed} -> Mix.shell().info("Feed #{feed.name} imported successfully.")
      {:error, reason} -> Mix.raise("Import failed: #{inspect(reason)}")
    end
  end
end
