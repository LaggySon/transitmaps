defmodule Transitmaps.GtfsTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs
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
