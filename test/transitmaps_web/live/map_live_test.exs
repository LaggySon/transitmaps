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
    assert has_element?(view, "#map-menu #region-menu")
    assert has_element?(view, "#map-menu #layer-toggle-metro")
    assert has_element?(view, "#map-menu #details-menu")
    assert has_element?(view, "#map-menu #places-menu")

    view |> element("#map-menu-button") |> render_click()
    refute has_element?(view, "#map-menu")

    view |> element("#map-menu-button") |> render_click()
    render_keydown(view, "close-menu", %{"key" => "Escape"})
    refute has_element?(view, "#map-menu")
  end

  test "switches region from the menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#map-menu-button") |> render_click()
    assert has_element?(view, "#region-great-britain[aria-checked='true']")

    view |> element("#region-northeast-corridor") |> render_click()
    assert has_element?(view, "#region-northeast-corridor[aria-checked='true']")
    assert has_element?(view, "#region-great-britain[aria-checked='false']")
    assert_push_event(view, "map-region", %{region: "northeast-corridor"})
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
