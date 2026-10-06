defmodule Transitmaps.GtfsFixture do
  @moduledoc """
  Writes a tiny GTFS zip — one agency, one rail route, three stations — for
  tests that run the real importer end to end. The route has a shape traced
  through its stations, the way a feed traces the track, unless
  `shapes: false`, or `shapes: :stop_to_stop` for a shape that only joins
  the stations with straight lines.
  """

  @doc "Writes the feed to `path` (relative to the project root) and returns it."
  def write!(path, opts \\ []) do
    agency = Keyword.get(opts, :agency, "Tiny Rail")
    stops = Keyword.get(opts, :stops, [{-0.20, 51.50}, {-0.10, 51.52}, {0.00, 51.54}])
    shapes = Keyword.get(opts, :shapes, true)

    files = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\nA1,#{agency},https://example.com,Europe/London\n"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_long_name,route_type\nR1,A1,T1,Tiny Line,2\n"},
      {"trips.txt",
       "route_id,service_id,trip_id,direction_id,shape_id\nR1,S1,T1,0,#{if shapes, do: "SH1"}\n"},
      {"stops.txt",
       "stop_id,stop_name,stop_lat,stop_lon,location_type\n" <>
         Enum.map_join(Enum.with_index(stops, 1), fn {{lon, lat}, i} ->
           "ST#{i},Station #{i},#{lat},#{lon},0\n"
         end)},
      {"stop_times.txt",
       "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <>
         Enum.map_join(1..length(stops), fn i ->
           "T1,08:0#{i}:00,08:0#{i}:00,ST#{i},#{i}\n"
         end)}
      | shapes_file(stops, shapes)
    ]

    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    {:ok, _path} =
      :zip.create(
        String.to_charlist(path),
        Enum.map(files, fn {name, body} -> {String.to_charlist(name), body} end)
      )

    path
  end

  defp shapes_file(_stops, false), do: []

  defp shapes_file(stops, :stop_to_stop), do: [shapes_txt(stops)]
  defp shapes_file(stops, true), do: [shapes_txt(traced(stops))]

  defp shapes_txt(points) do
    {"shapes.txt",
     "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n" <>
       Enum.map_join(Enum.with_index(points, 1), fn {{lon, lat}, i} ->
         "SH1,#{lat},#{lon},#{i}\n"
       end)}
  end

  # A point every few hundred metres between stations, swaying ~20 m either
  # side of the straight line the way surveyed track does.
  defp traced(stops) do
    legs =
      stops
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{lon1, lat1}, {lon2, lat2}] ->
        for step <- 0..49 do
          t = step / 50
          sway = if rem(step, 2) == 0, do: 0.0002, else: -0.0002
          {lon1 + (lon2 - lon1) * t, lat1 + (lat2 - lat1) * t + sway}
        end
      end)

    legs ++ [List.last(stops)]
  end
end
