defmodule Transitmaps.Services.TflTest do
  use Transitmaps.DataCase, async: true

  alias Transitmaps.{Departures, Services}
  alias Transitmaps.Gtfs.{Importer, Stop}

  # A line of four stations, A to D, west to east. B is an interchange,
  # imported under its hub id, as TfL lists interchanges.
  @stations [
    {"940GZZLUAAA", "Alpha", -0.20},
    {"HUBBBB", "Bravo", -0.18},
    {"940GZZLUCCC", "Charlie", -0.16},
    {"940GZZLUDDD", "Delta", -0.14}
  ]

  setup do
    route = %{
      route_id: "tfl:bakerloo",
      agency_name: "Transport for London",
      short_name: "Bakerloo",
      long_name: "Bakerloo",
      route_type: 1,
      category: "metro",
      color: "#B36305",
      text_color: "#FFFFFF",
      geometry: %{
        "type" => "MultiLineString",
        "coordinates" => [Enum.map(@stations, fn {_id, _name, lon} -> [lon, 51.5] end)]
      }
    }

    stations =
      for {id, name, lon} <- @stations do
        %{
          stop_id: id,
          name: name,
          lat: 51.5,
          lon: lon,
          location_type: 1,
          route_ids: ["tfl:bakerloo"]
        }
      end

    {:ok, feed} =
      Importer.persist_rows("tfl", "https://api.tfl.gov.uk", [route], stations,
        feed: %{timezone: "Europe/London"}
      )

    stops = Repo.all(from s in Stop, where: s.feed_id == ^feed.id)
    %{feed: feed, stops: Map.new(stops, &{&1.stop_id, &1.id})}
  end

  defp iso(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # TfL's answers. Train 201 runs from Bravo to Delta; TfL predicts it as
  # far as Charlie. A train on another line shares its number.
  defp stub_tfl(soon, opts \\ []) do
    vehicle = Keyword.get(opts, :vehicle, "201")
    ids = ["940GZZLUAAA", "940GZZLUBBB", "940GZZLUCCC", "940GZZLUDDD"]
    orders = Keyword.get(opts, :orders, [ids, Enum.reverse(ids)])

    Req.Test.stub(Transitmaps.Realtime.Tfl, fn conn ->
      case conn.request_path do
        "/StopPoint/HUBBBB" ->
          Req.Test.json(conn, %{
            "id" => "HUBBBB",
            "children" => [%{"id" => "940GZZLUBBB"}, %{"id" => "490G000123"}]
          })

        "/StopPoint/940GZZLUBBB/Arrivals" ->
          Req.Test.json(conn, [
            %{
              "lineId" => "bakerloo",
              "lineName" => "Bakerloo",
              "modeName" => "tube",
              "vehicleId" => vehicle,
              "naptanId" => "940GZZLUBBB",
              "destinationNaptanId" => "940GZZLUDDD",
              "destinationName" => "Delta Underground Station",
              "platformName" => "Eastbound - Platform 1",
              "expectedArrival" => iso(soon)
            }
          ])

        "/Vehicle/201/Arrivals" ->
          Req.Test.json(conn, [
            %{
              "lineId" => "bakerloo",
              "naptanId" => "940GZZLUCCC",
              "stationName" => "Charlie Underground Station",
              "destinationNaptanId" => "940GZZLUDDD",
              "platformName" => "Eastbound - Platform 2",
              "expectedArrival" => iso(soon + 120)
            },
            %{
              "lineId" => "bakerloo",
              "naptanId" => "940GZZLUBBB",
              "destinationNaptanId" => "940GZZLUDDD",
              "platformName" => "Eastbound - Platform 1",
              "expectedArrival" => iso(soon)
            },
            %{
              "lineId" => "victoria",
              "naptanId" => "940GZZLUDDD",
              "destinationNaptanId" => "940GZZLUXXX",
              "expectedArrival" => iso(soon + 60)
            }
          ])

        "/Line/bakerloo/Route/Sequence/all" ->
          Req.Test.json(conn, %{
            "orderedLineRoutes" => Enum.map(orders, &%{"naptanIds" => &1}),
            "stopPointSequences" => [
              %{
                "stopPoint" =>
                  for id <- ids do
                    %{
                      "id" => id,
                      "topMostParentId" => if(id == "940GZZLUBBB", do: "HUBBBB", else: id)
                    }
                  end
              }
            ]
          })

        path ->
          flunk("unexpected TfL request #{path}")
      end
    end)
  end

  test "an interchange lists its stations' trains, each opening to its run", %{
    stops: stops
  } do
    soon = System.os_time(:second) + 300
    stub_tfl(soon)

    assert %{live: "live", departures: [departure]} = Departures.list([stops["HUBBBB"]])
    assert departure.destination == "Delta"

    assert %{trip: "tfl:bakerloo:940GZZLUBBB:940GZZLUDDD:201", at: ^soon} = departure.service

    {:ok, run} = Services.show(Map.update!(departure.service, :date, &Date.from_iso8601!/1))

    assert %{
             line: %{name: "Bakerloo", agency: "Transport for London", color: "#B36305"},
             destination: "Delta",
             timezone: "Europe/London",
             live: "live",
             cancelled: false
           } = run

    # The whole route, on the map's stations: Alpha is behind the train
    # (TfL predicts it from Bravo on), and TfL's predictions stop short of
    # Delta, so it has no time.
    assert Enum.map(run.calls, &{&1.name, &1.station, &1.time, &1.status, &1.passed}) == [
             {"Alpha", stops["940GZZLUAAA"], nil, "scheduled", true},
             {"Bravo", stops["HUBBBB"], soon, "live", false},
             {"Charlie", stops["940GZZLUCCC"], soon + 120, "live", false},
             {"Delta", stops["940GZZLUDDD"], nil, "scheduled", false}
           ]

    assert Enum.map(run.calls, & &1.platform) == [nil, "1", "2", nil]
  end

  # Trains reach Bravo from Alpha, or from a branch (Echo, off the map):
  # which one this train came along, TfL doesn't say.
  test "a run reaches back only as far as its route is certain", %{stops: stops} do
    soon = System.os_time(:second) + 300

    stub_tfl(soon,
      vehicle: "",
      orders: [
        ["940GZZLUAAA", "940GZZLUBBB", "940GZZLUCCC", "940GZZLUDDD"],
        ["940GZZLUEEE", "940GZZLUBBB", "940GZZLUCCC", "940GZZLUDDD"]
      ]
    )

    %{departures: [departure]} = Departures.list([stops["HUBBBB"]])
    {:ok, run} = Services.show(Map.update!(departure.service, :date, &Date.from_iso8601!/1))
    assert Enum.map(run.calls, & &1.name) == ["Bravo", "Charlie", "Delta"]
  end

  test "a run's track is picked out along its line", %{stops: stops} do
    soon = System.os_time(:second) + 300
    stub_tfl(soon)

    %{departures: [departure]} = Departures.list([stops["HUBBBB"]])

    assert {:ok, %{features: [feature], stops: points}} = Services.path(departure.service)
    assert feature.properties.name == "Bakerloo"
    assert Enum.map(points, & &1.properties.name) == ["Alpha", "Bravo", "Charlie", "Delta"]
  end

  test "a train TfL names no number for shows only its time here", %{stops: stops} do
    soon = System.os_time(:second) + 300
    stub_tfl(soon, vehicle: "")

    %{departures: [departure]} = Departures.list([stops["HUBBBB"]])
    assert departure.service.trip == "tfl:bakerloo:940GZZLUBBB:940GZZLUDDD:"

    {:ok, run} = Services.show(Map.update!(departure.service, :date, &Date.from_iso8601!/1))
    assert run.live == "none"
    assert Enum.map(run.calls, & &1.time) == [nil, soon, nil, nil]
    # Without TfL following the train, nothing is known to be behind it.
    refute Enum.any?(run.calls, & &1.passed)
  end

  test "a run that isn't TfL's is not found", %{feed: feed} do
    assert {:error, :not_found} =
             Services.show(%{
               feed: feed.id,
               trip: "tfl:bakerloo:bad id:X:1",
               date: ~D[2026-03-02]
             })

    assert {:error, :not_found} = Services.path(%{feed: feed.id, trip: "tfl:nope:A:B:1"})
  end
end
