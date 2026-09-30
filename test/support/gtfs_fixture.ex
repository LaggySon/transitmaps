defmodule Transitmaps.GtfsFixture do
  @moduledoc """
  Writes a tiny GTFS zip — one agency, one rail route, three stations — for
  tests that run the real importer end to end.
  """

  @doc "Writes the feed to `path` (relative to the project root) and returns it."
  def write!(path, opts \\ []) do
    agency = Keyword.get(opts, :agency, "Tiny Rail")
    stops = Keyword.get(opts, :stops, [{-0.20, 51.50}, {-0.10, 51.52}, {0.00, 51.54}])

    files = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\nA1,#{agency},https://example.com,Europe/London\n"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_long_name,route_type\nR1,A1,T1,Tiny Line,2\n"},
      {"trips.txt", "route_id,service_id,trip_id,direction_id\nR1,S1,T1,0\n"},
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
end
