defmodule Transitmaps.Gtfs.Csv do
  @moduledoc """
  Streaming reader for GTFS CSV files.

  GTFS files are plain RFC4180 CSVs with a header row. This module streams
  them as maps keyed by header name so callers never deal with positional
  columns, and strips the UTF-8 BOM some feeds prepend to the header.
  """

  NimbleCSV.define(__MODULE__.Parser, separator: ",", escape: "\"")

  @doc """
  Streams `filename` inside `dir` as maps of `%{"header" => "value"}`.

  Returns an empty stream when the file does not exist, since most GTFS
  files are optional.
  """
  def stream(dir, filename) do
    path = Path.join(dir, filename)

    if File.exists?(path) do
      path
      |> File.stream!(read_ahead: 100_000)
      # A few otherwise-valid public feeds leave spaces after the final
      # quoted field. RFC4180 parsers reject that, so normalize line endings
      # and trailing whitespace before parsing.
      |> Stream.map(&(String.trim_trailing(&1) <> "\n"))
      |> __MODULE__.Parser.parse_stream(skip_headers: false)
      |> Stream.transform(nil, &zip_row_with_headers/2)
    else
      Stream.map([], & &1)
    end
  end

  defp zip_row_with_headers(header_row, nil) do
    {[], Enum.map(header_row, &strip_bom/1)}
  end

  defp zip_row_with_headers(row, headers) do
    {[headers |> Enum.zip(row) |> Map.new()], headers}
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF>> <> header), do: header
  defp strip_bom(header), do: header
end
