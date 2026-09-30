defmodule Transitmaps.Display do
  @moduledoc """
  Turns imported GTFS routes into the lines the map draws.

  Feeds describe timetables, not maps: one operator arrives as dozens of
  route entries that all re-trace the same corridor. `Identity` answers
  which lines exist, with a display name and colour for each.

  No vertex is moved. A line draws its routes' source shapes as imported —
  platform tangles, reversals and all — with every line on its own
  centreline and lines sharing track drawn on top of one another. The one
  thing dropped is exact repetition: track a line's shapes re-trace is
  served once, which leaves the picture unchanged and keeps the response a
  browser downloads close to the size of the network it shows.
  """

  alias Transitmaps.Display.Identity
  alias Transitmaps.Geometry

  @doc """
  Drawn lines for `routes`: display identity over the routes' source
  geometry, ready to serve as GeoJSON features. Routes need `route_id`,
  `agency_name`, `short_name`, `long_name`, `category`, `color`,
  `text_color`, and `geometry` keys. Output order and content are stable
  for identical input.
  """
  def drawn_lines(routes) do
    routes
    |> Identity.lines()
    |> Enum.map(fn line ->
      update_in(line.geometry.coordinates, &Geometry.drop_retraced_segments/1)
    end)
  end
end
