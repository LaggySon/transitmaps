defmodule Transitmaps.Display.Network do
  @moduledoc """
  Cleans a drawn line's merged geometry into a tidy network.

  A line's routes arrive as overlapping service-pattern shapes: they
  re-trace the same track dozens of times, reverse at stations they call
  at, wander around platforms, and split into fragments. Cleaning keeps
  the high-fidelity track geometry (shapes are simplified to ~2.5 m at
  import and never coarsened here) while removing everything that is not
  the network itself: implausible connector jumps and reversal hairpins
  are split, small self-crossing loops spliced out, re-traced strands and
  platform-detour slivers dropped, fragments that continue one another
  stitched back together, and every corner rounded into an arc so nothing
  downstream ever meets a jagged vertex.
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

  # Corners round into arcs blending across up to this much track, so
  # parallel bundle lines stay evenly spaced through bends.
  @corner_radius_km 0.15

  def clean(%{type: "MultiLineString", coordinates: strands}) do
    %{type: "MultiLineString", coordinates: clean_strands(strands)}
  end

  def clean(geometry), do: geometry

  defp clean_strands(strands) do
    strands
    |> Enum.flat_map(&Geometry.split_long_segments(&1, @max_segment_km))
    |> Enum.flat_map(&Geometry.split_at_reversals/1)
    |> Enum.map(&Geometry.remove_small_loops/1)
    |> Geometry.stitch_lines(@stitch_km)
    |> Geometry.extract_network_lines(@near_duplicate_km)
    |> Geometry.drop_short_shadows(@stub_max_km, @stub_shadow_km)
    |> Geometry.stitch_lines(@stitch_km)
    |> Enum.map(&Geometry.round_corners(&1, @corner_radius_km))
    |> Enum.map(&normalize_direction/1)
  end

  # Orient every strand along its dominant axis (south-to-north or
  # west-to-east) so cleaned geometry is stable however the source shapes
  # were digitised. Bundling later re-orients strands per corridor; this
  # keeps cache keys and diffs deterministic.
  defp normalize_direction([[lon1, lat1] | _] = strand) do
    [lon2, lat2] = List.last(strand)

    forward? =
      if abs(lat2 - lat1) >= abs(lon2 - lon1) do
        lat2 >= lat1
      else
        lon2 >= lon1
      end

    if forward?, do: strand, else: Enum.reverse(strand)
  end

  defp normalize_direction(strand), do: strand
end
