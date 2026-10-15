defmodule Transitmaps.StationsTest do
  use Transitmaps.DataCase, async: true

  alias Transitmaps.Gtfs.{Feed, Stop}
  alias Transitmaps.Stations

  setup do
    rail = Repo.insert!(%Feed{name: "rail"})
    metro = Repo.insert!(%Feed{name: "metro"})

    stop = fn feed, id, name, {lon, lat}, categories ->
      Repo.insert!(%Stop{
        feed_id: feed.id,
        stop_id: id,
        name: name,
        lon: lon,
        lat: lat,
        categories: categories,
        lines: []
      })
    end

    # One station listed twice by one agency (its platforms) and once by
    # another, a bus stop of the same name, and a different station.
    stop.(rail, "1", "Zürich HB", {8.540, 47.378}, ["rail"])
    stop.(rail, "2", "Zürich HB", {8.541, 47.377}, ["rail"])
    stop.(metro, "1", "Zürich HB", {8.539, 47.378}, ["tram"])
    stop.(metro, "2", "Zürich HB", {8.538, 47.379}, ["bus"])
    stop.(rail, "3", "Zürich Oerlikon", {8.544, 47.411}, ["rail"])
    :ok
  end

  test "finds stations by name, without accents, one entry per place" do
    assert [%{name: "Zürich HB", categories: ["tram", "rail"]}, %{name: "Zürich Oerlikon"}] =
             Stations.search("zurich")

    assert [%{name: "Zürich HB"}] = Stations.search("zurich hb")
    assert Stations.search("z") == []
    assert Stations.search("geneva") == []
  end
end
