defmodule Transitmaps.DeparturesTest do
  use Transitmaps.DataCase, async: true

  import Transitmaps.Realtime.GtfsRt, only: [encode: 1]

  alias Transitmaps.{Departures, Gtfs, GtfsFixture, Repo}
  alias Transitmaps.Gtfs.{Feed, Importer, Stop}

  @moduletag :tmp_dir

  # Monday 2 March 2026, half past seven in London (GMT, so UTC too).
  @today ~D[2026-03-02]
  @now ~U[2026-03-02 07:30:00Z] |> DateTime.to_unix()

  # The fixture's one train calls at Station 1, 2 and 3 at 08:01, 08:02 and
  # 08:03, every day.
  defp import_tiny!(dir, opts \\ []) do
    zip =
      GtfsFixture.write!(Path.join(dir, "tiny.zip"),
        files: [
          {"calendar.txt",
           "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n" <>
             "S1,1,1,1,1,1,1,1,20260101,20261231\n"}
        ]
      )

    {:ok, feed} =
      Importer.import_feed(
        Keyword.get(opts, :name, "tiny"),
        zip,
        Keyword.merge([today: @today], opts)
      )

    stops = Repo.all(from s in Stop, where: s.feed_id == ^feed.id)
    {feed, Map.new(stops, &{&1.stop_id, &1.id})}
  end

  defp stub_trip_updates(updates) do
    entities =
      for {update, i} <- Enum.with_index(updates),
          do: {2, encode([{1, "e#{i}"}, {3, encode(update)}])}

    body = encode([{1, encode([{1, "2.0"}])} | entities])
    Req.Test.stub(Transitmaps.Realtime, &Plug.Conn.send_resp(&1, 200, body))
  end

  describe "a timetable without live times" do
    test "lists the next departures in time order, leaving out the last stop", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir)

      result = Departures.list([stops["ST1"], stops["ST2"], stops["ST3"]], now: @now)

      assert %{timezone: "Europe/London", live: "none", timetable: "ok", updated_at: nil} = result
      assert [first, second | _] = result.departures

      assert %{
               time: time,
               scheduled: time,
               delay: nil,
               status: "scheduled",
               destination: "Station 3",
               platform: nil,
               line: %{name: "T1", agency: "Tiny Rail", category: "rail"}
             } = first

      assert time == ~U[2026-03-02 08:01:00Z] |> DateTime.to_unix()
      assert second.time == time + 60

      # Tomorrow's trains follow today's, and Station 3 (the end of the
      # line) has none.
      assert Enum.map(result.departures, & &1.time) ==
               Enum.sort(Enum.map(result.departures, & &1.time))

      assert Departures.list([stops["ST3"]], now: @now).departures == []
    end

    test "reads on to later days, and says when there are more", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir)

      assert %{departures: [today, tomorrow], more: true} =
               Departures.list([stops["ST1"]], now: @now, limit: 2)

      assert tomorrow.time - today.time == 24 * 3600

      # After today's train has gone, the next is tomorrow's.
      after_train = ~U[2026-03-02 09:00:00Z] |> DateTime.to_unix()
      assert %{departures: [next]} = Departures.list([stops["ST1"]], now: after_train, limit: 1)
      assert next.time == ~U[2026-03-03 08:01:00Z] |> DateTime.to_unix()
    end

    test "follows the clocks: London's summer time is an hour ahead of UTC", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir, today: ~D[2026-06-01])

      assert %{departures: [departure | _]} =
               Departures.list([stops["ST1"]],
                 now: ~U[2026-06-01 06:00:00Z] |> DateTime.to_unix()
               )

      assert departure.time == ~U[2026-06-01 07:01:00Z] |> DateTime.to_unix()
    end

    test "says when the timetable has run out", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir)
      much_later = ~U[2026-06-01 07:30:00Z] |> DateTime.to_unix()

      assert %{departures: [], timetable: "expired"} =
               Departures.list([stops["ST1"]], now: much_later)
    end

    test "has nothing for unknown stops" do
      assert %{departures: [], timetable: "none", live: "none", more: false} =
               Departures.list([-1])

      assert %{departures: []} = Departures.list([])
    end
  end

  describe "live times" do
    test "lay delays and cancellations over the timetable", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir, feed: %{catalog_id: "mdb-9001"})

      stub_trip_updates([
        [
          {1, encode([{1, "T1"}, {3, "20260302"}])},
          {2, encode([{1, 2}, {4, "ST2"}, {3, encode([{1, 300}])}])}
        ]
      ])

      result = Departures.list([stops["ST1"], stops["ST2"]], now: @now)
      assert %{live: "live", updated_at: updated_at} = result
      assert is_integer(updated_at)

      [at_one, at_two | _] = result.departures
      scheduled_two = ~U[2026-03-02 08:02:00Z] |> DateTime.to_unix()

      # No word on Station 1, before the delay: as timetabled.
      assert %{status: "scheduled", delay: nil} = at_one
      assert %{status: "late", delay: 300, scheduled: ^scheduled_two} = at_two
      assert at_two.time == scheduled_two + 300

      # Tomorrow's train isn't today's.
      assert result.departures |> Enum.drop(2) |> Enum.all?(&(&1.status == "scheduled"))
    end

    test "carry a delay on to later stops, and mark cancelled trains", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir, feed: %{catalog_id: "mdb-9001"})

      stub_trip_updates([
        [
          {1, encode([{1, "T1"}, {3, "20260302"}])},
          {2, encode([{1, 1}, {4, "ST1"}, {3, encode([{1, 30}])}])}
        ]
      ])

      assert %{departures: [%{status: "on_time", delay: 30}, %{status: "on_time", delay: 30} | _]} =
               Departures.list([stops["ST1"], stops["ST2"]], now: @now)

      stub_trip_updates([[{1, encode([{1, "T1"}, {4, 3}])}]])

      assert %{departures: [%{status: "cancelled", delay: nil} | _]} =
               Departures.list([stops["ST1"]], now: @now)
    end

    test "fall back to the timetable when the live feed can't be reached", %{tmp_dir: dir} do
      {_feed, stops} = import_tiny!(dir, feed: %{catalog_id: "mdb-9001"})
      Req.Test.stub(Transitmaps.Realtime, &Plug.Conn.send_resp(&1, 503, "down"))

      assert %{live: "unavailable", departures: [%{status: "scheduled"} | _]} =
               Departures.list([stops["ST1"]], now: @now)
    end
  end

  describe "TfL's stations" do
    setup do
      feed =
        Repo.insert!(%Feed{name: "tfl", label: "Transport for London", timezone: "Europe/London"})

      stop =
        Repo.insert!(%Stop{
          feed_id: feed.id,
          stop_id: "940GZZLUKSX",
          name: "King's Cross St. Pancras",
          lat: 51.53,
          lon: -0.12,
          location_type: 1,
          categories: ["metro"],
          lines: [
            %{
              "name" => "Circle",
              "agency" => "Circle",
              "color" => "#FFD329",
              "category" => "metro"
            }
          ]
        })

      %{feed: feed, stop: stop}
    end

    test "list TfL's live arrivals, without trains that end there", %{stop: stop} do
      soon = DateTime.utc_now() |> DateTime.add(300) |> DateTime.truncate(:second)

      Req.Test.stub(Transitmaps.Realtime.Tfl, fn conn ->
        assert conn.request_path == "/StopPoint/940GZZLUKSX/Arrivals"

        Req.Test.json(conn, [
          %{
            "lineName" => "Circle",
            "modeName" => "tube",
            "destinationName" => "Edgware Road (Circle Line) Underground Station",
            "destinationNaptanId" => "940GZZLUERC",
            "platformName" => "Eastbound - Platform 2",
            "expectedArrival" => DateTime.to_iso8601(soon)
          },
          %{
            "lineName" => "Circle",
            "modeName" => "tube",
            "destinationName" => "King's Cross St. Pancras Underground Station",
            "destinationNaptanId" => "940GZZLUKSX",
            "expectedArrival" => DateTime.to_iso8601(soon)
          }
        ])
      end)

      assert %{live: "live", timetable: "none", departures: [departure]} =
               Departures.list([stop.id])

      assert departure == %{
               time: DateTime.to_unix(soon),
               scheduled: nil,
               delay: nil,
               status: "live",
               destination: "Edgware Road (Circle Line)",
               platform: "2",
               line: %{
                 name: "Circle",
                 agency: "Transport for London",
                 category: "metro",
                 color: "#FFD329"
               }
             }
    end

    test "say when TfL can't be reached", %{stop: stop} do
      Req.Test.stub(Transitmaps.Realtime.Tfl, &Plug.Conn.send_resp(&1, 500, "oops"))
      assert %{live: "unavailable", departures: []} = Departures.list([stop.id])
    end

    test "are marked as having departures to show", %{feed: feed} do
      assert %{features: [%{properties: %{ids: [_id]}}]} =
               Gtfs.stop_feature_collection(["metro"], feed.id)
    end
  end

  test "station markers name the stops with departures", %{tmp_dir: dir} do
    {feed, stops} = import_tiny!(dir)

    ids =
      Gtfs.stop_feature_collection(["rail"], feed.id).features
      |> Map.new(&{&1.properties.name, &1.properties[:ids]})

    assert ids["Station 1"] == [stops["ST1"]]
    assert ids["Station 2"] == [stops["ST2"]]
    # The end of the line has no departures.
    assert ids["Station 3"] == nil
  end

  test "a re-import replaces the timetable", %{tmp_dir: dir} do
    {feed, _stops} = import_tiny!(dir)
    {again, _stops} = import_tiny!(dir)

    assert again.id == feed.id
    assert %{timezone: "Europe/London", timetable_from: ~D[2026-02-28]} = Repo.get!(Feed, feed.id)

    count = Repo.one(from d in "stop_departures", select: count())
    assert count == 2
  end
end
