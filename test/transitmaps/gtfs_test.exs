defmodule Transitmaps.GtfsTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.Importer
  alias Transitmaps.Gtfs.Stop
  alias Transitmaps.Gtfs.RouteTypes
  alias Transitmaps.Gtfs.TflImporter

  describe "TflImporter.line_coordinates/4" do
    test "joins ordered OSM way members into continuous line geometry" do
      relations = [
        tfl_relation([
          way([[-0.60, 51.50], [-0.59, 51.50]]),
          way([[-0.58, 51.50], [-0.59, 51.50]]),
          way([[-0.58, 51.50], [-0.57, 51.50]])
        ])
      ]

      assert [[[-0.60, 51.50], [-0.59, 51.50], [-0.58, 51.50], [-0.57, 51.50]]] =
               TflImporter.line_coordinates(central_line(), "tube", relations, central_stations())
    end

    test "rejects similarly named non-TfL relations and geometry outside the line's stations" do
      valid =
        tfl_relation([
          way([[-0.60, 51.50], [-0.55, 51.51]]),
          way([[-0.55, 51.51], [-0.50, 51.52]])
        ])

      national_rail = %{
        "tags" => %{
          "route" => "train",
          "name" => "Slough to Windsor & Eton Central",
          "network" => "National Rail",
          "operator" => "Great Western Railway"
        },
        "members" => [way([[-2.60, 51.45], [-2.58, 51.46]])]
      }

      mislabeled_tfl =
        tfl_relation([
          way([[-2.60, 51.45], [-2.58, 51.46]]),
          way([[-0.50, 51.52], [-0.45, 51.53]])
        ])

      assert coordinates =
               TflImporter.line_coordinates(
                 central_line(),
                 "tube",
                 [national_rail, mislabeled_tfl, valid],
                 central_stations()
               )

      assert coordinates == [
               [[-0.50, 51.52], [-0.45, 51.53]],
               [[-0.60, 51.50], [-0.55, 51.51], [-0.50, 51.52]]
             ]

      refute Enum.any?(List.flatten(coordinates), &(&1 == -2.60))
    end

    test "accepts the Elizabeth line's current National Rail OSM tags" do
      relations = [
        %{
          "tags" => %{
            "route" => "train",
            "ref" => "Elizabeth",
            "name" => "Elizabeth line: Paddington → Abbey Wood",
            "network" => "National Rail",
            "network:metro" => "Elizabeth line",
            "operator" => "GTS Rail Operations"
          },
          "members" => [way([[-0.18, 51.52], [0.12, 51.49]])]
        }
      ]

      line = %{"id" => "elizabeth", "name" => "Elizabeth line"}

      stations = [
        %{"lon" => -0.18, "lat" => 51.52},
        %{"lon" => 0.12, "lat" => 51.49}
      ]

      assert [[[-0.18, 51.52], [0.12, 51.49]]] =
               TflImporter.line_coordinates(line, "elizabeth-line", relations, stations)
    end
  end

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

  defp central_line, do: %{"id" => "central", "name" => "Central"}

  defp central_stations do
    [
      %{"lon" => -0.61, "lat" => 51.49},
      %{"lon" => 0.11, "lat" => 51.69}
    ]
  end

  defp tfl_relation(members) do
    %{
      "tags" => %{
        "route" => "subway",
        "ref" => "Central",
        "name" => "Central line",
        "network" => "London Underground",
        "operator" => "Transport for London"
      },
      "members" => members
    }
  end

  defp way(coordinates) do
    %{
      "type" => "way",
      "geometry" => Enum.map(coordinates, fn [lon, lat] -> %{"lon" => lon, "lat" => lat} end)
    }
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

  describe "Importer.route_geometry/4" do
    test "does not draw Great Britain rail services as straight stop-to-stop chords" do
      cardiff_to_newport = [
        [-3.179301702, 51.476023688],
        [-3.000543440, 51.588787290]
      ]

      assert Importer.route_geometry("gb-rail", "rail", nil, [cardiff_to_newport]) == nil
    end

    test "prefers a real track shape over fallback stop coordinates" do
      track_shape = [
        [-3.17930, 51.47602],
        [-3.15000, 51.49000],
        [-3.10000, 51.51000],
        [-3.00054, 51.58879]
      ]

      direct_fallback = [[hd(track_shape), List.last(track_shape)]]

      assert Importer.route_geometry("gb-rail", "rail", [track_shape], direct_fallback) == %{
               type: "MultiLineString",
               coordinates: [track_shape]
             }
    end

    test "retains fallback geometry for feeds that still rely on it" do
      fallback = [[[-74.01, 40.71], [-73.98, 40.75]]]

      assert Importer.route_geometry("local-shuttle", "rail", nil, fallback) == %{
               type: "MultiLineString",
               coordinates: fallback
             }
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

  describe "Geometry.extract_network_lines/2" do
    test "draws a shared trunk once while retaining a real branch" do
      trunk = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]

      branch =
        (for(i <- 0..10, do: [-1.0 + i * 0.01, 51.4004])) ++
          (for(i <- 1..10, do: [-0.9, 51.4 + i * 0.005]))

      assert [^trunk, unique_branch] = Geometry.extract_network_lines([trunk, branch], 0.15)
      [join_lon, join_lat] = hd(unique_branch)
      assert_in_delta join_lon, -0.9, 0.006
      assert join_lat == 51.4
      [end_lon, end_lat] = List.last(unique_branch)
      assert_in_delta end_lon, -0.9, 0.000_001
      assert_in_delta end_lat, 51.45, 0.000_001
      assert Enum.all?(tl(unique_branch), fn [lon, _lat] -> abs(lon + 0.9) < 0.001 end)
    end

    test "keeps only the novel extension of a partly overlapping path" do
      trunk = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      overlapping_extension = for i <- 10..25, do: [-1.0 + i * 0.01, 51.4003]

      assert [^trunk, extension] =
               Geometry.extract_network_lines([trunk, overlapping_extension], 0.15)

      [join_lon, join_lat] = hd(extension)
      assert_in_delta join_lon, -0.8, 0.01
      assert join_lat == 51.4
      assert List.last(extension) == [-0.75, 51.4003]
    end

    test "drops fully duplicated paths" do
      trunk = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      platform_variant = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4004]

      assert Geometry.extract_network_lines([trunk, platform_variant], 0.15) == [trunk]
    end

    test "does not merge genuinely parallel tracks outside the tolerance" do
      first = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      second = for i <- 0..20, do: [-1.0 + i * 0.01, 51.406]

      assert Geometry.extract_network_lines([first, second], 0.15) == [first, second]
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

  describe "Geometry.round_corners/2" do
    test "replaces a sharp corner with an arc between the same endpoints" do
      corner = [[-1.0, 51.4], [-0.99, 51.4], [-0.99, 51.41]]

      rounded = Geometry.round_corners(corner, 0.15)

      assert length(rounded) > length(corner)
      assert hd(rounded) == hd(corner)
      assert List.last(rounded) == List.last(corner)
      refute [-0.99, 51.4] in rounded
    end

    test "keeps every output turn gentle enough for parallel offsets" do
      corner = [[-1.0, 51.4], [-0.99, 51.4], [-0.99, 51.41]]
      {kx, ky} = Geometry.km_scale(hd(corner))

      turns =
        corner
        |> Geometry.round_corners(0.15)
        |> Enum.map(fn [lon, lat] -> {lon * kx, lat * ky} end)
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.map(fn [{ax, ay}, {bx, by}, {cx, cy}] ->
          {ux, uy} = {bx - ax, by - ay}
          {vx, vy} = {cx - bx, cy - by}
          norm = :math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
          :math.acos(min(1.0, max(-1.0, (ux * vx + uy * vy) / norm)))
        end)

      assert Enum.max(turns) < 0.35
    end

    test "leaves straight lines and gentle bends untouched" do
      straight = [[-1.0, 51.4], [-0.99, 51.4], [-0.98, 51.4]]
      gentle = [[-1.0, 51.4], [-0.99, 51.4], [-0.98, 51.4001]]

      assert Geometry.round_corners(straight, 0.15) == straight
      assert Geometry.round_corners(gentle, 0.15) == gentle
    end

    test "leaves near-reversals for the hairpin splitter" do
      hairpin = [[-1.0, 51.4], [-0.99, 51.4], [-0.9999, 51.4001]]

      assert Geometry.round_corners(hairpin, 0.15) == hairpin
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
