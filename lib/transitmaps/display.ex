defmodule Transitmaps.Display do
  @moduledoc """
  Turns imported GTFS routes into the lines the map draws.

  Feeds describe timetables, not maps: one operator arrives as dozens of
  route entries that all re-trace the same corridor. `Identity` answers
  which lines exist, with a display name and colour for each.

  Each line is then drawn as one line along its route, the way a single
  service is picked out: feeds keep a shape per direction and per service
  pattern, each on its own track (the Elizabeth line's eastbound and
  westbound bores, a platform either side of a station), which drawn
  together run as two lines side by side. Where a line's strands run within
  a few metres of track already kept they are dropped, so only branches and
  diverging track add to it. What is kept is source geometry: no vertex is
  moved, lines sharing track are drawn on top of one another, and track
  several lines run is drawn once by each.
  """

  alias Transitmaps.Display.Identity
  alias Transitmaps.Geometry

  # Strands of one line running this close are one route drawn twice: two
  # tracks, two tunnel bores, or the platforms either side of a station.
  @parallel_km 0.15

  # A strand this short that never leaves the rest of its line by more than
  # `@sliver_shadow_km` is a platform loop or turnback beside it, not a
  # branch.
  @sliver_km 1.0
  @sliver_shadow_km 0.25

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
    |> Enum.map(fn line -> update_in(line.geometry.coordinates, &one_line/1) end)
  end

  # Exact repeats go first, which leaves a fraction of the strands to
  # compare. A strand that reverses (a train out and back along one track)
  # is split there, so its return leg can be dropped like any other repeat.
  defp one_line(strands) do
    strands = Geometry.drop_retraced_segments(strands)
    vertices = strands |> Enum.concat() |> MapSet.new()

    strands
    |> Enum.flat_map(&Geometry.split_at_reversals/1)
    |> Geometry.extract_network_lines(@parallel_km)
    |> Geometry.drop_short_shadows(@sliver_km, @sliver_shadow_km)
    |> Enum.map(&source_points(&1, vertices))
  end

  # Comparing adds a point every `@parallel_km` along the track it keeps.
  # Those go again, but for a branch's ends, which join it to the line.
  defp source_points([first | rest], vertices) do
    {middle, [last]} = Enum.split(rest, -1)
    [first | Enum.filter(middle, &MapSet.member?(vertices, &1))] ++ [last]
  end
end
