defmodule Transitmaps.DisplayTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Display
  alias Transitmaps.Display.Identity
  alias Transitmaps.Display.LineGraph
  alias Transitmaps.Display.Network
  alias Transitmaps.Display.Ordering
  alias Transitmaps.Display.Render

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

  describe "LineGraph.build/1" do
    test "lines tracing the same railway come back on one shared track" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      # A feed never traces a corridor twice the same way; forty metres of
      # disagreement is a quiet day.
      traced = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4004]

      graph = LineGraph.build([line([corridor]), line([traced])])

      assert map_size(graph.tracks) == 1
      assert [%{lines: [0, 1]}] = graph.edges
    end

    test "a line leaving the corridor cuts it into edges that tile it" do
      full = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      half = for i <- 0..50, do: [-1.0 + i * 0.004, 51.4]

      graph = LineGraph.build([line([full]), line([half])])
      [shared, alone] = Enum.sort_by(graph.edges, & &1.from)

      assert shared.lines == [0, 1]
      assert alone.lines == [0]
      # No gap and no overlap: the edges meet exactly where membership changes.
      assert shared.to == alone.from
      assert shared.from == 0.0
    end

    test "crossing lines are never made to share track" do
      west_east = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      south_north = for i <- 0..100, do: [-0.8, 51.2 + i * 0.004]

      graph = LineGraph.build([line([west_east]), line([south_north])])

      assert map_size(graph.tracks) == 2
      assert graph.edges |> Enum.map(& &1.lines) |> Enum.sort() == [[0], [1]]
    end

    test "a line's coverage is never trimmed by edge rounding" do
      full = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      part = for i <- 30..70, do: [-1.0 + i * 0.004, 51.4]

      graph = LineGraph.build([line([full]), line([part])])
      shared = Enum.filter(graph.edges, &(&1.lines == [0, 1]))

      assert [%{from: from, to: to}] = shared
      # Boundaries snap outward, so the short line is drawn over all of its
      # own track rather than stopping short of it.
      assert from <= km_along(full, hd(part))
      assert to >= km_along(full, List.last(part))
    end
  end

  describe "Render.runs/2" do
    test "corridor-sharing lines take symmetric slots and share the geometry" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      traced = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4004]

      runs = drawn([line([corridor]), line([traced])])

      assert Enum.map(runs, & &1.slot) |> Enum.sort() == [-0.5, 0.5]

      # The point of slotting rather than displacing: nothing has been moved
      # off the track, so the map holds its shape at every zoom.
      for run <- runs, [_lon, lat] <- run.coordinates do
        assert_in_delta lat, 51.4, 0.00001
      end
    end

    test "an isolated line sits in slot 0 on its own centreline" do
      away = for i <- 0..100, do: [-1.0 + i * 0.004, 53.0]

      assert [run] = drawn([line([away])])
      assert run.slot == 0.0
      assert run.bundle == 1
      assert hd(run.coordinates) == [-1.0, 53.0]
      assert List.last(run.coordinates) == [-0.6, 53.0]
    end

    test "survivors close up over a ramp rather than stepping sideways" do
      full = for i <- 0..150, do: [-1.0 + i * 0.004, 51.4]
      half = for i <- 0..75, do: [-1.0 + i * 0.004, 51.4]

      runs = drawn([line([full]), line([half]), line([full])])
      outer = runs |> Enum.filter(&(&1.line == 0)) |> Enum.sort_by(&hd(hd(&1.coordinates)))

      # Three abreast, then two: the outer line moves from one full place out
      # to half a place, and does it in steps no reader can see.
      assert List.first(outer).slot == -1.0
      assert List.last(outer).slot == -0.5

      steps =
        outer
        |> Enum.map(& &1.slot)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> abs(b - a) end)

      assert steps != []
      assert Enum.max(steps) <= 0.25
    end

    test "consecutive runs of a line meet, so a line is never drawn broken" do
      full = for i <- 0..150, do: [-1.0 + i * 0.004, 51.4]
      half = for i <- 0..75, do: [-1.0 + i * 0.004, 51.4]

      runs = drawn([line([full]), line([half]), line([full])])
      outer = runs |> Enum.filter(&(&1.line == 0)) |> Enum.sort_by(&hd(hd(&1.coordinates)))

      outer
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [before, aft] ->
        assert List.last(before.coordinates) == hd(aft.coordinates)
      end)
    end
  end

  describe "Ordering.order/1" do
    test "a line branching left is placed on the left of the bundle" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      south = for i <- 0..100, do: [-1.0 + i * 0.004, 51.3996]
      traced = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4004]

      # Ranked last, so only the crossing count can pull it to the north side
      # of the bundle it leaves northwards.
      branching =
        for(i <- 0..60, do: [-1.0 + i * 0.004, 51.4]) ++
          for(i <- 1..40, do: [-0.76 + i * 0.002, 51.4 + i * 0.004])

      runs = drawn([line([corridor]), line([traced]), line([south]), line([branching])])
      trunk = Enum.filter(runs, &(&1.bundle == 4))
      branch = trunk |> Enum.filter(&(&1.line == 3)) |> Enum.min_by(& &1.slot)

      assert branch.slot == -1.5
      assert Enum.all?(trunk, &(&1.slot >= branch.slot))
    end
  end

  describe "Display.corridor_ribbons/1" do
    test "every line reaches the map, and shared track is one ribbon" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      away = for i <- 0..100, do: [-1.0 + i * 0.004, 51.41]

      ribbons =
        Display.corridor_ribbons([
          route("a", "Avanti West Coast", [corridor]),
          route("b", "CrossCountry", [corridor]),
          route("c", "Northern", [away])
        ])

      colors = Enum.map(ribbons, & &1.colors)

      assert Enum.any?(colors, &(length(&1) == 2))
      assert Enum.any?(colors, &(length(&1) == 1))
      assert ribbons |> Enum.flat_map(& &1.colors) |> Enum.uniq() |> length() == 3
    end

    test "a ribbon's colours are in the order the lines are slotted" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]

      routes = [
        route("a", "Avanti West Coast", [corridor]),
        route("b", "CrossCountry", [corridor])
      ]

      assert [ribbon] = Display.corridor_ribbons(routes)
      lines = Display.drawn_lines(routes)

      assert ribbon.colors ==
               lines |> Enum.sort_by(& &1.slot) |> Enum.map(& &1.color)
    end
  end

  describe "Display.drawn_lines/1" do
    test "runs identity, cleanup, and slotting end to end" do
      corridor = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4]
      variant = for i <- 0..100, do: [-1.0 + i * 0.004, 51.4003]

      lines =
        Display.drawn_lines([
          route("gw1", "Great Western Railway", [corridor], short_name: "GW1"),
          route("gw2", "Great Western Railway", [variant], short_name: "GW2"),
          route("xc1", "CrossCountry", [Enum.reverse(corridor)], short_name: "XC1")
        ])

      assert lines |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort() ==
               ["CrossCountry", "Great Western Railway"]

      assert lines |> Enum.map(& &1.slot) |> Enum.sort() == [-0.5, 0.5]
      assert Enum.all?(lines, &(&1.bundle == 2))
      assert Enum.all?(lines, &match?(%{type: "LineString"}, &1.geometry))
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

  # The drawn runs for bare geometry lines, straight off the graph.
  defp drawn(lines) do
    graph = LineGraph.build(lines)

    Render.runs(graph, Ordering.order(graph))
  end

  # Distance in km from the start of `strand` to the vertex nearest `point`.
  defp km_along([[_lon, lat] | _] = strand, point) do
    kx = 111.320 * :math.cos(lat * :math.pi() / 180)

    strand
    |> Enum.take_while(&(&1 != point))
    |> Kernel.++([point])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [[lon1, lat1], [lon2, lat2]], total ->
      dx = (lon2 - lon1) * kx
      dy = (lat2 - lat1) * @km_per_lat
      total + :math.sqrt(dx * dx + dy * dy)
    end)
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
