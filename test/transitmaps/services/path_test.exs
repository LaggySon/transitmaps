defmodule Transitmaps.Services.PathTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Services.Path

  # A line in `Transitmaps.Gtfs.Cells.lines/3`'s form: `agency`'s strands,
  # each traced through its waypoints with a point about every 100 m.
  defp line(agency, strands) do
    {Jason.encode!(%{agency: agency}), Enum.map(strands, &pack(trace(&1)))}
  end

  defp trace(waypoints) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{lon1, lat1}, {lon2, lat2}] ->
      steps = max(round(max(abs(lon2 - lon1), abs(lat2 - lat1)) / 0.001), 1)

      for step <- 0..(steps - 1),
          do: point(lon1 + (lon2 - lon1) * step / steps, lat1 + (lat2 - lat1) * step / steps)
    end)
    |> Kernel.++([List.last(waypoints)])
  end

  defp point(lon, lat), do: {Float.round(lon / 1, 6), Float.round(lat / 1, 6)}

  defp pack(points) do
    {lons, lats} = Enum.unzip(points)
    bounds = {Enum.min(lons), Enum.min(lats), Enum.max(lons), Enum.max(lats)}
    {bounds, for({lon, lat} <- points, into: <<>>, do: <<lon / 1::float-64, lat / 1::float-64>>)}
  end

  defp passes?(strands, {lon, lat}) do
    Enum.any?(strands, fn strand ->
      Enum.any?(strand, fn [x, y] -> abs(x - lon) < 0.0005 and abs(y - lat) < 0.0005 end)
    end)
  end

  test "follows the track from stop to stop, taking the branch the service takes" do
    lines = [
      line("Own", [
        [{0.0, 51.0}, {0.0, 51.1}],
        # A branch leaving the main line halfway.
        [{0.0, 51.05}, {0.05, 51.1}]
      ])
    ]

    assert [strand] = Path.along(lines, "Own", [{0.0, 51.0}, {0.05, 51.1}])
    assert hd(strand) == [0.0, 51.0]
    assert List.last(strand) == [0.05, 51.1]
    assert passes?([strand], {0.0, 51.05})
    refute passes?([strand], {0.0, 51.1})
  end

  test "prefers its own operator's track to another's shortcut" do
    lines = [
      line("Own", [[{0.0, 51.0}, {0.02, 51.05}, {0.0, 51.1}]]),
      line("Other", [[{0.0, 51.0}, {0.0, 51.1}]])
    ]

    assert [strand] = Path.along(lines, "Own", [{0.0, 51.0}, {0.0, 51.1}])
    assert passes?([strand], {0.02, 51.05})
  end

  test "runs on another operator's track where its own has none" do
    lines = [
      line("Own", [[{0.0, 51.0}, {0.0, 51.05}]]),
      line("Other", [[{0.0, 51.05}, {0.0, 51.1}]])
    ]

    assert [strand] = Path.along(lines, "Own", [{0.0, 51.0}, {0.0, 51.05}, {0.0, 51.1}])
    assert hd(strand) == [0.0, 51.0]
    assert List.last(strand) == [0.0, 51.1]
  end

  test "crosses a few metres between strands that stop short of each other" do
    lines = [line("Own", [[{0.0, 51.0}, {0.0, 51.05}], [{0.0, 51.0502}, {0.0, 51.1}]])]

    assert [strand] = Path.along(lines, "Own", [{0.0, 51.0}, {0.0, 51.1}])
    assert List.last(strand) == [0.0, 51.1]
  end

  test "finds track that bulges far from the stops it joins" do
    lines = [line("Own", [[{0.0, 51.0}, {0.15, 51.05}, {0.0, 51.1}]])]

    assert [strand] = Path.along(lines, "Own", [{0.0, 51.0}, {0.0, 51.1}])
    assert passes?([strand], {0.15, 51.05})
  end

  test "leaves out a leg with no track between its stops" do
    lines = [line("Own", [[{0.0, 51.0}, {0.0, 51.1}]])]

    # One stop isn't on the map, and the next is miles from any track: the
    # run reaches the stop before it and goes no further.
    stops = [{0.0, 51.0}, nil, {0.0, 51.05}, {1.0, 52.0}, {0.0, 51.1}]

    assert [strand] = Path.along(lines, "Own", stops)
    assert hd(strand) == [0.0, 51.0]
    assert List.last(strand) == [0.0, 51.05]

    assert Path.along(lines, "Own", [{1.0, 52.0}, {0.0, 51.1}]) == []
  end
end
