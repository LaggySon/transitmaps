defmodule Transitmaps.DisplayTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Display
  alias Transitmaps.Display.Bundles
  alias Transitmaps.Display.Identity
  alias Transitmaps.Display.Network

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
  end

  describe "Identity.brand_color/2" do
    test "gives corridor-sharing operators distinct colours" do
      great_western = Identity.brand_color("Great Western Railway", "rail")
      southern = Identity.brand_color("Southern", "rail")

      assert great_western =~ ~r/^#[0-9A-F]{6}$/
      assert southern =~ ~r/^#[0-9A-F]{6}$/
      refute great_western == southern
    end

    test "matches the most specific operator name first" do
      refute Identity.brand_color("Great Northern", "rail") ==
               Identity.brand_color("Northern", "rail")

      refute Identity.brand_color("South Western Railway", "rail") ==
               Identity.brand_color("Southern", "rail")
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
    end

    test "sharp corners come back rounded" do
      corner = [[-1.0, 51.4], [-0.99, 51.4], [-0.99, 51.41]]

      assert %{coordinates: [strand]} =
               Network.clean(%{type: "MultiLineString", coordinates: [corner]})

      assert length(strand) > 3
      refute [-0.99, 51.4] in strand
    end
  end

  describe "Bundles.arrange/1" do
    test "corridor-sharing lines separate side by side" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]

      [first, second] = Bundles.arrange([line([corridor]), line([corridor])])

      gap = lateral_km(first, second, -0.8)
      assert_in_delta gap, 0.03, 0.008
    end

    test "lines running opposite directions still bundle to opposite sides" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]

      [first, second] = Bundles.arrange([line([corridor]), line([Enum.reverse(corridor)])])

      gap = lateral_km(first, second, -0.8)
      assert_in_delta gap, 0.03, 0.008
    end

    test "remaining lines collapse into the space a departing line leaves" do
      full = for i <- 0..150, do: [-1.0 + i * 0.004, 51.4]
      half = for i <- 0..75, do: [-1.0 + i * 0.004, 51.4]

      [first, _short, third] = Bundles.arrange([line([full]), line([half]), line([full])])

      # Three abreast on the shared half: outer lines sit a full spacing
      # apart on each side of the middle one.
      assert_in_delta lateral_km(first, third, -0.9), 0.06, 0.012

      # After the middle line leaves, the outer pair collapses to a single
      # spacing, centred on the corridor.
      assert_in_delta lateral_km(first, third, -0.5), 0.03, 0.008
    end

    test "bundle offsets taper smoothly, never jump" do
      full = for i <- 0..150, do: [-1.0 + i * 0.004, 51.4]
      half = for i <- 0..75, do: [-1.0 + i * 0.004, 51.4]

      [first | _rest] = Bundles.arrange([line([full]), line([half]), line([full])])
      [strand] = first.geometry.coordinates
      kx = 111.320 * :math.cos(51.4 * :math.pi() / 180)

      # Sideways drift per km travelled: a taper is a gentle ramp, a gap
      # left unfilled or a hard slot change would show as a steep step.
      slopes =
        strand
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [[lon1, lat1], [lon2, lat2]] ->
          dx = (lon2 - lon1) * kx
          dy = (lat2 - lat1) * @km_per_lat
          abs(dy) / max(abs(dx), 0.001)
        end)

      assert Enum.max(slopes) < 0.06
    end

    test "an isolated line keeps its centreline" do
      away = for i <- 0..100, do: [-1.0 + i * 0.004, 53.0]

      [only] = Bundles.arrange([line([away])])
      [strand] = only.geometry.coordinates

      assert hd(strand) == [-1.0, 53.0]
      assert List.last(strand) == [-0.6, 53.0]
      assert Enum.all?(strand, fn [_lon, lat] -> abs(lat - 53.0) * @km_per_lat < 0.001 end)
    end

    test "crossing lines keep their own centrelines" do
      west_east = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      south_north = for i <- 0..100, do: [-0.8, 51.2 + i * 0.004]

      [horizontal, vertical] = Bundles.arrange([line([west_east]), line([south_north])])

      [h_strand] = horizontal.geometry.coordinates
      [v_strand] = vertical.geometry.coordinates

      assert Enum.all?(h_strand, fn [_lon, lat] -> abs(lat - 51.4) * @km_per_lat < 0.002 end)
      assert Enum.all?(v_strand, fn [lon, _lat] -> abs(lon + 0.8) * 69.0 < 0.002 end)
    end
  end

  describe "Display.drawn_lines/1" do
    test "runs identity, cleanup, and bundling end to end" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      variant = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4003]

      lines =
        Display.drawn_lines([
          route("gw1", "Great Western Railway", [corridor], short_name: "GW1"),
          route("gw2", "Great Western Railway", [variant], short_name: "GW2"),
          route("xc1", "CrossCountry", [Enum.reverse(corridor)], short_name: "XC1")
        ])

      assert [%{name: "CrossCountry"}, %{name: "Great Western Railway"}] =
               Enum.sort_by(lines, & &1.name)

      [first, second] = lines
      gap = lateral_km(first, second, -0.8)
      assert_in_delta gap, 0.03, 0.01
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp route(id, agency, strands, opts \\ []) do
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

  defp line(strands) do
    %{geometry: %{type: "MultiLineString", coordinates: strands}}
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

  # Distance from a point to the nearest vertex of any strand; inputs use
  # dense vertices so vertex distance approximates line distance.
  defp within_km?([lon, lat], strands, tolerance_km) do
    kx = 111.320 * :math.cos(lat * :math.pi() / 180)

    Enum.any?(strands, fn strand ->
      Enum.any?(strand, fn [lon2, lat2] ->
        dx = (lon2 - lon) * kx
        dy = (lat2 - lat) * @km_per_lat
        :math.sqrt(dx * dx + dy * dy) <= tolerance_km
      end)
    end)
  end
end
