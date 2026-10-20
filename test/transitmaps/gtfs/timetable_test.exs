defmodule Transitmaps.Gtfs.TimetableTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Gtfs.Timetable

  @moduletag :tmp_dir

  # Monday 2 March 2026: the window starts on Saturday 28 February, so
  # Monday is day 2, Tuesday day 3 and Wednesday day 4.
  @today ~D[2026-03-02]
  @monday 2
  @tuesday 3
  @wednesday 4

  @routes [
    %{
      route_id: "R1",
      short_name: "T1",
      long_name: "Tiny Line",
      agency_name: "Tiny Rail",
      category: "rail",
      color: "#123456"
    },
    %{
      route_id: "R2",
      short_name: "B1",
      long_name: nil,
      agency_name: "Tiny Bus",
      category: "bus",
      color: nil
    }
  ]

  defp write_feed!(dir) do
    files = %{
      "agency.txt" =>
        "agency_id,agency_name,agency_url,agency_timezone\nA1,Tiny Rail,https://example.com,Europe/London\n",
      "calendar.txt" =>
        "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n" <>
          "WK,1,1,1,1,1,0,0,20260101,20261231\n" <>
          "OLD,1,1,1,1,1,1,1,20250101,20251231\n",
      # No trains on Tuesday 3 March, and an extra one on Wednesday.
      "calendar_dates.txt" => "service_id,date,exception_type\nWK,20260303,2\nEXTRA,20260304,1\n",
      "trips.txt" =>
        "route_id,service_id,trip_id,trip_headsign\n" <>
          "R1,WK,T1,Gamma Docks\n" <>
          "R1,WK,T2,\n" <>
          "R1,EXTRA,T3,Beta\n" <>
          "R1,WK,F1,Beta\n" <>
          "R1,OLD,T4,Gamma\n" <>
          "R2,WK,B1,Gamma\n",
      "stops.txt" =>
        "stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station,platform_code\n" <>
          "STA,Alpha,51.5,-0.2,1,,\n" <>
          "STA1,Alpha platform 1,51.5,-0.2,0,STA,1\n" <>
          "ST2,Beta,51.52,-0.1,0,,\n" <>
          "ST3,Gamma,51.54,0.0,0,,\n",
      # Sets down only at Beta: not a departure.
      # Past midnight, to Alpha (no headsign: named after its last stop).
      "stop_times.txt" =>
        "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type\n" <>
          "T1,08:00:00,08:00:00,STA1,1,0\n" <>
          "T1,08:10:00,08:10:00,ST2,2,1\n" <>
          "T1,08:20:00,08:20:00,ST3,3,0\n" <>
          "T2,25:10:00,25:10:00,ST3,1,0\n" <>
          "T2,25:20:00,25:20:00,ST2,2,0\n" <>
          "T2,25:30:00,25:30:00,STA1,3,0\n" <>
          "T3,09:00:00,09:00:00,STA1,1,0\n" <>
          "T3,09:10:00,09:10:00,ST2,2,0\n" <>
          "F1,10:00:00,10:00:00,STA1,1,0\n" <>
          "F1,10:05:00,10:05:00,ST2,2,0\n" <>
          "T4,07:00:00,07:00:00,STA1,1,0\n" <>
          "T4,07:10:00,07:10:00,ST3,2,0\n" <>
          "B1,08:30:00,08:30:00,ST2,1,0\n" <>
          "B1,08:40:00,08:40:00,ST3,2,0\n",
      "frequencies.txt" => "trip_id,start_time,end_time,headway_secs\nF1,10:00:00,11:00:00,1200\n"
    }

    for {name, body} <- files, do: File.write!(Path.join(dir, name), body)
  end

  defp read(dir) do
    write_feed!(dir)
    Timetable.read(dir, @routes, today: @today)
  end

  defp departures(timetable, station, day) do
    timetable.stations
    |> Map.fetch!(station)
    |> Timetable.unpack()
    |> Timetable.departures(day)
    |> Enum.map(fn {seconds, {trip_id, line, destination}, _seq, stop_id, platform} ->
      {seconds, trip_id, line.short_name, destination, stop_id, platform}
    end)
  end

  test "reads the agency's time zone and counts the window from two days before today", %{
    tmp_dir: dir
  } do
    timetable = read(dir)

    assert timetable.timezone == "Europe/London"
    assert timetable.from == ~D[2026-02-28]
  end

  test "files platforms under their station, with each trip's days", %{tmp_dir: dir} do
    timetable = read(dir)

    assert Map.keys(timetable.stations) |> Enum.sort() == ["ST2", "ST3", "STA"]

    assert departures(timetable, "STA", @monday) == [
             {8 * 3600, "T1", "T1", "Gamma Docks", "STA1", "1"},
             # The frequency trip runs every 20 minutes from 10:00 until 11:00.
             {10 * 3600, "F1", "T1", "Beta", "STA1", "1"},
             {10 * 3600 + 1200, "F1", "T1", "Beta", "STA1", "1"},
             {10 * 3600 + 2400, "F1", "T1", "Beta", "STA1", "1"}
           ]

    # Tuesday's trains are taken off; Wednesday gets an extra one.
    assert departures(timetable, "STA", @tuesday) == []

    assert timetable |> departures("STA", @wednesday) |> Enum.map(&elem(&1, 1)) ==
             ["T1", "T3", "F1", "F1", "F1"]
  end

  test "leaves out last stops, set-down-only stops, buses and trips outside the window", %{
    tmp_dir: dir
  } do
    timetable = read(dir)

    # T1 only sets down at Beta and F1 ends there; the bus doesn't count.
    assert departures(timetable, "ST2", @monday) == [
             {25 * 3600 + 20 * 60, "T2", "T1", "Alpha", "ST2", nil}
           ]

    # T1 ends at Gamma, and T4's service ran in 2025.
    assert departures(timetable, "ST3", @monday) == [
             {25 * 3600 + 10 * 60, "T2", "T1", "Alpha", "ST3", nil}
           ]
  end

  test "a day outside the window has no departures", %{tmp_dir: dir} do
    timetable = read(dir)
    packed = timetable.stations |> Map.fetch!("STA") |> Timetable.unpack()

    assert Timetable.departures(packed, Timetable.days()) == []
    assert Timetable.departures(packed, -1) == []
  end

  test "a feed with no timetabled modes has no stations", %{tmp_dir: dir} do
    write_feed!(dir)
    timetable = Timetable.read(dir, Enum.filter(@routes, &(&1.category == "bus")), today: @today)

    assert timetable.stations == %{}
    assert timetable.timezone == "Europe/London"
  end

  test "reads GTFS times past midnight" do
    assert Timetable.parse_time("08:05:30") == 8 * 3600 + 5 * 60 + 30
    assert Timetable.parse_time(" 25:10:00") == 25 * 3600 + 600
    assert Timetable.parse_time("") == nil
    assert Timetable.parse_time("8:05") == nil
  end
end
