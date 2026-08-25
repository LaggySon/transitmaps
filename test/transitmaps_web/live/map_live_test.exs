defmodule TransitmapsWeb.MapLiveTest do
  use TransitmapsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders an unobstructed map with navigation controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#transit-explorer")
    assert has_element?(view, "#transit-map[phx-hook='TransitMap']")
    assert has_element?(view, "#map-control-stack")
    assert has_element?(view, "#map-zoom-in")
    assert has_element?(view, "#map-zoom-out")
    assert has_element?(view, "#map-locate")
    assert has_element?(view, ".map-loading [role='progressbar']")

    refute has_element?(view, "#map-sidebar")
    refute has_element?(view, "#show-map-sidebar")
    refute has_element?(view, "#map-options-button")
    refute has_element?(view, "#map-options-menu")
  end

  test "uses the fixed default map layers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s{#transit-map[data-enabled='["ferry","intercity","metro","rail","tram"]']}
           )

    assert has_element?(view, ~s{#transit-map[data-details='["labels","stops"]']})

    assert has_element?(
             view,
             ~s{#transit-map[data-places='["culture","essentials","food","outdoors","shopping"]']}
           )

    assert has_element?(view, "#transit-map[data-live-traffic='false']")
  end
end
