defmodule Mix.Tasks.Tfl.Import do
  use Mix.Task

  @shortdoc "Imports TfL Tube, DLR, Overground, Elizabeth line, and tram data"

  @moduledoc """
  Imports TfL rail-family data.

      mix tfl.import
      mix tfl.import --geometry tfl

  The default `osm` geometry follows detailed physical track alignments. Use
  `tfl` to try the simplified station-to-station line strings returned by the
  TfL Unified API.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [geometry: :string])

    if rest != [] do
      Mix.raise("Usage: mix tfl.import [--geometry osm|tfl]")
    end

    geometry_source = geometry_source!(opts[:geometry])

    Mix.Task.run("app.start")

    case Transitmaps.Gtfs.TflImporter.import(geometry_source: geometry_source) do
      {:ok, feed} -> Mix.shell().info("Feed #{feed.name} imported successfully.")
      {:error, reason} -> Mix.raise("TfL import failed: #{inspect(reason)}")
    end
  end

  defp geometry_source!(nil), do: :osm
  defp geometry_source!("osm"), do: :osm
  defp geometry_source!("tfl"), do: :tfl

  defp geometry_source!(source) do
    Mix.raise("Unknown TfL geometry source #{inspect(source)}; expected osm or tfl")
  end
end
