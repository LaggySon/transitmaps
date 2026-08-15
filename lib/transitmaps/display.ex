defmodule Transitmaps.Display do
  @moduledoc """
  Turns imported GTFS routes into the lines the map draws.

  Feeds describe timetables, not maps: one operator arrives as dozens of
  route entries that all re-trace the same corridor, shapes carry platform
  tangles and reversals, and nothing says how lines sharing track should sit
  next to each other. The pipeline answers those questions in order, one
  stage per module:

    1. `Identity` — *which* lines exist: one drawn line per national-rail
       operator or per TfL-style line, with its display name and colour.
    2. `Network` — *what* geometry each line draws: its routes' shapes
       merged and cleaned into one tidy, high-fidelity course with rounded
       corners.
    3. `LineGraph` — *where the network actually is*: every line's course
       collapsed onto shared tracks, cut into edges that each carry a fixed
       set of lines. After this stage two operators along one railway are
       not two polylines that happen to be near each other; they are two
       lines on one edge.
    4. `Ordering` — *who is on the left*: the order the lines on each edge
       sit in across the corridor, chosen to minimise the crossings a
       reader sees at junctions.
    5. `Render` — *what to serve*: each line on the track it runs on,
       carrying the slot it holds across the bundle. The sideways shift is
       left to the renderer and applied in screen pixels, so a corridor
       looks the same at every zoom.
  """

  alias Transitmaps.Display.{Identity, LineGraph, Network, Ordering, Render}

  # Ribbon labels name the lines on the corridor, but a trunk route carries
  # ten operators and a label that lists them all is a wall of text no reader
  # gets through. Past this many, the rest are counted.
  @named_lines 3

  @doc """
  Drawn lines for `routes`, one feature per run of track a line holds a
  single slot along.

  Each carries the line's display identity plus `:slot` (its signed place
  across the bundle, for the renderer to turn into a sideways shift),
  `:bundle` (how many lines share the run) and a LineString `:geometry` on
  the shared track. Routes need `route_id`, `agency_name`, `short_name`,
  `long_name`, `category`, `color`, `text_color` and `geometry` keys. Output
  order and content are stable for identical input.
  """
  def drawn_lines(routes) do
    {lines, graph, orders} = arrange(routes)

    graph
    |> Render.runs(orders)
    |> Enum.map(fn run ->
      lines
      |> Map.fetch!(run.line)
      |> Map.merge(%{
        slot: run.slot,
        bundle: run.bundle,
        geometry: %{type: "LineString", coordinates: run.coordinates}
      })
    end)
  end

  @doc """
  The same network drawn as corridor ribbons: one segment per stretch of
  track, carrying the colours of every line that runs along it, in the order
  `drawn_lines/1` places them across the bundle.

  Where `drawn_lines/1` hands the renderer neighbouring lines to spread
  apart, this hands it one line to stripe.
  """
  def corridor_ribbons(routes) do
    {lines, graph, orders} = arrange(routes)

    graph
    |> Render.ribbons(orders)
    |> Enum.map(fn ribbon ->
      drawn = Enum.map(ribbon.lines, &Map.fetch!(lines, &1))

      first = List.first(drawn)

      %{
        coordinates: ribbon.coordinates,
        colors: Enum.map(drawn, & &1.color),
        name: label(Enum.map(drawn, & &1.name)),
        # The corridor's own colour, for a label that has to be one colour.
        color: Map.get(first, :color),
        category: Map.get(first, :category)
      }
    end)
  end

  defp arrange(routes) do
    lines =
      routes
      |> Identity.lines()
      |> Enum.map(&%{&1 | geometry: Network.clean(&1.geometry)})

    graph = LineGraph.build(lines)
    indexed = lines |> Enum.with_index() |> Map.new(fn {line, index} -> {index, line} end)

    {indexed, graph, Ordering.order(graph)}
  end

  defp label(names) do
    case Enum.split(Enum.uniq(names), @named_lines) do
      {named, []} -> Enum.join(named, " · ")
      {named, rest} -> Enum.join(named, " · ") <> " +#{length(rest)}"
    end
  end
end
