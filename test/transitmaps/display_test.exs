defmodule Transitmaps.DisplayTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Display
  alias Transitmaps.Display.Identity
  alias Transitmaps.Display.Network
  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs.RouteTypes

  @km_per_lat 110.574

  describe "Identity.lines/1" do
    test "collapses an operator's routes into one line named for the operator" do
      corridor = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]
      variant = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4004]

      assert [line] =
               Identity.lines([
                 route("gw1", "Great Western Railway", [corridor], short_name: "GW1"),
                 route("gw2", "Great Western Railway", [variant], short_name: "GW2")
               ])

      assert line.name == "Great Western Railway"
      assert line.color == Identity.brand_color("Great Western Railway", "rail")
      assert length(line.geometry.coordinates) == 2
    end

    test "keeps differently coloured lines of one agency separate" do
      corridor = for i <- 0..40, do: [-1.0 + i * 0.005, 51.5]

      lines =
        Identity.lines([
          route("tfl:central", "Transport for London", [corridor],
            category: "metro",
            short_name: "Central",
            color: "#E32017"
          ),
          route("tfl:victoria", "Transport for London", [corridor],
            category: "metro",
            short_name: "Victoria",
            color: "#0098D4"
          )
        ])

      assert lines |> Enum.map(& &1.name) |> Enum.sort() == ["Central", "Victoria"]
      assert lines |> Enum.map(& &1.color) |> Enum.sort() == ["#0098D4", "#E32017"]
    end

    test "categories never merge even when agency and colour match" do
      corridor = for i <- 0..40, do: [-1.0 + i * 0.005, 51.5]

      lines =
        Identity.lines([
          route("r1", "Acme", [corridor], category: "rail", color: "#112233"),
          route("r2", "Acme", [corridor], category: "tram", color: "#112233")
        ])

      assert lines |> Enum.map(& &1.category) |> Enum.sort() == ["rail", "tram"]
    end

    test "merges a known named rail line across agency aliases" do
      western = for i <- 0..10, do: [-1.0 + i * 0.01, 51.4]
      eastern = for i <- 10..20, do: [-1.0 + i * 0.01, 51.4]

      assert [line] =
               Identity.lines([
                 route("elizabeth", "Elizabeth line", [western],
                   short_name: "Elizabeth line",
                   color: "#6950A1"
                 ),
                 route("tfl-elizabeth", "Transport for London", [eastern],
                   short_name: "Elizabeth line",
                   color: "#6950A1"
                 )
               ])

      assert line.name == "Elizabeth line"
      assert line.agency == "Elizabeth line"
      assert length(line.geometry.coordinates) == 2
    end

    test "merges a named Overground line across agency and colour aliases" do
      official = for i <- 0..20, do: [-0.05, 51.47 + i * 0.002]
      stale_alias = for i <- 0..20, do: [-0.049, 51.47 + i * 0.002]

      assert [line] =
               Identity.lines([
                 route("windrush", "Windrush", [stale_alias],
                   short_name: "Windrush",
                   color: "#C9423A"
                 ),
                 route("tfl-windrush", "Transport for London", [official],
                   short_name: "Windrush line",
                   color: "#DC241F"
                 )
               ])

      assert line.name == "Windrush"
      assert line.agency == "Windrush"
      assert line.color == "#DC241F"
      assert line.geometry.coordinates == [official]
    end
  end

  describe "Identity.brand_color/2" do
    test "uses canonical colours for every named Overground line" do
      expected = %{
        "Liberty" => "#61686B",
        "Lioness" => "#FFA600",
        "Mildmay" => "#006FE6",
        "Suffragette" => "#18A95B",
        "Weaver" => "#9B0058",
        "Windrush" => "#DC241F"
      }

      for {name, color} <- expected do
        assert Identity.brand_color(name, "rail") == color
        assert Identity.brand_color("#{name} line", "rail") == color
        assert Identity.brand_color("London Overground / #{name}", "rail") == color
      end
    end

    test "gives conventional National Rail operators one system colour" do
      great_western = Identity.brand_color("Great Western Railway", "rail")
      southern = Identity.brand_color("Southern", "rail")

      assert great_western =~ ~r/^#[0-9A-F]{6}$/
      assert great_western == RouteTypes.default_color("rail")
      assert southern == great_western
    end

    test "keeps similarly named National Rail operators as separate identities" do
      corridor = for i <- 0..10, do: [-1.0 + i * 0.01, 51.4]

      lines =
        Identity.lines([
          route("great-northern", "Great Northern", [corridor], []),
          route("northern", "Northern", [corridor], []),
          route("south-western", "South Western Railway", [corridor], []),
          route("southern", "Southern", [corridor], [])
        ])

      assert lines |> Enum.map(& &1.name) |> Enum.sort() ==
               ["Great Northern", "Northern", "South Western Railway", "Southern"]
    end

    test "only applies to rail-family categories" do
      assert Identity.brand_color("Southern Vectis", "bus") == nil
      assert Identity.brand_color("Great Western Railway", "ferry") == nil
    end

    test "unknown operators keep feed colours" do
      assert Identity.brand_color("Acme Trains", "rail") == nil
      assert Identity.brand_color(nil, "rail") == nil
    end
  end

  # The geometry contract: corridors draw as continuous strands (never
  # chains of dashes), cleanup never opens a gap in a route's coverage,
  # and re-traced track collapses to one strand.
  describe "Network.clean/1" do
    test "a fragmented corridor comes back as one unbroken strand" do
      fragments = [
        for(i <- 0..10, do: [-1.0 + i * 0.01, 51.4]),
        for(i <- 20..30, do: [-1.0 + i * 0.01, 51.4]),
        for(i <- 10..20, do: [-1.0 + i * 0.01, 51.4])
      ]

      assert %{coordinates: [strand]} =
               Network.clean(%{type: "MultiLineString", coordinates: fragments})

      assert hd(strand) == [-1.0, 51.4]
      assert List.last(strand) == [-0.7, 51.4]
    end

    test "an out-and-back tangle collapses to one strand without gaps" do
      east = for i <- 0..50, do: [-1.0 + i * 0.002, 51.4]
      back = for i <- 49..40//-1, do: [-1.0 + i * 0.002, 51.4]
      onward = for i <- 41..90, do: [-1.0 + i * 0.002, 51.4]
      shape = east ++ back ++ onward

      assert %{coordinates: strands} =
               Network.clean(%{type: "MultiLineString", coordinates: [shape]})

      for point <- shape do
        assert within_km?(point, strands, 0.3),
               "corridor point #{inspect(point)} lost by cleanup"
      end

      assert Enum.all?(strands, &(Geometry.split_at_reversals(&1) == [&1]))
    end

    test "sharp corners come back rounded" do
      corner = [[-1.0, 51.4], [-0.99, 51.4], [-0.99, 51.41]]

      assert %{coordinates: [strand]} =
               Network.clean(%{type: "MultiLineString", coordinates: [corner]})

      assert length(strand) > 3
      refute [-0.99, 51.4] in strand
    end

    test "a bend spread across dense samples receives a broad curve" do
      approach = for i <- 0..20, do: [-1.0 + i * 0.0005, 51.4]
      departure = for i <- 1..20, do: [-0.99, 51.4 + i * 0.0005]
      corner = [-0.99, 51.4]

      assert %{coordinates: [strand]} =
               Network.clean(%{type: "MultiLineString", coordinates: [approach ++ departure]})

      nearest_vertex = strand |> Enum.map(&point_distance_km(&1, corner)) |> Enum.min()

      assert nearest_vertex > 0.1
    end

    test "branches blend onto their trunk instead of ending at a right angle" do
      trunk = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      junction = [-0.9, 51.4]
      branch = [junction, [-0.9, 51.42], [-0.9, 51.45]]

      assert %{coordinates: strands} =
               Network.clean(%{type: "MultiLineString", coordinates: [trunk, branch]})

      curved_branch =
        Enum.find(strands, &(Enum.max(Enum.map(&1, fn [_lon, lat] -> lat end)) > 51.44))

      assert curved_branch
      refute junction in curved_branch
      assert Enum.any?(curved_branch, fn [_lon, lat] -> lat == 51.4 end)
    end
  end

  describe "Display.drawn_lines/1" do
    test "runs identity and cleanup without moving shared track off its centreline" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]

      lines =
        Display.drawn_lines([
          route("gw1", "Great Western Railway", [corridor], short_name: "GW1"),
          route("gw2", "Great Western Railway", [corridor], short_name: "GW2"),
          route("xc1", "CrossCountry", [Enum.reverse(corridor)], short_name: "XC1")
        ])

      assert [%{name: "CrossCountry"}, %{name: "Great Western Railway"}] =
               Enum.sort_by(lines, & &1.name)

      [first, second] = lines
      gap = lateral_km(first, second, -0.8)
      assert gap < 0.003
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp route(id, agency, strands, opts) do
    %{
      route_id: id,
      agency_name: agency,
      short_name: Keyword.get(opts, :short_name),
      long_name: Keyword.get(opts, :long_name),
      category: Keyword.get(opts, :category, "rail"),
      color: Keyword.get(opts, :color),
      text_color: Keyword.get(opts, :text_color),
      geometry: %{"type" => "MultiLineString", "coordinates" => strands}
    }
  end

  # Lateral distance in km between two lines' strands, sampled at the
  # vertex of each nearest to `longitude`.
  defp lateral_km(first, second, longitude) do
    abs(latitude_near(first, longitude) - latitude_near(second, longitude)) * @km_per_lat
  end

  defp latitude_near(%{geometry: %{coordinates: strands}}, longitude) do
    strands
    |> Enum.concat()
    |> Enum.min_by(fn [lon, _lat] -> abs(lon - longitude) end)
    |> Enum.at(1)
  end

  # Distance from a point to the nearest segment of any strand.
  defp within_km?([lon, lat], strands, tolerance_km) do
    kx = 111.320 * :math.cos(lat * :math.pi() / 180)

    Enum.any?(strands, fn strand ->
      Enum.any?(Enum.chunk_every(strand, 2, 1, :discard), fn [[lon1, lat1], [lon2, lat2]] ->
        ax = (lon1 - lon) * kx
        ay = (lat1 - lat) * @km_per_lat
        bx = (lon2 - lon) * kx
        by = (lat2 - lat) * @km_per_lat
        dx = bx - ax
        dy = by - ay
        denominator = dx * dx + dy * dy

        amount =
          if denominator == 0.0,
            do: 0.0,
            else: max(0.0, min(1.0, -(ax * dx + ay * dy) / denominator))

        :math.sqrt(:math.pow(ax + amount * dx, 2) + :math.pow(ay + amount * dy, 2)) <=
          tolerance_km
      end)
    end)
  end

  defp point_distance_km([lon1, lat1], [lon2, lat2]) do
    kx = 111.320 * :math.cos(lat1 * :math.pi() / 180)
    dx = (lon2 - lon1) * kx
    dy = (lat2 - lat1) * @km_per_lat
    :math.sqrt(dx * dx + dy * dy)
  end
end
