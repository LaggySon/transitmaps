defmodule Transitmaps.ServicesTest do
  use Transitmaps.DataCase, async: true

  import Ecto.Query
  import Transitmaps.Realtime.GtfsRt, only: [encode: 1]

  alias Transitmaps.{Departures, GtfsFixture, Repo, Services}
  alias Transitmaps.Gtfs.{Feed, Importer, Stop}

  @moduletag :tmp_dir

  # Monday 2 March 2026, half past seven in London (GMT, so UTC too).
  @today ~D[2026-03-02]
  @now ~U[2026-03-02 07:30:00Z] |> DateTime.to_unix()

  @every_day {"calendar.txt",
              "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n" <>
                "S1,1,1,1,1,1,1,1,20260101,20261231\n"}

  # The fixture's one train calls at Station 1, 2 and 3 at 08:01, 08:02 and
  # 08:03, every day.
  defp import_tiny!(dir, opts \\ []) do
    files = [@every_day | Keyword.get(opts, :files, [])]
    zip = GtfsFixture.write!(Path.join(dir, "tiny.zip"), files: files)

    {:ok, feed} =
      Importer.import_feed("tiny-services", zip,
        today: @today,
        feed: Keyword.get(opts, :feed, %{})
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

  defp at(time), do: DateTime.new!(@today, time, "Etc/UTC") |> DateTime.to_unix()

  defp show!(service) do
    {:ok, result} =
      service
      |> Map.update!(:date, &Date.from_iso8601!/1)
      |> Services.show()

    result
  end

  test "a departure opens to its whole run: every stop, with the last one's arrival",
       %{tmp_dir: dir} do
    {feed, stops} = import_tiny!(dir)

    %{departures: [departure | _]} = Departures.list([stops["ST1"]], now: @now)

    assert %{feed: feed_id, trip: "T1", date: "2026-03-02", seq: 1} = departure.service
    assert feed_id == feed.id
    assert departure.service.at == at(~T[08:01:00])

    result = show!(departure.service)

    assert %{
             line: %{name: "T1", agency: "Tiny Rail", category: "rail"},
             destination: "Station 3",
             date: "2026-03-02",
             timezone: "Europe/London",
             live: "none",
             updated_at: nil,
             cancelled: false
           } = result

    assert Enum.map(result.calls, &{&1.name, &1.station, &1.scheduled, &1.status}) == [
             {"Station 1", stops["ST1"], at(~T[08:01:00]), "scheduled"},
             {"Station 2", stops["ST2"], at(~T[08:02:00]), "scheduled"},
             {"Station 3", stops["ST3"], at(~T[08:03:00]), "scheduled"}
           ]

    assert %{lng: -0.2, lat: 51.5, pickup: true, drop_off: true} = hd(result.calls)
  end

  test "a trip, feed or bucket it can't find is not found", %{tmp_dir: dir} do
    {feed, _stops} = import_tiny!(dir)

    for service <- [
          %{feed: feed.id, trip: "NOPE", date: @today},
          %{feed: feed.id + 1, trip: "T1", date: @today}
        ] do
      assert Services.show(service) == {:error, :not_found}
    end

    # An agency imported before trips were kept has no runs to open, and
    # its departures say so by having no service.
    Repo.update_all(from(f in Feed, where: f.id == ^feed.id), set: [trip_buckets: nil])
    assert Services.show(%{feed: feed.id, trip: "T1", date: @today}) == {:error, :not_found}
  end

  test "live times carry a delay on down the line", %{tmp_dir: dir} do
    {feed, _stops} = import_tiny!(dir, feed: %{catalog_id: "mdb-9001"})

    stub_trip_updates([
      [
        {1, encode([{1, "T1"}, {3, "20260302"}])},
        {2, encode([{1, 2}, {4, "ST2"}, {3, encode([{1, 300}])}])}
      ]
    ])

    result = show!(%{feed: feed.id, trip: "T1", date: "2026-03-02"})

    assert %{live: "live", updated_at: updated_at} = result
    assert is_integer(updated_at)

    assert Enum.map(result.calls, &{&1.status, &1.delay}) == [
             {"scheduled", nil},
             {"late", 300},
             {"late", 300}
           ]

    assert Enum.at(result.calls, 2).time == at(~T[08:08:00])
  end

  test "a trip run at a frequency opens to the run that was clicked", %{tmp_dir: dir} do
    frequencies =
      {"frequencies.txt", "trip_id,start_time,end_time,headway_secs\nT1,08:01:00,09:00:00,1800\n"}

    {_feed, stops} = import_tiny!(dir, files: [frequencies])

    %{departures: departures} = Departures.list([stops["ST1"]], now: @now)
    later = Enum.find(departures, &(&1.scheduled == at(~T[08:31:00])))

    assert Enum.map(show!(later.service).calls, & &1.scheduled) == [
             at(~T[08:31:00]),
             at(~T[08:32:00]),
             at(~T[08:33:00])
           ]
  end
end
