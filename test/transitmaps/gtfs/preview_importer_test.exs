defmodule Transitmaps.Gtfs.PreviewImporterTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Gtfs.PreviewImporter

  test "converts public route features into isolated snapshot rows" do
    feature = %{
      "geometry" => %{"type" => "MultiLineString", "coordinates" => [[[-0.1, 51.5]]]},
      "properties" => %{
        "agency" => "Transport for London",
        "category" => "metro",
        "color" => "#003688",
        "name" => "Piccadilly",
        "text_color" => "#FFFFFF"
      }
    }

    assert [route] = PreviewImporter.route_rows([feature])
    assert route.route_id == "snapshot-route-0"
    assert route.agency_name == "Transport for London"
    assert route.short_name == "Piccadilly"
    assert route.route_type == 1
    assert route.geometry == feature["geometry"]
  end

  test "preserves station categories and line presentation from the snapshot" do
    lines = [
      %{
        "agency" => "Transport for London",
        "category" => "metro",
        "color" => "#003688",
        "name" => "Piccadilly"
      }
    ]

    feature = %{
      "geometry" => %{"type" => "Point", "coordinates" => [-0.445, 51.471]},
      "properties" => %{
        "categories" => ["metro"],
        "lines" => lines,
        "name" => "Heathrow Terminal 5",
        "station" => true
      }
    }

    assert [stop] = PreviewImporter.stop_rows([feature])
    assert stop.stop_id == "snapshot-stop-0"
    assert stop.name == "Heathrow Terminal 5"
    assert stop.location_type == 1
    assert stop.categories == ["metro"]
    assert stop.lines == lines
    assert {stop.lon, stop.lat} == {-0.445, 51.471}
  end
end
