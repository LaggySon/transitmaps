defmodule Transitmaps.Display do
  @moduledoc """
  Turns imported GTFS routes into the lines the map draws.

  Feeds describe timetables, not maps: one operator arrives as dozens of
  route entries that all re-trace the same corridor. `Identity` answers
  which lines exist, with a display name and colour for each.

  Nothing is done to the geometry. A line draws its routes' source shapes
  exactly as imported — platform tangles, reversals, re-traced strands and
  all — with every line on its own centreline and lines sharing track drawn
  on top of one another. This is the bare network, the starting point that
  any rule about how track should be drawn has to improve on.
  """

  alias Transitmaps.Display.Identity

  @doc """
  Drawn lines for `routes`: display identity over the routes' source
  geometry, ready to serve as GeoJSON features. Routes need `route_id`,
  `agency_name`, `short_name`, `long_name`, `category`, `color`,
  `text_color`, and `geometry` keys. Output order and content are stable
  for identical input.
  """
  def drawn_lines(routes), do: Identity.lines(routes)
end
