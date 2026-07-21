defmodule Transitmaps.GtfsTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.DisplayGeometry
  alias Transitmaps.Gtfs.OffsetSlots
  alias Transitmaps.Gtfs.OperatorColors
  alias Transitmaps.Gtfs.Stop
  alias Transitmaps.Gtfs.RouteTypes

  describe "RouteTypes.category/1" do
    test "maps basic GTFS route types" do
      assert RouteTypes.category(0) == "tram"
      assert RouteTypes.category(1) == "metro"
      assert RouteTypes.category(2) == "rail"
      assert RouteTypes.category(3) == "bus"
      assert RouteTypes.category(4) == "ferry"
    end

    test "maps extended route types" do
      assert RouteTypes.category(101) == "intercity"
      assert RouteTypes.category(106) == "rail"
      assert RouteTypes.category(200) == "coach"
      assert RouteTypes.category(401) == "metro"
      assert RouteTypes.category(700) == "bus"
      assert RouteTypes.category(900) == "tram"
    end

    test "unknown types fall back to other" do
      assert RouteTypes.category(9999) == "other"
      assert RouteTypes.category(nil) == "other"
    end

    test "every category has a default color" do
      for category <- RouteTypes.categories() do
        assert RouteTypes.default_color(category) =~ ~r/^#[0-9A-F]{6}$/
      end
    end
  end

  describe "Gtfs.sanitize_categories/1" do
    test "keeps only known categories" do
      assert Gtfs.sanitize_categories("rail,metro,junk") == ["rail", "metro"]
    end

    test "handles empty and non-string input" do
      assert Gtfs.sanitize_categories("") == []
      assert Gtfs.sanitize_categories(nil) == []
      assert Gtfs.sanitize_categories(%{}) == []
    end

    test "deduplicates" do
      assert Gtfs.sanitize_categories("bus,bus") == ["bus"]
    end
  end

  describe "Gtfs.merge_colocated_stops/1" do
    test "combines lines and categories from colocated operator feeds" do
      amtrak = %Stop{
        name: "New York Penn Station",
        lat: 40.7505,
        lon: -73.99342,
        categories: ["intercity"],
        lines: [%{name: "Northeast Regional", agency: "Amtrak", color: "#006DB8"}]
      }

      nj_transit = %Stop{
        name: "Penn Station New York",
        lat: 40.7506,
        lon: -73.99344,
        categories: ["rail"],
        lines: [%{name: "Northeast Corridor", agency: "NJ Transit", color: "#F06824"}]
      }

      assert [station] = Gtfs.merge_colocated_stops([amtrak, nj_transit])
      assert Enum.sort(station.categories) == ["intercity", "rail"]
      assert length(station.lines) == 2
    end

    test "does not combine stations in different grid cells" do
      first = %Stop{name: "First", lat: 40.0, lon: -74.0, categories: ["rail"], lines: []}
      second = %Stop{name: "Second", lat: 40.01, lon: -74.01, categories: ["rail"], lines: []}

      assert length(Gtfs.merge_colocated_stops([first, second])) == 2
    end
  end

  # Raw GTFS routes are not what the map draws: an operator's dozens of
  # timetabled routes share one colour and corridor, and drawn separately
  # they stack into dozens of parallel strands. Grouping collapses them into
  # one line per {category, agency, colour} with a deduped network geometry.
  describe "Gtfs.group_display_lines/1" do
    test "collapses an operator's corridor-sharing routes into one line" do
      corridor = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]
      platform_variant = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4004]

      assert [line] =
               Gtfs.group_display_lines([
                 db_route("gw1", "Great Western Railway", corridor, short_name: "GW1"),
                 db_route("gw2", "Great Western Railway", platform_variant, short_name: "GW2")
               ])

      assert line.short_name == "Great Western Railway"
      assert line.color == OperatorColors.color_for("Great Western Railway", "rail")
      assert %{coordinates: [_single_strand]} = line.geometry
    end

    test "keeps differently coloured lines of one agency separate" do
      corridor = for i <- 0..40, do: [-1.0 + i * 0.005, 51.5]

      lines =
        Gtfs.group_display_lines([
          db_route("tfl:central", "Transport for London", corridor,
            category: "metro",
            short_name: "Central",
            color: "#E32017"
          ),
          db_route("tfl:victoria", "Transport for London", corridor,
            category: "metro",
            short_name: "Victoria",
            color: "#0098D4"
          )
        ])

      assert lines |> Enum.map(& &1.short_name) |> Enum.sort() == ["Central", "Victoria"]
      assert lines |> Enum.map(& &1.color) |> Enum.sort() == ["#0098D4", "#E32017"]
    end

    test "categories never merge even when agency and colour match" do
      corridor = for i <- 0..40, do: [-1.0 + i * 0.005, 51.5]

      lines =
        Gtfs.group_display_lines([
          db_route("r1", "Acme", corridor, category: "rail", color: "#112233"),
          db_route("r2", "Acme", corridor, category: "tram", color: "#112233")
        ])

      assert lines |> Enum.map(& &1.category) |> Enum.sort() == ["rail", "tram"]
    end
  end

  describe "Geometry.simplify/2" do
    test "keeps endpoints and drops collinear midpoints" do
      line = [[0.0, 0.0], [1.0, 0.00001], [2.0, 0.0], [3.0, 0.00001], [4.0, 0.0]]

      assert Geometry.simplify(line, 0.001) == [[0.0, 0.0], [4.0, 0.0]]
    end

    test "keeps significant deviations" do
      line = [[0.0, 0.0], [1.0, 1.0], [2.0, 0.0]]

      assert Geometry.simplify(line, 0.001) == line
    end

    test "leaves short lines untouched" do
      line = [[0.0, 0.0], [1.0, 1.0]]

      assert Geometry.simplify(line, 10.0) == line
    end
  end

  describe "Geometry.split_at_reversals/1" do
    test "splits an out-and-back hairpin at the reversal point" do
      out = [[-1.0, 51.4], [-0.99, 51.4], [-0.98, 51.4]]
      back = [[-0.98, 51.4], [-0.99, 51.4], [-1.0, 51.4]]
      hairpin = out ++ tl(back)

      assert Geometry.split_at_reversals(hairpin) == [out, back]
    end

    test "leaves ordinary curves and corners alone" do
      line = [[-1.0, 51.4], [-0.99, 51.4], [-0.99, 51.41], [-0.98, 51.42]]

      assert Geometry.split_at_reversals(line) == [line]
    end

    test "splits a hairpin whose return leg sits a platform's width aside" do
      out = for i <- 0..10, do: [-1.0 + i * 0.01, 51.4]
      back = for i <- 10..0//-1, do: [-1.0 + i * 0.01, 51.4001]

      assert [_out, _back] = Geometry.split_at_reversals(out ++ back)
    end

    test "passes short lines through" do
      assert Geometry.split_at_reversals([[-1.0, 51.4], [-0.99, 51.4]]) ==
               [[[-1.0, 51.4], [-0.99, 51.4]]]
    end

    test "tolerates duplicate consecutive points" do
      line = [[-1.0, 51.4], [-1.0, 51.4], [-0.99, 51.4]]

      assert Geometry.split_at_reversals(line) == [line]
    end
  end

  describe "Geometry.drop_redundant_lines/2" do
    # ~0.0005 degrees latitude is roughly 55 m: platform-level variance.
    test "drops strands that re-trace kept geometry" do
      main = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      platform_variant = for i <- 0..18, do: [-1.0 + i * 0.01, 51.4005]

      assert Geometry.drop_redundant_lines([main, platform_variant], 0.15) == [main]
    end

    test "drops exact duplicates" do
      main = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]

      assert Geometry.drop_redundant_lines([main, main], 0.15) == [main]
    end

    test "keeps genuinely diverging branches" do
      main = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      branch = for i <- 0..10, do: [-1.0 + i * 0.01, 51.4 + i * 0.005]

      result = Geometry.drop_redundant_lines([main, branch], 0.15)

      assert main in result
      assert branch in result
    end

    test "covers sparse straight stretches via segment sampling" do
      main = [[-1.0, 51.4], [-0.72, 51.4]]
      variant = for i <- 5..10, do: [-1.0 + i * 0.01, 51.4004]

      assert Geometry.drop_redundant_lines([main, variant], 0.15) == [main]
    end

    test "reversal split plus dedupe collapses a hairpin to one strand" do
      out = for i <- 0..10, do: [-1.0 + i * 0.01, 51.4]
      back = for i <- 10..0//-1, do: [-1.0 + i * 0.01, 51.4001]

      strands = Geometry.split_at_reversals(out ++ back)

      assert [_single] = Geometry.drop_redundant_lines(strands, 0.15)
    end
  end

  describe "Geometry.remove_small_loops/1" do
    test "splices out a station-area loop where the line crosses itself" do
      # ~0.001 deg is roughly 110 m of latitude / 70 m of longitude here.
      approach = [[-1.0, 51.4], [-0.99, 51.4], [-0.98, 51.4]]
      loop = [[-0.98, 51.402], [-0.977, 51.402], [-0.977, 51.4], [-0.98, 51.4]]
      onward = [[-0.97, 51.4], [-0.96, 51.4]]

      assert Geometry.remove_small_loops(approach ++ loop ++ onward) ==
               approach ++ onward
    end

    test "leaves straight lines and gentle curves untouched" do
      line = [[-1.0, 51.4], [-0.99, 51.4], [-0.99, 51.41], [-0.98, 51.42]]

      assert Geometry.remove_small_loops(line) == line
    end

    test "keeps genuine circular routes whose loop is larger than the window" do
      circle =
        for i <- 0..12 do
          angle = i * :math.pi() / 6
          [-1.0 + 0.012 * :math.cos(angle), 51.4 + 0.008 * :math.sin(angle)]
        end

      assert Geometry.remove_small_loops(circle) == circle
    end

    test "passes short lines through" do
      line = [[-1.0, 51.4], [-0.99, 51.4]]

      assert Geometry.remove_small_loops(line) == line
    end
  end

  describe "Geometry.drop_short_shadows/3" do
    test "drops a short sliver hugging a long strand" do
      main = for i <- 0..30, do: [-1.0 + i * 0.01, 51.4]
      sliver = for i <- 0..4, do: [-0.9 + i * 0.001, 51.4008]

      assert Geometry.drop_short_shadows([main, sliver], 1.0, 0.25) == [main]
    end

    test "keeps short spurs that leave the corridor" do
      main = for i <- 0..30, do: [-1.0 + i * 0.01, 51.4]
      spur = [[-0.9, 51.4], [-0.9, 51.404], [-0.9, 51.408]]

      result = Geometry.drop_short_shadows([main, spur], 1.0, 0.25)

      assert main in result
      assert spur in result
    end

    test "leaves routes made only of short strands alone" do
      first = [[-1.0, 51.4], [-0.995, 51.4]]
      second = [[-1.0, 51.4004], [-0.995, 51.4004]]

      assert Geometry.drop_short_shadows([first, second], 1.0, 0.25) == [first, second]
    end

    test "passes single lines through" do
      line = [[-1.0, 51.4], [-0.9, 51.4]]

      assert Geometry.drop_short_shadows([line], 1.0, 0.25) == [line]
    end
  end

  describe "OperatorColors.color_for/2" do
    test "gives corridor-sharing operators distinct colours" do
      great_western = OperatorColors.color_for("Great Western Railway", "rail")
      southern = OperatorColors.color_for("Southern", "rail")

      assert great_western =~ ~r/^#[0-9A-F]{6}$/
      assert southern =~ ~r/^#[0-9A-F]{6}$/
      refute great_western == southern
    end

    test "matches the most specific operator name first" do
      refute OperatorColors.color_for("Great Northern", "rail") ==
               OperatorColors.color_for("Northern", "rail")

      refute OperatorColors.color_for("South Western Railway", "rail") ==
               OperatorColors.color_for("Southern", "rail")

      refute OperatorColors.color_for("London North Eastern Railway", "intercity") ==
               OperatorColors.color_for("Northern", "rail")
    end

    test "only applies to rail-family categories" do
      assert OperatorColors.color_for("Southern Vectis", "bus") == nil
      assert OperatorColors.color_for("Great Western Railway", "ferry") == nil
    end

    test "unknown operators keep feed colours" do
      assert OperatorColors.color_for("Acme Trains", "rail") == nil
      assert OperatorColors.color_for(nil, "rail") == nil
    end
  end

  describe "Geometry.stitch_lines/2" do
    test "rejoins fragments that continue one another into one strand" do
      first = [[-1.0, 51.4], [-0.99, 51.4]]
      second = [[-0.99, 51.4], [-0.98, 51.4]]
      third = [[-0.98, 51.4], [-0.97, 51.4]]

      assert Geometry.stitch_lines([first, third, second], 0.05) ==
               [[[-1.0, 51.4], [-0.99, 51.4], [-0.98, 51.4], [-0.97, 51.4]]]
    end

    test "does not stitch genuine reversal legs back into a hairpin" do
      out = [[-1.0, 51.4], [-0.99, 51.4], [-0.98, 51.4]]
      back = [[-0.98, 51.4], [-0.99, 51.4], [-1.0, 51.4]]

      assert Geometry.stitch_lines([out, back], 0.05) == [out, back]
    end

    test "leaves disconnected lines alone" do
      first = [[-1.0, 51.4], [-0.99, 51.4]]
      second = [[-0.9, 51.4], [-0.89, 51.4]]

      assert Geometry.stitch_lines([first, second], 0.05) == [first, second]
    end
  end

  # The rendering contract for route geometry: corridors must draw as
  # continuous lines (never chains of dashes), cleanup must never open a
  # gap in a route's coverage, and every strand must be oriented the same
  # way along its corridor so MapLibre's line-offset keeps parallel routes
  # on consistent, distinct sides.
  describe "DisplayGeometry.prepare/1" do
    test "a fragmented corridor comes back as one unbroken strand" do
      fragments = [
        for(i <- 0..10, do: [-1.0 + i * 0.01, 51.4]),
        for(i <- 20..30, do: [-1.0 + i * 0.01, 51.4]),
        for(i <- 10..20, do: [-1.0 + i * 0.01, 51.4])
      ]

      assert %{coordinates: [strand]} =
               DisplayGeometry.prepare(%{type: "MultiLineString", coordinates: fragments})

      assert hd(strand) == [-1.0, 51.4]
      assert List.last(strand) == [-0.7, 51.4]
    end

    test "cleanup never opens gaps in the corridor" do
      # One shape that runs east, reverses back over its own track, then
      # continues east: the pipeline may split and drop strands, but every
      # point of the original corridor must stay covered.
      east = for i <- 0..50, do: [-1.0 + i * 0.002, 51.4]
      back = for i <- 49..40//-1, do: [-1.0 + i * 0.002, 51.4]
      onward = for i <- 41..90, do: [-1.0 + i * 0.002, 51.4]
      shape = east ++ back ++ onward

      assert %{coordinates: strands} =
               DisplayGeometry.prepare(%{type: "MultiLineString", coordinates: [shape]})

      for point <- shape do
        assert within_km?(point, strands, 0.3),
               "corridor point #{inspect(point)} lost by cleanup"
      end
    end

    test "strands are all oriented the same way along their corridor" do
      # Two north-south strands whose endpoint longitudes wiggle in
      # opposite directions; ordering by whole coordinates would flip one
      # onto the other side of the corridor.
      northbound = [[-1.0001, 51.0], [-1.0, 51.05], [-1.0002, 51.1]]
      southbound = [[-0.9999, 51.3], [-1.0, 51.25], [-1.0001, 51.2]]

      assert %{coordinates: strands} =
               DisplayGeometry.prepare(%{
                 type: "MultiLineString",
                 coordinates: [northbound, southbound]
               })

      assert length(strands) == 2

      for [[_lon1, lat1] | _] = strand <- strands do
        [_lon2, lat2] = List.last(strand)
        assert lat2 > lat1, "strand not oriented south-to-north: #{inspect(strand)}"
      end
    end

    test "string-keyed geometry goes through the same pipeline" do
      fragments = [
        [[-1.0, 51.4], [-0.99, 51.4]],
        [[-0.99, 51.4], [-0.98, 51.4]]
      ]

      assert %{"coordinates" => [_single_strand]} =
               DisplayGeometry.prepare(%{
                 "type" => "MultiLineString",
                 "coordinates" => fragments
               })
    end
  end

  # The other half of the rendering contract: routes sharing a corridor
  # must occupy distinct offset slots (side-by-side strands, one ribbon
  # that fans apart when zoomed in), never the same slot where one line
  # hides the other and peeks out as broken fragments.
  describe "OffsetSlots.assign/1" do
    test "corridor-sharing routes always get distinct slots" do
      shared = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]

      slots =
        [
          corridor_route("1", "Thameslink", [shared]),
          corridor_route("2", "Southern", [shared]),
          corridor_route("3", "Gatwick Express", [shared])
        ]
        |> OffsetSlots.assign()
        |> Enum.map(fn {_route, slot} -> slot end)

      assert length(Enum.uniq(slots)) == 3
    end

    test "slots fan out symmetrically so the ribbon stays centred" do
      shared = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]

      routes = for id <- ~w(a b c d e), do: corridor_route(id, "Operator #{id}", [shared])

      slots = routes |> OffsetSlots.assign() |> Enum.map(fn {_route, slot} -> slot end)

      assert Enum.sort(slots) == [-2, -1, 0, 1, 2]
    end

    test "isolated routes stay centred on their own track" do
      first = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]
      far_away = for i <- 0..40, do: [-1.0 + i * 0.005, 53.4]

      assert [{_route_a, 0}, {_route_b, 0}] =
               [
                 corridor_route("1", "A", [first]),
                 corridor_route("2", "B", [far_away])
               ]
               |> OffsetSlots.assign()
               |> Enum.sort_by(fn {route, _slot} -> route.route_id end)
    end

    test "routes that merely cross keep their own centreline" do
      west_east = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]
      south_north = for i <- 0..40, do: [-0.9, 51.3 + i * 0.005]

      assert [{_route_a, 0}, {_route_b, 0}] =
               [
                 corridor_route("1", "A", [west_east]),
                 corridor_route("2", "B", [south_north])
               ]
               |> OffsetSlots.assign()
               |> Enum.sort_by(fn {route, _slot} -> route.route_id end)
    end

    test "slots never fan wider than plus or minus 3 on very busy corridors" do
      shared = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]

      slots =
        for(id <- ~w(a b c d e f g h i), do: corridor_route(id, "Operator #{id}", [shared]))
        |> OffsetSlots.assign()
        |> Enum.map(fn {_route, slot} -> slot end)

      assert length(slots) == 9
      assert slots |> Enum.map(&abs/1) |> Enum.max() == 3
    end

    test "categories get independent slot assignments" do
      shared = for i <- 0..40, do: [-1.0 + i * 0.005, 51.4]

      slots =
        [
          corridor_route("1", "A", [shared], "rail"),
          corridor_route("2", "B", [shared], "tram")
        ]
        |> OffsetSlots.assign()
        |> Enum.map(fn {_route, slot} -> slot end)

      assert slots == [0, 0]
    end
  end

  defp db_route(id, agency, coordinates, opts \\ []) do
    %{
      route_id: id,
      agency_name: agency,
      short_name: Keyword.get(opts, :short_name),
      long_name: Keyword.get(opts, :long_name),
      category: Keyword.get(opts, :category, "rail"),
      color: Keyword.get(opts, :color),
      text_color: Keyword.get(opts, :text_color),
      geometry: %{"type" => "MultiLineString", "coordinates" => [coordinates]}
    }
  end

  defp corridor_route(id, agency, coordinates, category \\ "rail") do
    %{
      route_id: id,
      agency_name: agency,
      short_name: id,
      long_name: nil,
      category: category,
      geometry: %{type: "MultiLineString", coordinates: coordinates}
    }
  end

  # Distance from a point to the nearest vertex of any strand; inputs use
  # dense vertices so vertex distance approximates line distance.
  defp within_km?([lon, lat], strands, tolerance_km) do
    kx = 111.320 * :math.cos(lat * :math.pi() / 180)

    Enum.any?(strands, fn strand ->
      Enum.any?(strand, fn [lon2, lat2] ->
        dx = (lon2 - lon) * kx
        dy = (lat2 - lat) * 110.574
        :math.sqrt(dx * dx + dy * dy) <= tolerance_km
      end)
    end)
  end

  describe "Geometry.split_long_segments/2" do
    test "removes implausible connector jumps while preserving valid sections" do
      line = [
        [-0.12, 51.50],
        [-0.13, 51.51],
        [-3.18, 51.48],
        [-3.19, 51.49]
      ]

      assert Geometry.split_long_segments(line, 25) == [
               [[-0.12, 51.50], [-0.13, 51.51]],
               [[-3.18, 51.48], [-3.19, 51.49]]
             ]
    end
  end
end
