defmodule Transitmaps.Gtfs.DisplayGeometry do
  @moduledoc """
  Cleans stored route geometry into display-ready strands.

  A route's service-pattern strands (up to 6, see Importer) mostly re-trace
  the same track; where they reverse or pick different platforms they paint
  loops and tangles around stations, and splitting can leave a strand as a
  chain of fragments that renders as broken dashes. The pipeline splits
  implausible jumps and reversal hairpins, splices out small self-crossing
  loops, drops re-traced strands and platform-detour slivers, stitches back
  fragments that continue one another, and gives every strand one canonical
  direction so parallel offsets fan out to a consistent side.
  """

  alias Transitmaps.Geometry

  # Points further apart than this are malformed connector jumps, not track.
  @max_segment_km 25

  # Strands whose whole path stays within a platform's width of kept
  # geometry are re-traces, not branches.
  @near_duplicate_km 0.15

  # Slivers no longer than this that hug a longer strand the whole way are
  # platform detours around a station, not branches.
  @stub_max_km 1.0
  @stub_shadow_km 0.25

  # Fragments whose endpoints meet within this are one broken line.
  @stitch_km 0.05

  def prepare(%{"type" => "MultiLineString", "coordinates" => lines}) do
    %{"type" => "MultiLineString", "coordinates" => prepare_lines(lines)}
  end

  def prepare(%{type: "MultiLineString", coordinates: lines}) do
    %{type: "MultiLineString", coordinates: prepare_lines(lines)}
  end

  def prepare(geometry), do: geometry

  defp prepare_lines(lines) do
    lines
    |> Enum.flat_map(&Geometry.split_long_segments(&1, @max_segment_km))
    |> Enum.flat_map(&Geometry.split_at_reversals/1)
    |> Enum.map(&Geometry.remove_small_loops/1)
    |> Geometry.drop_redundant_lines(@near_duplicate_km)
    |> Geometry.drop_short_shadows(@stub_max_km, @stub_shadow_km)
    |> Geometry.stitch_lines(@stitch_km)
    |> Enum.map(&normalize_direction/1)
  end

  # MapLibre's line-offset shifts perpendicular to travel direction, so
  # strands running opposite ways offset to opposite sides. Orient every
  # strand along its dominant axis (south-to-north or west-to-east) so all
  # strands of a corridor — including corridor-sharing routes — offset the
  # same way. Comparing whole endpoints lexicographically would let a tiny
  # longitude wiggle flip a mostly north-south strand (and its offset)
  # across the corridor.
  defp normalize_direction([[lon1, lat1] | _] = line) do
    [lon2, lat2] = List.last(line)

    forward? =
      if abs(lat2 - lat1) >= abs(lon2 - lon1) do
        lat2 >= lat1
      else
        lon2 >= lon1
      end

    if forward?, do: line, else: Enum.reverse(line)
  end

  defp normalize_direction(line), do: line
end
