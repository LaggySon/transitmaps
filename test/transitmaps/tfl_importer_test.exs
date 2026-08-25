defmodule Transitmaps.Gtfs.TflImporterTest do
  use ExUnit.Case, async: false

  alias Transitmaps.Gtfs.TflImporter

  describe "tfl_line_coordinates/1" do
    test "decodes TfL line strings and collapses reverse duplicates" do
      forward = [[-0.49, 51.47], [-0.45, 51.48], [-0.42, 51.50]]

      assert TflImporter.tfl_line_coordinates([
               Jason.encode!([forward]),
               Jason.encode!([Enum.reverse(forward)])
             ]) == [forward]
    end

    test "keeps the separate branches within a line string" do
      first = [[-0.49, 51.47], [-0.45, 51.48]]
      second = [[-0.45, 51.48], [-0.42, 51.50]]

      assert TflImporter.tfl_line_coordinates([Jason.encode!([first, second])]) == [first, second]
    end

    test "ignores malformed and unusable geometry" do
      assert TflImporter.tfl_line_coordinates([
               "not-json",
               Jason.encode!([[[nil, 51.47]], [[-0.49, 51.47]]])
             ]) == []
    end
  end

  describe "configured_geometry_source!/0" do
    setup do
      original = System.get_env("TFL_GEOMETRY_SOURCE")

      on_exit(fn ->
        if original do
          System.put_env("TFL_GEOMETRY_SOURCE", original)
        else
          System.delete_env("TFL_GEOMETRY_SOURCE")
        end
      end)
    end

    test "defaults to OSM and accepts the Railway preview value" do
      System.delete_env("TFL_GEOMETRY_SOURCE")
      assert TflImporter.configured_geometry_source!() == :osm

      System.put_env("TFL_GEOMETRY_SOURCE", "tfl")
      assert TflImporter.configured_geometry_source!() == :tfl
    end

    test "rejects unknown configuration" do
      System.put_env("TFL_GEOMETRY_SOURCE", "other")

      assert_raise ArgumentError, ~r/unknown TfL geometry source/, fn ->
        TflImporter.configured_geometry_source!()
      end
    end
  end
end
