defmodule Transitmaps.Realtime.GtfsRtTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Realtime.GtfsRt

  import GtfsRt, only: [encode: 1]

  # A FeedMessage with a header, a trip running late (with a vehicle
  # position the reader skips), a cancelled trip, and an alert.
  defp feed do
    late =
      encode([
        {1, encode([{1, "T1"}, {3, "20260302"}, {5, "R1"}])},
        {2, encode([{1, 1}, {4, "ST1"}, {3, encode([{1, 120}, {3, 30}])}])},
        {2, encode([{1, 2}, {4, "ST2"}, {2, encode([{2, 1_772_438_520}])}])},
        {2, encode([{1, 3}, {4, "ST3"}, {5, 1}])},
        {3, encode([{1, "train 7"}])},
        {5, -90}
      ])

    cancelled = encode([{1, encode([{1, "T2"}, {4, 3}])}])

    encode([
      {1, encode([{1, "2.0"}, {3, 1_772_438_400}])},
      {2, encode([{1, "e1"}, {3, late}])},
      {2, encode([{1, "e2"}, {3, cancelled}])},
      {2, encode([{1, "e3"}, {5, encode([{1, "an alert"}])}])}
    ])
  end

  test "reads each trip's delays, times, skipped stops and cancellation" do
    assert [late, cancelled] = GtfsRt.trip_updates(feed())

    assert %{trip_id: "T1", start_date: "20260302", cancelled: false, delay: -90} = late

    assert [
             %{seq: 1, stop_id: "ST1", departure: {120, nil}, arrival: nil, skipped: false},
             %{seq: 2, stop_id: "ST2", arrival: {nil, 1_772_438_520}, departure: nil},
             %{seq: 3, stop_id: "ST3", skipped: true}
           ] = late.stops

    assert %{trip_id: "T2", start_date: nil, cancelled: true, stops: []} = cancelled
  end

  test "indexes trips by id, leaving each update to be read when asked for" do
    assert [{"T1", "20260302", late}, {"T2", nil, _cancelled}] = GtfsRt.index(feed())
    assert %{trip_id: "T1", delay: -90} = GtfsRt.trip_update(late)
  end

  test "reads negative 32 and 64-bit values" do
    event = encode([{1, -1}, {2, -5}])
    stop = encode([{1, 1}, {3, event}])
    update = encode([{1, encode([{1, "T"}])}, {2, stop}])

    assert [%{stops: [%{departure: {-1, -5}}]}] =
             GtfsRt.trip_updates(encode([{2, encode([{3, update}])}]))
  end

  test "skips fixed-width fields" do
    # A double (wire type 1) and a float (wire type 5) before the entity.
    message =
      <<0x49, 0::64, 0x55, 0::32>> <>
        encode([{2, encode([{3, encode([{1, encode([{1, "T"}])}])}])}])

    assert [%{trip_id: "T"}] = GtfsRt.trip_updates(message)
  end

  test "refuses a binary that isn't a protocol buffer" do
    assert_raise ArgumentError, fn -> GtfsRt.trip_updates(<<0x0B>>) end
    assert_raise MatchError, fn -> GtfsRt.trip_updates(<<0x12, 0x10, "short">>) end
  end
end
