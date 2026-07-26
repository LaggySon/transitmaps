defmodule Transitmaps.JourneyTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Gtfs.Stop
  alias Transitmaps.Journey

  defp station(name, lines) do
    categories =
      lines
      |> Enum.map(&(Map.get(&1, :category) || Map.get(&1, "category")))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %Stop{name: name, lat: 51.5, lon: -0.1, categories: categories, lines: lines}
  end

  defp line(name, agency, category \\ "metro", color \\ "#112233") do
    %{name: name, agency: agency, category: category, color: color}
  end

  describe "find_station/2" do
    test "returns a blank error for empty input" do
      assert Journey.find_station([station("Alpha", [])], "  ") == {:error, :blank}
    end

    test "returns a not-found error when nothing matches" do
      assert Journey.find_station([station("Alpha", [])], "Zeta") ==
               {:error, {:not_found, "Zeta"}}
    end

    test "matches case-insensitively on a substring" do
      stations = [station("Kings Cross", []), station("Paddington", [])]
      assert {:ok, %Stop{name: "Paddington"}} = Journey.find_station(stations, "padding")
    end

    test "prefers an exact match over a longer containing name" do
      stations = [station("Oxford Circus", []), station("Oxford", [])]
      assert {:ok, %Stop{name: "Oxford"}} = Journey.find_station(stations, "oxford")
    end
  end

  describe "plan/3" do
    test "returns a single direct leg when one line serves both stations" do
      victoria = line("Victoria", "TfL")
      stations = [station("Brixton", [victoria]), station("Green Park", [victoria])]

      assert {:ok, itinerary} = Journey.plan(stations, "Brixton", "Green Park")
      assert itinerary.origin.name == "Brixton"
      assert itinerary.destination.name == "Green Park"
      assert itinerary.transfers == 0
      assert [leg] = itinerary.legs
      assert leg.line.name == "Victoria"
      assert leg.from.name == "Brixton"
      assert leg.to.name == "Green Park"
    end

    test "routes through an interchange with a single transfer" do
      victoria = line("Victoria", "TfL")
      central = line("Central", "TfL")

      stations = [
        station("Brixton", [victoria]),
        station("Oxford Circus", [victoria, central]),
        station("Bank", [central])
      ]

      assert {:ok, itinerary} = Journey.plan(stations, "Brixton", "Bank")
      assert itinerary.transfers == 1
      assert [first, second] = itinerary.legs

      assert first.line.name == "Victoria"
      assert first.from.name == "Brixton"
      assert first.to.name == "Oxford Circus"

      assert second.line.name == "Central"
      assert second.from.name == "Oxford Circus"
      assert second.to.name == "Bank"
    end

    test "chooses the fewest-transfer route when several exist" do
      fast = line("Fast", "TfL")
      slow_a = line("SlowA", "TfL")
      slow_b = line("SlowB", "TfL")

      stations = [
        station("Start", [fast, slow_a]),
        station("Middle", [slow_a, slow_b]),
        station("End", [fast, slow_b])
      ]

      assert {:ok, itinerary} = Journey.plan(stations, "Start", "End")
      assert itinerary.transfers == 0
      assert [%{line: %{name: "Fast"}}] = itinerary.legs
    end

    test "reports when no route connects the two stations" do
      stations = [
        station("Island A", [line("A", "TfL")]),
        station("Island B", [line("B", "TfL")])
      ]

      assert Journey.plan(stations, "Island A", "Island B") == {:error, :no_route}
    end

    test "reports when start and destination resolve to the same station" do
      stations = [station("Alpha", [line("A", "TfL")])]
      assert Journey.plan(stations, "Alpha", "Alpha") == {:error, :same_station}
    end

    test "propagates a not-found query" do
      stations = [station("Alpha", [line("A", "TfL")])]
      assert Journey.plan(stations, "Alpha", "Nowhere") == {:error, {:not_found, "Nowhere"}}
    end

    test "treats lines shared by name and agency across feeds as connected" do
      # Lines loaded from jsonb arrive with string keys; the planner must still
      # recognise them as the same line as atom-keyed struct data.
      atom_line = %{name: "Shared", agency: "Rail Co", category: "rail", color: "#123456"}
      string_line = %{"name" => "Shared", "agency" => "Rail Co", "category" => "rail"}

      stations = [
        station("North", [atom_line]),
        station("South", [string_line])
      ]

      assert {:ok, itinerary} = Journey.plan(stations, "North", "South")
      assert itinerary.transfers == 0
      assert [%{line: %{name: "Shared"}}] = itinerary.legs
    end
  end
end
