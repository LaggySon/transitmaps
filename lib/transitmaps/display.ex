defmodule Transitmaps.Display do
  @moduledoc """
  Turns imported GTFS routes into the lines the map draws.

  Feeds describe timetables, not maps: one operator arrives as dozens of
  route entries that all re-trace the same corridor, shapes carry
  platform tangles and reversals, and nothing says how lines sharing
  track should sit next to each other. The pipeline answers those three
  questions in order, one stage per module:

    1. `Identity` — *which* lines exist: one drawn line per national-rail
       operator or per TfL-style line, with its display name and colour.
    2. `Network` — *what* geometry each line draws: its routes' shapes
       merged and cleaned into one tidy, high-fidelity network with
       rounded corners. Rendered as-is this stage is the baseline map:
       every line on its true centreline, overlapping where track is
       shared.
    3. `Bundles` — *how* corridor-sharing lines sit together: bundle
       offsets are computed locally along each corridor and baked into
       the geometry, so lines render side by side, collapse smoothly into
       the space a departing line leaves behind, and the client draws
       plain lines with no renderer offset tricks.
  """

  alias Transitmaps.Display.{Bundles, Identity, Network}

  @doc """
  Drawn lines for `routes`: display identity plus bundle-offset geometry,
  ready to serve as GeoJSON features. Routes need `route_id`,
  `agency_name`, `short_name`, `long_name`, `category`, `color`,
  `text_color`, and `geometry` keys. Output order and content are stable
  for identical input.
  """
  def drawn_lines(routes) do
    routes
    |> cleaned_lines()
    |> Bundles.arrange()
  end

  @doc """
  The same network drawn as corridor ribbons: one segment per run of track,
  carrying the colours of every line that runs along it.

  Where `drawn_lines/1` moves lines apart so a shared corridor reads as
  several neighbouring lines, this keeps the geometry where the track is and
  leaves the renderer to draw it as one thicker line striped in those colours.
  """
  def corridor_ribbons(routes) do
    lines = cleaned_lines(routes)
    by_index = lines |> Enum.with_index() |> Map.new(fn {line, index} -> {index, line} end)

    lines
    |> Bundles.corridors()
    |> Enum.map(fn %{members: members, coordinates: coordinates} ->
      drawn = Enum.map(members, &Map.fetch!(by_index, &1))

      %{
        coordinates: coordinates,
        colors: Enum.map(drawn, & &1.color),
        names: Enum.map(drawn, & &1.name),
        category: drawn |> List.first() |> Map.get(:category)
      }
    end)
  end

  defp cleaned_lines(routes) do
    routes
    |> Identity.lines()
    |> Enum.map(&%{&1 | geometry: Network.clean(&1.geometry)})
  end
end
