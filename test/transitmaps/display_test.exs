defmodule Transitmaps.DisplayTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Display
  alias Transitmaps.Display.Identity

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

  describe "Display.drawn_lines/1" do
    test "names the lines and hands their source geometry through untouched" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      variant = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4003]

      lines =
        Display.drawn_lines([
          route("gw1", "Great Western Railway", [corridor], short_name: "GW1"),
          route("gw2", "Great Western Railway", [variant], short_name: "GW2"),
          route("xc1", "CrossCountry", [Enum.reverse(corridor)], short_name: "XC1")
        ])

      assert [%{name: "CrossCountry"} = cross_country, %{name: "Great Western Railway"} = gwr] =
               Enum.sort_by(lines, & &1.name)

      # Not a vertex is moved. The two operators sharing this corridor come
      # back on the very same coordinates, drawn one on top of the other, and
      # the operator's two re-tracing shapes both survive as separate strands.
      assert cross_country.geometry.coordinates == [Enum.reverse(corridor)]
      assert gwr.geometry.coordinates == [corridor, variant]
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
end
