defmodule Transitmaps.Live.TflTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Live.Tfl

  # Shape mirrors a /Line/{id}/Route/Sequence/all response: a flat station
  # list (with coordinates) plus ordered stop sequences per direction.
  defp sample_detail do
    %{
      "stations" => [
        %{"id" => "A", "name" => "Alpha Underground Station", "lon" => 0.0, "lat" => 0.0},
        %{"id" => "B", "name" => "Bravo Underground Station", "lon" => 1.0, "lat" => 0.0},
        %{"id" => "C", "name" => "Charlie Underground Station", "lon" => 2.0, "lat" => 0.0}
      ],
      "stopPointSequences" => [
        %{
          "direction" => "inbound",
          "stopPoint" => [%{"id" => "A"}, %{"id" => "B"}, %{"id" => "C"}]
        }
      ]
    }
  end

  defp line, do: %{id: "victoria", name: "Victoria", color: "#0098D4", category: "metro"}

  describe "station_graph/1" do
    test "maps station coordinates and cleans names" do
      graph = Tfl.station_graph(sample_detail())

      assert graph.coords["A"] == {0.0, 0.0, "Alpha"}
      assert graph.coords["C"] == {2.0, 0.0, "Charlie"}
    end

    test "records the predecessor of each stop per direction" do
      graph = Tfl.station_graph(sample_detail())

      assert graph.predecessors[{"inbound", "B"}] == "A"
      assert graph.predecessors[{"inbound", "C"}] == "B"
      refute Map.has_key?(graph.predecessors, {"inbound", "A"})
    end

    test "tolerates a missing or malformed body" do
      assert Tfl.station_graph(%{}) == %{coords: %{}, predecessors: %{}}
      assert Tfl.station_graph(nil) == %{coords: %{}, predecessors: %{}}
    end
  end

  describe "vehicles/3" do
    test "places a train approaching a station between it and the previous stop" do
      graph = Tfl.station_graph(sample_detail())

      # A train reaching B in a full segment sits at the previous stop (A);
      # halfway through the segment it sits halfway between A and B.
      arrivals = [
        %{"vehicleId" => "t1", "direction" => "inbound", "naptanId" => "B", "timeToStation" => 105},
        %{"vehicleId" => "t2", "direction" => "inbound", "naptanId" => "C", "timeToStation" => 52.5}
      ]

      features = Tfl.vehicles(arrivals, graph, line())
      by_station = Map.new(features, &{&1.properties.station, &1.geometry.coordinates})

      assert by_station["Bravo"] == [0.0, 0.0]
      assert [x, 0.0] = by_station["Charlie"]
      assert_in_delta x, 1.5, 0.0001
    end

    test "carries line branding onto each vehicle and builds a stable id" do
      graph = Tfl.station_graph(sample_detail())

      arrivals = [
        %{"vehicleId" => "t1", "direction" => "inbound", "naptanId" => "B", "timeToStation" => 30}
      ]

      assert [feature] = Tfl.vehicles(arrivals, graph, line())
      assert feature.properties.color == "#0098D4"
      assert feature.properties.category == "metro"
      assert feature.properties.id == "victoria:inbound:B"
    end

    test "drops predictions that are too far out or reference unknown stations" do
      graph = Tfl.station_graph(sample_detail())

      arrivals = [
        %{"direction" => "inbound", "naptanId" => "B", "timeToStation" => 900},
        %{"direction" => "inbound", "naptanId" => "Z", "timeToStation" => 20}
      ]

      assert Tfl.vehicles(arrivals, graph, line()) == []
    end

    test "keeps only the soonest arrival per station and direction" do
      graph = Tfl.station_graph(sample_detail())

      arrivals = [
        %{"direction" => "inbound", "naptanId" => "C", "timeToStation" => 90},
        %{"direction" => "inbound", "naptanId" => "C", "timeToStation" => 20}
      ]

      assert [feature] = Tfl.vehicles(arrivals, graph, line())
      assert feature.properties.seconds == 20
    end

    test "returns [] for a non-list arrivals payload" do
      assert Tfl.vehicles(%{"error" => "nope"}, %{coords: %{}, predecessors: %{}}, line()) == []
    end
  end
end
