defmodule TransitmapsWeb.MapLiveTest do
  use TransitmapsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the map with a single closed filter menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#transit-explorer")
    assert has_element?(view, "#transit-map[phx-hook='TransitMap']")
    assert has_element?(view, "#map-menu-button[aria-expanded='false']")
    refute has_element?(view, "#map-menu")
    assert has_element?(view, "#map-control-stack")
    assert has_element?(view, ".map-loading [role='progressbar']")
  end

  test "opens and closes the filter menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-button") |> render_click()
    assert has_element?(view, "#map-menu-button[aria-expanded='true']")
    assert has_element?(view, "#map-menu #agency-menu")
    assert has_element?(view, "#map-menu #layer-toggle-metro")
    assert has_element?(view, "#map-menu #details-menu")
    assert has_element?(view, "#map-menu #places-menu")

    view |> element("#map-menu-button") |> render_click()
    refute has_element?(view, "#map-menu")

    view |> element("#map-menu-button") |> render_click()
    render_keydown(view, "close-menu", %{"key" => "Escape"})
    refute has_element?(view, "#map-menu")
  end

  describe "agencies" do
    @describetag :capture_log

    alias Transitmaps.GtfsFixture
    alias Transitmaps.Gtfs.Importer

    setup do
      GtfsFixture.write!("tmp/fixtures/tiny-gtfs.zip")
      on_exit(fn -> File.rm("tmp/fixtures/tiny-gtfs.zip") end)
    end

    test "finds an agency, downloads it, and flies there when it lands", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#map-menu-button") |> render_click()

      view |> form("#agency-search", agency: %{query: "tiny"}) |> render_change()
      assert has_element?(view, "#agency-result-mdb-9001", "Add")

      view |> element("#agency-result-mdb-9001 button") |> render_click()
      assert has_element?(view, "#agency-result-mdb-9001", "Waiting")

      # The worker is off in tests; run the queued download the way it would.
      Transitmaps.Agencies.run_import("mdb-9001")

      assert_push_event(view, "feeds-changed", %{feeds: [%{id: feed_id}]})
      assert_push_event(view, "fly-to", %{bounds: [[_, _], [_, _]]})

      view |> form("#agency-search", agency: %{query: "tiny"}) |> render_change()
      view |> element("#agency-result-mdb-9001 button", "Show") |> render_click()
      assert_push_event(view, "fly-to", %{bounds: _bounds})
      assert is_integer(feed_id)
    end

    test "lists the agencies in view, each of which can be hidden", %{conn: conn} do
      {:ok, feed} = Importer.import_feed("gb-rail", "tmp/fixtures/tiny-gtfs.zip")
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#transit-map") |> render_hook("view", %{"feeds" => [feed.id]})
      view |> element("#map-menu-button") |> render_click()

      toggle = "#agencies-in-view #agency-toggle-#{feed.id}"
      assert has_element?(view, toggle <> "[aria-checked='true']", "National Rail")
      assert has_element?(view, "#layer-toggle-rail:not([disabled])")

      view |> element(toggle) |> render_click()
      assert has_element?(view, toggle <> "[aria-checked='false']")
      assert_push_event(view, "agencies-hidden", %{hidden: [_]})

      # Hand-curated agencies aren't in the catalog but are still found.
      view |> form("#agency-search", agency: %{query: "national"}) |> render_change()
      assert has_element?(view, "#agency-result-on-map-#{feed.id}", "Show")
      view |> form("#agency-search", agency: %{query: ""}) |> render_change()

      # Nothing in view: the list says so and the modes have nothing to count.
      view |> element("#transit-map") |> render_hook("view", %{"feeds" => []})
      refute has_element?(view, toggle)
      assert has_element?(view, "#layer-toggle-rail[disabled]")
    end
  end

  test "toggles map details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-button") |> render_click()
    assert has_element?(view, "#map-detail-labels[aria-checked='true']")

    view |> element("#map-detail-labels") |> render_click()
    assert has_element?(view, "#map-detail-labels[aria-checked='false']")
  end

  test "toggles a place category and pushes it to the map", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-button") |> render_click()
    assert has_element?(view, "#place-toggle-shopping[aria-checked='true']")

    view |> element("#place-toggle-shopping") |> render_click()
    assert has_element?(view, "#place-toggle-shopping[aria-checked='false']")

    view |> element("#place-toggle-shopping") |> render_click()
    assert has_element?(view, "#place-toggle-shopping[aria-checked='true']")
  end

  test "shows and hides every place category at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-button") |> render_click()

    view |> element("#group-toggle-places") |> render_click()
    assert has_element?(view, "#place-toggle-food[aria-checked='false']")
    assert has_element?(view, "#place-toggle-essentials[aria-checked='false']")

    view |> element("#group-toggle-places") |> render_click()
    assert has_element?(view, "#place-toggle-food[aria-checked='true']")
    assert has_element?(view, "#place-toggle-essentials[aria-checked='true']")
  end

  test "starts with every place category shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s{#transit-map[data-places='["culture","essentials","food","outdoors","shopping"]']}
           )
  end
end
