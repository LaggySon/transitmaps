defmodule Transitmaps.Gtfs.Cells do
  @moduledoc """
  Serves a zoomed-in map only the part of an agency's lines and stations
  that falls in the area it shows.

  A national network's lines run the length of a country, and one train to
  Paris makes the whole network relevant there: sent whole, Paris at street
  zoom came to over 80 MB. So below the low detail, the map asks for its
  view in grid cells (`@line_cells` degrees for each line detail,
  `@stop_cells` for stations) and each cell carries only the stretches of
  line that cross it, and only the stations inside it.

  Cutting a cell starts from the agency's whole collection, which takes
  seconds to build for a big network. It is built once per agency, mode and
  detail and kept in `GeoJsonCache.fetch_term/2` in a compact form:
  coordinates packed into binaries, which ETS shares rather than copies,
  and properties already encoded as JSON. Cells are then cheap to cut, and
  their responses are cached like any other.
  """

  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.GeoJsonCache

  # Cell sizes in degrees. A cell holds a few views' worth at its zoom band
  # (mid detail is zoom 8 to 11, full detail from 11; stations from 10).
  @line_cells %{mid: 4, full: 1}
  @stop_cells 1

  # A stretch of line is kept when it comes this close to its cell (in
  # degrees, about 200 m), so neighbouring cells' stretches overlap a little
  # and the line has no gaps at their edges.
  @margin 0.002

  @doc """
  Parses a cell parameter, `"x,y"`: the cell's column and row in the grid
  of its size, counted from 0°, 0°. Anything else is nil.
  """
  def parse(param) when is_binary(param) do
    with [x, y] <- String.split(param, ","),
         {x, ""} <- Integer.parse(x),
         {y, ""} <- Integer.parse(y),
         true <- x in -180..179 and y in -90..89 do
      {x, y}
    else
      _ -> nil
    end
  end

  def parse(_param), do: nil

  @doc "Feed `feed_id`'s lines in `categories` at `detail`, as far as they cross `cell`."
  def routes(categories, feed_id, detail, cell) do
    {west, south, east, north} = box(cell, Map.fetch!(@line_cells, detail))
    box = {west - @margin, south - @margin, east + @margin, north + @margin}

    lines =
      GeoJsonCache.fetch_term({{:route_lines, detail}, feed_id, Enum.sort(categories)}, fn ->
        categories |> Gtfs.route_feature_collection(feed_id, detail) |> pack_lines()
      end)

    for {properties, strands} <- lines,
        stretches = Enum.flat_map(strands, &stretches(&1, box)),
        stretches != [] do
      line_json(properties, stretches)
    end
    |> collection()
  end

  @doc "Feed `feed_id`'s stations serving `categories` inside `cell`."
  def stops(categories, feed_id, cell) do
    {west, south, east, north} = box(cell, @stop_cells)

    stops =
      GeoJsonCache.fetch_term({:stop_points, feed_id, Enum.sort(categories)}, fn ->
        categories |> Gtfs.stop_feature_collection(feed_id) |> pack_stops()
      end)

    # Half-open, so a station on a cell's edge is in exactly one cell.
    for {lon, lat, json} <- stops, lon >= west and lon < east and lat >= south and lat < north do
      json
    end
    |> collection()
  end

  defp box({x, y}, size), do: {x * size, y * size, (x + 1) * size, (y + 1) * size}

  # -- the compact form ---------------------------------------------------------

  # Each line as its encoded properties and its strands, each strand with
  # its bounding box (to skip it whole) and its coordinates as 64-bit floats.
  defp pack_lines(%{features: features}) do
    for %{geometry: %{coordinates: strands}, properties: properties} <- features do
      {Jason.encode!(properties),
       for(strand <- strands, length(strand) >= 2, do: pack_strand(strand))}
    end
  end

  defp pack_strand(points) do
    {lons, lats} = points |> Enum.map(fn [lon, lat] -> {lon / 1, lat / 1} end) |> Enum.unzip()
    bounds = {Enum.min(lons), Enum.min(lats), Enum.max(lons), Enum.max(lats)}
    {bounds, for([lon, lat] <- points, into: <<>>, do: <<lon / 1::float-64, lat / 1::float-64>>)}
  end

  defp pack_stops(%{features: features}) do
    for %{geometry: %{coordinates: [lon, lat]}} = feature <- features do
      {lon, lat, Jason.encode!(feature)}
    end
  end

  # -- cutting ------------------------------------------------------------------

  # The runs of a strand's segments that overlap the box, each as a list of
  # points. A segment counts when its own bounding box overlaps, which errs
  # towards keeping a little more.
  defp stretches({{min_lon, min_lat, max_lon, max_lat}, _points}, {west, south, east, north})
       when min_lon > east or max_lon < west or min_lat > north or max_lat < south,
       do: []

  defp stretches({_bounds, <<lon::float-64, lat::float-64, rest::binary>>}, box) do
    walk(rest, {lon, lat}, box, [], [])
  end

  defp walk(<<>>, _previous, _box, run, runs), do: Enum.reverse(close(run, runs))

  defp walk(
         <<lon::float-64, lat::float-64, rest::binary>>,
         {plon, plat} = previous,
         box,
         run,
         runs
       ) do
    {west, south, east, north} = box
    point = {lon, lat}

    overlaps =
      min(lon, plon) <= east and max(lon, plon) >= west and min(lat, plat) <= north and
        max(lat, plat) >= south

    cond do
      overlaps and run == [] -> walk(rest, point, box, [point, previous], runs)
      overlaps -> walk(rest, point, box, [point | run], runs)
      true -> walk(rest, point, box, [], close(run, runs))
    end
  end

  defp close([], runs), do: runs
  defp close(run, runs), do: [Enum.reverse(run) | runs]

  # -- encoding -----------------------------------------------------------------

  defp line_json(properties, stretches) do
    [
      ~s({"type":"Feature","geometry":{"type":"MultiLineString","coordinates":[),
      stretches |> Enum.map(&stretch_json/1) |> Enum.intersperse(","),
      ~s(]},"properties":),
      properties,
      "}"
    ]
  end

  defp stretch_json(points) do
    ["[", points |> Enum.map(&point_json/1) |> Enum.intersperse(","), "]"]
  end

  defp point_json({lon, lat}) do
    [
      "[",
      :erlang.float_to_binary(lon, [:short]),
      ",",
      :erlang.float_to_binary(lat, [:short]),
      "]"
    ]
  end

  defp collection(features) do
    Jason.Fragment.new([
      ~s({"type":"FeatureCollection","features":[),
      Enum.intersperse(features, ","),
      "]}"
    ])
  end
end
