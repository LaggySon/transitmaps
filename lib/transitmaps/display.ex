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
    |> Identity.lines()
    |> Enum.map(&%{&1 | geometry: Network.clean(&1.geometry)})
    |> Bundles.arrange()
  end
end
