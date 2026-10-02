defmodule Transitmaps.Gtfs.CsvTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Gtfs.Csv

  @moduletag :tmp_dir

  test "reads rows keyed by header, without a BOM or padding spaces", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "trips.txt"),
      "﻿route_id, trip_id, shape_id\nBNSF, BN1200, BNSF_IB_1\nUP-N,UN300,\n"
    )

    assert Csv.stream(dir, "trips.txt") |> Enum.to_list() == [
             %{"route_id" => "BNSF", "trip_id" => "BN1200", "shape_id" => "BNSF_IB_1"},
             %{"route_id" => "UP-N", "trip_id" => "UN300", "shape_id" => ""}
           ]
  end

  test "a missing file is an empty stream", %{tmp_dir: dir} do
    assert Csv.stream(dir, "shapes.txt") |> Enum.to_list() == []
  end
end
