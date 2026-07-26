defmodule TransitmapsWeb.MapLiveTest do
  use TransitmapsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the Apple-style map shell and primary menus", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#transit-explorer")
    assert has_element?(view, "#transit-map[phx-hook='TransitMap']")
    assert has_element?(view, "#map-sidebar")
    assert has_element?(view, "#explore-menu")
    assert has_element?(view, "#map-search-form")
    assert has_element?(view, "#map-control-stack")
    assert has_element?(view, ".map-loading [role='progressbar']")
  end

  test "switches between explore and trip menus", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-trip") |> render_click()
    assert has_element?(view, "#trip-menu")
    refute has_element?(view, "#explore-menu")

    view |> element("#map-menu-explore") |> render_click()
    assert has_element?(view, "#explore-menu")
  end

  test "gathers every layer control under map details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # The sidebar no longer carries a layers panel of its own.
    refute has_element?(view, "#map-menu-layers")
    refute has_element?(view, "#layers-menu")

    view |> element("#map-options-button") |> render_click()
    assert has_element?(view, "#map-options-menu #layer-toggle-metro")
    assert has_element?(view, "#map-options-menu #places-menu")
    assert has_element?(view, "#map-options-menu #map-live-traffic")
  end

  test "opens settings and toggles map details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-options-button") |> render_click()
    assert has_element?(view, "#map-options-menu")
    assert has_element?(view, "#map-detail-labels[aria-checked='true']")

    view |> element("#map-detail-labels") |> render_click()
    assert has_element?(view, "#map-detail-labels[aria-checked='false']")
  end

  test "toggles a place category and pushes it to the map", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-options-button") |> render_click()
    assert has_element?(view, "#place-toggle-shopping[aria-checked='true']")

    view |> element("#place-toggle-shopping") |> render_click()
    assert has_element?(view, "#place-toggle-shopping[aria-checked='false']")

    view |> element("#place-toggle-shopping") |> render_click()
    assert has_element?(view, "#place-toggle-shopping[aria-checked='true']")
  end

  test "shows and hides every place category at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-options-button") |> render_click()

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

  test "toggles the optional live train traffic layer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#transit-map[data-live-traffic='false']")

    view |> element("#map-options-button") |> render_click()
    assert has_element?(view, "#map-live-traffic[aria-checked='false']")

    view |> element("#map-live-traffic") |> render_click()
    assert has_element?(view, "#map-live-traffic[aria-checked='true']")
    assert has_element?(view, "#transit-map[data-live-traffic='true']")

    view |> element("#map-live-traffic") |> render_click()
    assert has_element?(view, "#map-live-traffic[aria-checked='false']")
  end

  test "collapses and restores the sidebar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#hide-map-sidebar") |> render_click()
    refute has_element?(view, "#map-sidebar")
    assert has_element?(view, "#show-map-sidebar")

    view |> element("#show-map-sidebar") |> render_click()
    assert has_element?(view, "#map-sidebar")
  end

  test "validates an empty station search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#map-search-form", search: %{query: ""})
    |> render_submit()

    assert has_element?(view, "#map-search-message")
  end

  test "opens the trip planner and reports unknown stations", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-trip") |> render_click()
    assert has_element?(view, "#trip-menu")
    assert has_element?(view, "#trip-form")

    view
    |> form("#trip-form", trip: %{from: "Kings Cross", to: "Paddington"})
    |> render_submit()

    assert has_element?(view, "#trip-error")
  end
end
