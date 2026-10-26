defmodule Transitmaps.Gtfs.ImporterLinesTest do
  use Transitmaps.DataCase, async: true

  alias Transitmaps.{GtfsFixture, Repo}
  alias Transitmaps.Gtfs.{Feed, Importer, Route}

  @moduletag :tmp_dir

  defp import_metro!(dir, short_name) do
    zip =
      GtfsFixture.write!(Path.join(dir, "metro.zip"),
        agency: "Tyne and Wear Metro",
        files: [
          {"routes.txt",
           "route_id,agency_id,route_short_name,route_long_name,route_type\n" <>
             "R1,A1,#{short_name},,1\n"}
        ]
      )

    {:ok, feed} = Importer.import_feed("tyne-wear-metro", zip)
    {feed, Repo.get_by!(Route, feed_id: feed.id)}
  end

  test "names the Tyne and Wear Metro's coded lines and gives them their colours",
       %{tmp_dir: dir} do
    {feed, route} = import_metro!(dir, "YEL")

    assert %Feed{label: "Tyne and Wear Metro"} = feed

    assert %Route{
             category: "metro",
             short_name: "Yellow",
             long_name: "Yellow line",
             color: "#FEB300",
             text_color: "#000000"
           } = route
  end

  test "leaves a Metro route it doesn't know as the feed has it", %{tmp_dir: dir} do
    {_feed, route} = import_metro!(dir, "SHUTTLE")

    assert %Route{short_name: "SHUTTLE", long_name: nil, color: nil} = route
  end
end
