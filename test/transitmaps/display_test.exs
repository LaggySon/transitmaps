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

    test "draws Amtrak in its brand blue rather than its feed's pale colour" do
      [line] =
        Identity.lines([
          %{
            route_id: "88",
            agency_name: "Amtrak",
            short_name: "Northeast Regional",
            long_name: nil,
            category: "intercity",
            color: "#CAE4F1",
            text_color: "#000000",
            geometry: %{type: "MultiLineString", coordinates: [[[-74.0, 40.7], [-75.2, 39.9]]]}
          }
        ])

      assert line.color == "#00539B"
      assert line.name == "Amtrak"

      # Its Thruway buses aren't rail, so they keep the feed's colour.
      assert Identity.brand_color("Amtrak", "bus") == nil
    end

    test "unknown operators keep feed colours" do
      assert Identity.brand_color("Acme Trains", "rail") == nil
      assert Identity.brand_color(nil, "rail") == nil
    end
  end

  describe "Identity.lines/1 names" do
    @track [[[-122.3, 37.8], [-122.2, 37.8]]]

    defp name_of(routes), do: routes |> Identity.lines() |> Enum.map(& &1.name)

    defp metro(id, agency, color, opts),
      do: route(id, agency, @track, [category: "metro", color: color] ++ opts)

    test "a line run as one route per direction takes its stem" do
      assert name_of([
               metro("1", nil, "#FFFF33", short_name: "Yellow-S", long_name: "Antioch to SFO"),
               metro("2", nil, "#FFFF33", short_name: "Yellow-N", long_name: "SFO to Antioch")
             ]) == ["Yellow"]
    end

    test "a line only named in full takes its long name" do
      assert name_of([
               metro("Red", "Chicago Transit Authority", "#C60C30", long_name: "Red Line")
             ]) ==
               ["Red Line"]
    end

    test "branches of one line take the line's name" do
      assert name_of([
               metro("Green-B", "MBTA", "#00843D", short_name: "B", long_name: "Green Line B"),
               metro("Green-C", "MBTA", "#00843D", short_name: "C", long_name: "Green Line C")
             ]) == ["Green Line"]
    end

    test "a few services sharing a colour list their names" do
      assert name_of([
               metro("A", "MTA", "#0062CF", short_name: "A", long_name: "8 Avenue Express"),
               metro("E", "MTA", "#0062CF", short_name: "E", long_name: "8 Avenue Local"),
               metro("C", "MTA", "#0062CF", short_name: "C", long_name: "8 Avenue Local")
             ]) == ["A C E"]
    end

    test "an operator colouring every train alike draws each line on its own" do
      routes =
        for n <- [1, 1, 2, 5],
            do: route("re#{n}", "DB Regio AG", @track, short_name: "RE#{n}", color: "#EC0016")

      assert name_of(routes) == ["RE1", "RE2", "RE5"]
    end

    test "lines riders know by colour get it when their feed has none" do
      lines =
        Identity.lines([
          route("a", "DSB S-tog", @track, short_name: "A"),
          route("b", "DSB S-tog", @track, short_name: "B"),
          route("ic", "DSB", @track, short_name: "IC")
        ])

      assert lines |> Enum.map(&{&1.name, &1.color}) |> Enum.sort() ==
               [{"A", "#0098D4"}, {"B", "#4BAF4F"}, {"DSB", "#B41730"}]
    end

    test "unnamed routes fall back to the agency" do
      assert name_of([route("x", "Acme Rail", @track, color: "#123456")]) == ["Acme Rail"]
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

    test "serves track that several services re-trace only once" do
      trunk = for i <- 0..20, do: [-1.0 + i * 0.01, 51.4]
      branch = for i <- 1..10, do: [-0.8 + i * 0.01, 51.4 + i * 0.01]

      [line] =
        Display.drawn_lines([
          route("sw1", "South Western Railway", [trunk]),
          # The return working runs the same track the other way.
          route("sw2", "South Western Railway", [Enum.reverse(trunk)]),
          # A stopping service covers half the trunk, then takes a branch.
          route("sw3", "South Western Railway", [Enum.slice(trunk, 10..20) ++ branch])
        ])

      assert line.geometry.coordinates == [trunk, [List.last(trunk) | branch]]
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
