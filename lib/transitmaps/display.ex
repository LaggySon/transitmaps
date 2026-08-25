defmodule Transitmaps.Display do
  @moduledoc """
  Turns imported GTFS routes into the continuous lines the map draws.

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
    3. The browser — *how* the line reads on the map: a dedicated layer
       stack supplies one shared-looking white casing and the solid route
       colour. Geometry stays on the geographic centreline.

  Keeping display geometry on its centreline is deliberate. A ground-metre
  offset can only look right at one zoom, and changing corridor membership
  forces an otherwise continuous route to step sideways. Those steps were
  the source of visible elbows and hairline gaps at busy junctions. Parallel
  physical tracks in the feed still remain parallel; genuinely shared track
  is allowed to overlap cleanly, as it does on a geographic transit map.
  """

  alias Transitmaps.Display.{Identity, Network}

  @doc """
  Drawn lines for `routes`: display identity plus cleaned centreline geometry,
  ready to serve as GeoJSON features. Routes need `route_id`,
  `agency_name`, `short_name`, `long_name`, `category`, `color`,
  `text_color`, and `geometry` keys. Output order and content are stable
  for identical input.
  """
  def drawn_lines(routes) do
    routes
    |> Identity.lines()
    |> Enum.map(&%{&1 | geometry: Network.clean(&1.geometry)})
  end
end
