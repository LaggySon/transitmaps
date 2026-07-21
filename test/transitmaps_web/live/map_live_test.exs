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

  test "switches between explore and layer menus", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-layers") |> render_click()
    assert has_element?(view, "#layers-menu")
    refute has_element?(view, "#explore-menu")

    view |> element("#map-menu-explore") |> render_click()
    assert has_element?(view, "#explore-menu")
  end

  test "opens settings and toggles map details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-options-button") |> render_click()
    assert has_element?(view, "#map-options-menu")
    assert has_element?(view, "#map-detail-labels[aria-checked='true']")

    view |> element("#map-detail-labels") |> render_click()
    assert has_element?(view, "#map-detail-labels[aria-checked='false']")
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
end
