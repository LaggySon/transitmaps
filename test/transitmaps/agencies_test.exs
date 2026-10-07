defmodule Transitmaps.AgenciesTest do
  use Transitmaps.DataCase, async: false

  # A failed download logs a warning; those failures are the point of some tests.
  @moduletag :capture_log

  alias Transitmaps.Agencies
  alias Transitmaps.Agencies.FeedImport
  alias Transitmaps.Gtfs.{Feed, Importer}
  alias Transitmaps.GtfsFixture

  # Where the fixture catalog points its agencies' downloads.
  @tiny_zip "tmp/fixtures/tiny-gtfs.zip"
  @mbta_zip "tmp/fixtures/mbta.zip"
  @shapeless_zip "tmp/fixtures/shapeless-gtfs.zip"
  @stop_to_stop_zip "tmp/fixtures/stop-to-stop-gtfs.zip"
  @hop_zip "tmp/fixtures/hop-gtfs.zip"
  @padded_zip "tmp/fixtures/padded-gtfs.zip"

  setup do
    GtfsFixture.write!(@tiny_zip)
    on_exit(fn -> File.rm(@tiny_zip) end)
  end

  describe "request/1" do
    test "queues a catalog agency once" do
      Agencies.subscribe()

      assert {:ok, %FeedImport{status: "queued", label: "Tiny Rail"}} =
               Agencies.request("mdb-9001")

      assert {:ok, %FeedImport{status: "queued"}} = Agencies.request("mdb-9001")
      assert Repo.aggregate(FeedImport, :count) == 1
      assert_received {:import_updated, %FeedImport{catalog_id: "mdb-9001"}}
    end

    test "turns away agencies the catalog doesn't offer" do
      assert Agencies.request("mdb-9003") == {:error, :unknown}
      assert Agencies.request("nonsense") == {:error, :unknown}
    end

    test "turns requests away once the queue is full" do
      for i <- 1..10,
          do: Repo.insert!(%FeedImport{catalog_id: "q#{i}", label: "Q", status: "queued"})

      assert Agencies.request("mdb-9001") == {:error, :busy}
    end
  end

  describe "request_package/1" do
    test "lists each pack with only the members the catalog offers" do
      bay_area = Enum.find(Agencies.packages(), &(&1.id == "bay-area"))
      assert bay_area.catalog_ids == ["mdb-53", "mdb-2455"]
    end

    test "queues every member of a pack once" do
      Agencies.subscribe()

      assert {:ok, [%FeedImport{catalog_id: "mdb-53"}, %FeedImport{catalog_id: "mdb-2455"}]} =
               Agencies.request_package("bay-area")

      assert {:ok, []} = Agencies.request_package("bay-area")
      assert Repo.aggregate(FeedImport, :count) == 2
      assert_received {:import_updated, %FeedImport{catalog_id: "mdb-2455", status: "queued"}}
    end

    test "is one request against the queue limit" do
      for i <- 1..9,
          do: Repo.insert!(%FeedImport{catalog_id: "q#{i}", label: "Q", status: "queued"})

      assert {:ok, [_, _]} = Agencies.request_package("bay-area")
      assert Agencies.request_package("northeast-corridor") == {:error, :busy}
    end

    test "turns away packs that don't exist" do
      assert Agencies.request_package("atlantis") == {:error, :unknown}
    end
  end

  describe "run_import/1" do
    test "downloads the agency and puts it on the map where its stops are" do
      {:ok, _import} = Agencies.request("mdb-9001")
      Agencies.subscribe()

      assert :ok = Agencies.run_import("mdb-9001")

      assert %FeedImport{status: "ready", imported_at: %DateTime{}} =
               Agencies.get_import("mdb-9001")

      assert_received :feeds_changed

      assert [%{label: "Tiny Rail", catalog_id: "mdb-9001", bounds: bounds, counts: counts}] =
               Agencies.list_feeds()

      assert [[west, south], [east, north]] = bounds
      assert west >= -0.2 and east <= 0.0 and south >= 51.5 and north <= 51.54
      assert counts == %{"rail" => 1}
      refute File.exists?("priv/gtfs_cache/catalog-mdb-9001.zip")
    end

    test "replaces the hand-curated feeds it supersedes" do
      GtfsFixture.write!(@mbta_zip, agency: "MBTA", stops: [{-71.06, 42.35}, {-71.05, 42.36}])
      on_exit(fn -> File.rm(@mbta_zip) end)
      Importer.import_feed("mbta-rapid", @tiny_zip)
      Importer.import_feed("path", @tiny_zip)

      {:ok, _import} = Agencies.request("mdb-437")
      Agencies.run_import("mdb-437")

      names = Feed |> Repo.all() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["catalog-mdb-437", "path"]
    end

    test "turns away an agency without route shapes, and drops an earlier import of it" do
      GtfsFixture.write!(@shapeless_zip, shapes: false)
      on_exit(fn -> File.rm(@shapeless_zip) end)
      {:ok, _feed} = Importer.import_feed("catalog-mdb-9007", @tiny_zip)

      {:ok, _import} = Agencies.request("mdb-9007")
      Agencies.subscribe()
      Agencies.run_import("mdb-9007")

      assert %FeedImport{status: "failed", error: error} = Agencies.get_import("mdb-9007")
      assert error =~ "shapes"
      assert_received :feeds_changed
      assert Agencies.list_feeds() == []
    end

    test "turns away an agency whose shapes only join its stations" do
      GtfsFixture.write!(@stop_to_stop_zip, shapes: :stop_to_stop)
      on_exit(fn -> File.rm(@stop_to_stop_zip) end)

      assert Importer.import_feed("stop-to-stop", @stop_to_stop_zip) == {:error, :no_shapes}
      assert Agencies.list_feeds() == []
    end

    test "draws a shape's traced track but not a long hop between stations" do
      # Traced for 97 km, then 76 km straight to the last station.
      stops = [{-1.50, 51.50}, {-0.80, 51.51}, {-0.10, 51.52}, {1.00, 51.54}]
      GtfsFixture.write!(@hop_zip, stops: stops, shapes: :last_leg_hop)
      on_exit(fn -> File.rm(@hop_zip) end)

      {:ok, feed} = Importer.import_feed("hop", @hop_zip)

      [%{geometry: %{"coordinates" => lines}}] = Repo.all(Ecto.assoc(feed, :routes))
      assert lines |> List.flatten() |> Enum.take_every(2) |> Enum.max() < -0.09
    end

    test "draws a short straight stretch between stations" do
      GtfsFixture.write!(@hop_zip, shapes: :last_leg_hop)
      on_exit(fn -> File.rm(@hop_zip) end)

      {:ok, feed} = Importer.import_feed("hop", @hop_zip)

      [%{geometry: %{"coordinates" => lines}}] = Repo.all(Ecto.assoc(feed, :routes))
      assert lines |> List.flatten() |> Enum.take_every(2) |> Enum.max() == 0.0
    end

    test "draws a train line's rarely run branch" do
      # Six variants of the trunk, each busier than the one branch train.
      trunk = for i <- 0..40, do: {-0.20 + i * 0.005, 51.50 + :math.sin(i / 4) * 0.001}
      branch = for i <- 0..40, do: {-0.20 + i * 0.002, 51.50 - i * 0.004}

      shapes =
        for(n <- 1..6, do: {"T#{n}", trunk}) ++ [{"BR", branch}]

      trips =
        for(
          {shape_id, _} <- shapes,
          copies = if(shape_id == "BR", do: 1, else: 3),
          k <- 1..copies,
          do: "R1,S1,#{shape_id}-#{k},#{shape_id}"
        )

      zip = "tmp/fixtures/branch-gtfs.zip"
      on_exit(fn -> File.rm(zip) end)
      [{x1, y1} | _] = trunk
      {x2, y2} = List.last(branch)

      files = [
        {~c"agency.txt",
         "agency_id,agency_name,agency_url,agency_timezone\nA,Branch Rail,https://e.com,Europe/London\n"},
        {~c"routes.txt", "route_id,agency_id,route_short_name,route_type\nR1,A,B1,2\n"},
        {~c"trips.txt",
         "route_id,service_id,trip_id,shape_id\n" <> Enum.join(trips, "\n") <> "\n"},
        {~c"stops.txt",
         "stop_id,stop_name,stop_lat,stop_lon\nS1,One,#{y1},#{x1}\nS2,Two,#{y2},#{x2}\n"},
        {~c"stop_times.txt",
         "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nBR-1,08:00:00,08:00:00,S1,1\nBR-1,08:30:00,08:30:00,S2,2\n"},
        {~c"shapes.txt",
         "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n" <>
           Enum.map_join(shapes, fn {id, points} ->
             points
             |> Enum.with_index(1)
             |> Enum.map_join(fn {{lon, lat}, i} -> "#{id},#{lat},#{lon},#{i}\n" end)
           end)}
      ]

      File.mkdir_p!("tmp/fixtures")
      {:ok, _} = :zip.create(String.to_charlist(zip), files)

      {:ok, feed} = Importer.import_feed("branch", zip)

      [%{geometry: %{"coordinates" => lines}}] = Repo.all(Ecto.assoc(feed, :routes))
      assert length(lines) == 2
      assert lines |> List.flatten() |> Enum.drop(1) |> Enum.take_every(2) |> Enum.min() < 51.4
    end

    test "imports a zip with a web page appended after the archive" do
      GtfsFixture.write!(@padded_zip)
      File.write!(@padded_zip, "<html><body>Download</body></html>\r\n", [:append])
      on_exit(fn -> File.rm(@padded_zip) end)

      assert {:ok, _feed} = Importer.import_feed("padded", @padded_zip)
    end

    test "records a failed download and lets it be retried" do
      {:ok, _import} = Agencies.request("mdb-9002")
      Agencies.run_import("mdb-9002")

      assert %FeedImport{status: "failed", error: error} = Agencies.get_import("mdb-9002")
      assert error =~ "couldn't"
      assert {:ok, %FeedImport{status: "queued"}} = Agencies.request("mdb-9002")
    end
  end

  test "hand-curated feeds are labelled and placed by their own stops" do
    Importer.import_feed("gb-rail", @tiny_zip)
    Importer.import_feed("my-feed", @tiny_zip, feed: %{label: "My Buses"})

    assert Agencies.list_feeds() |> Enum.map(& &1.label) == ["My Buses", "National Rail"]
  end
end
