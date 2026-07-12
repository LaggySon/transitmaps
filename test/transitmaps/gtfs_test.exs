defmodule Transitmaps.GtfsTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Geometry
  alias Transitmaps.Gtfs
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
end
