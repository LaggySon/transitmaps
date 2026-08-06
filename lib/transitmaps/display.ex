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
    3. `Bundles` — *who shares each run of track*: the corridor is read
       locally along every line, and the network comes back cut into
       segments, each carrying the lines that run along it and lying on
       that corridor's own centreline. The renderer spaces the members
       across it in screen pixels, which is the only way a bundle holds
       its shape at every zoom.
  """

  alias Transitmaps.Display.{Bundles, Identity, Network}

  @doc """
  Drawn lines for `routes`: display identity plus cleaned geometry, each on
  its own true centreline. The map draws `corridor_ribbons/1` instead, which
  is the same network cut into shared runs of track; this is the per-line
  view of it. Routes need `route_id`,
  `agency_name`, `short_name`, `long_name`, `category`, `color`,
  `text_color`, and `geometry` keys. Output order and content are stable
  for identical input.
  """
  def drawn_lines(routes) do
    cleaned_lines(routes)
  end

  @doc """
  The network cut into corridor ribbons: one segment per run of track,
  carrying the colours and names of every line that runs along it.

  This is what the map draws. The geometry stays where the track is and the
  renderer spaces the members across it in screen pixels, so a corridor holds
  its shape at every zoom.
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
