const CATEGORY_COLORS = {
  metro: "#007AFF",
  tram: "#34C759",
  rail: "#5856D6",
  intercity: "#AF52DE",
  bus: "#FF9500",
  coach: "#A2632A",
  ferry: "#32ADE6",
}

// The map draws corridor segments, so fixtures serve those: one segment per
// category, shifted slightly north of the last so the categories are visible
// side by side the way real bundled track is.
const CATEGORY_SHIFT = {ferry: -3, coach: -2, bus: -1, rail: 0, intercity: 1, tram: 2, metro: 3}

const ROUTE_COORDINATES = [
  [-0.5104, 51.4713],
  [-0.3019, 51.5154],
  [-0.1276, 51.5072],
  [0.0032, 51.5413],
  [0.129, 51.5681],
]

const shiftedRoute = (category) => {
  const shift = (CATEGORY_SHIFT[category] || 0) * 0.0006
  return ROUTE_COORDINATES.map(([lon, lat]) => [lon, lat + shift])
}

const stopFeature = (name, coordinates, color, category) => ({
  type: "Feature",
  geometry: {type: "Point", coordinates},
  properties: {
    name,
    station: true,
    categories: [category],
    lines: [{name: `${category[0].toUpperCase()}${category.slice(1)} Line`, agency: "Visual Transit", color}],
  },
})

export const mockTransitApis = async (page) => {
  await page.route("**/api/corridors.geojson?cats=*", async (route) => {
    const category = new URL(route.request().url()).searchParams.get("cats") || "rail"
    const color = CATEGORY_COLORS[category] || "#6E6E73"
    const name = `${category[0].toUpperCase()}${category.slice(1)} Line`

    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            geometry: {type: "LineString", coordinates: shiftedRoute(category)},
            properties: {
              name,
              name_0: name,
              stripe_0: color,
              stripes: 1,
              category,
              color,
            },
          },
        ],
      }),
    })
  })

  await page.route("**/api/stops.geojson?cats=*", async (route) => {
    const category = new URL(route.request().url()).searchParams.get("cats") || "rail"
    const color = CATEGORY_COLORS[category] || "#6E6E73"

    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: [
          stopFeature("London Central", [-0.1276, 51.5072], color, category),
          stopFeature("Stratford International", [0.0032, 51.5413], color, category),
        ],
      }),
    })
  })
}

export const openStableMap = async (page) => {
  await mockTransitApis(page)
  await page.goto("/?visual_test=1")
  await page.locator("body").evaluate((body) => body.classList.add("playwright-visuals"))
  await page.locator("#transit-map[data-map-ready='true']").waitFor()
  await page.locator("#transit-map[data-transit-ready='true']").waitFor()
  await page.locator("#transit-map[data-map-idle='true']").waitFor()
}

// The junction suite judges how real track is drawn where lines meet, so it
// deliberately skips the synthetic fixtures above and renders whatever the
// database holds. That makes its screenshots move when a feed is re-imported:
// they are approved drawings of live data, not fixed expectations.
export const openLiveMap = async (page) => {
  await page.goto("/")
  await page.locator("body").evaluate((body) => body.classList.add("playwright-visuals"))
  await page.locator("#transit-map[data-map-ready='true']").waitFor({timeout: 180_000})
  await page.locator("#transit-map[data-transit-ready='true']").waitFor({timeout: 300_000})

  await page.locator("#map-options-button").click()
  // Places are noise when the subject is track: switch them off so a shop
  // opening or closing never re-approves a junction drawing.
  await page.locator("#group-toggle-places").click({force: true})
  await page.locator("#map-options-button").click()
  await page.locator("#hide-map-sidebar").click()

  // No wait for `data-map-idle` here. Collapsing the sidebar re-renders the
  // map element, and LiveView patches its attributes back to what the server
  // rendered — wiping the hook's idle flag. Nothing moves the map afterwards,
  // so no further idle event would arrive to set it again. `setMapZoom` waits
  // on the idle *event* instead, which is unaffected.
}

export const setMapZoom = async (page, zoom, center = [-0.1276, 51.5072]) => {
  await page.locator("#transit-map").evaluate(
    (map, detail) =>
      new Promise((resolve) => {
        window.addEventListener("transit-map:idle", resolve, {once: true})
        map.dispatchEvent(new CustomEvent("map:set-zoom", {detail}))
      }),
    {zoom, center}
  )
  await page.locator("#transit-map").waitFor()
}
