const CATEGORY_COLORS = {
  metro: "#007AFF",
  tram: "#34C759",
  rail: "#5856D6",
  intercity: "#AF52DE",
  bus: "#FF9500",
  coach: "#A2632A",
  ferry: "#32ADE6",
}

// The server builds one line graph per category, so lines of different modes
// never share a corridor and never bundle with each other. Fixtures keep the
// modes apart the same way, by giving each its own course.
const CATEGORY_SHIFT = {ferry: -3, coach: -2, bus: -1, rail: 0, intercity: 1, tram: 2, metro: 3}

const ROUTE_COORDINATES = [
  [-0.5104, 51.4713],
  [-0.3019, 51.5154],
  [-0.1276, 51.5072],
  [0.0032, 51.5413],
  [0.129, 51.5681],
]

const lineName = (category) => `${category[0].toUpperCase()}${category.slice(1)} Line`

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
    lines: [{name: lineName(category), agency: "Visual Transit", color}],
  },
})

export const mockTransitApis = async (page) => {
  await page.route("**/api/routes.geojson?cats=*", async (route) => {
    const category = new URL(route.request().url()).searchParams.get("cats") || "rail"
    const color = CATEGORY_COLORS[category] || "#6E6E73"

    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            geometry: {type: "LineString", coordinates: shiftedRoute(category)},
            properties: {
              line: `${category}-line`,
              name: lineName(category),
              long_name: `${category[0].toUpperCase()}${category.slice(1)} visual route`,
              agency: "Visual Transit",
              category,
              color,
              text_color: "#FFFFFF",
              // One line to a corridor here, so it sits on the centreline.
              slot: 0,
              bundle: 1,
            },
          },
        ],
      }),
    })
  })

  // Names come off the corridor in both renderings, so the fixture serves the
  // same course again as the corridor the line runs along.
  await page.route("**/api/corridors.geojson?cats=*", async (route) => {
    const category = new URL(route.request().url()).searchParams.get("cats") || "rail"
    const color = CATEGORY_COLORS[category] || "#6E6E73"

    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            geometry: {type: "LineString", coordinates: shiftedRoute(category)},
            properties: {
              name: lineName(category),
              category,
              color,
              stripes: 1,
              stripe_0: color,
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
export const openLiveMap = async (page, {stripes = false} = {}) => {
  await page.goto("/")
  await page.locator("body").evaluate((body) => body.classList.add("playwright-visuals"))
  await page.locator("#transit-map[data-map-ready='true']").waitFor({timeout: 180_000})
  await page.locator("#transit-map[data-transit-ready='true']").waitFor({timeout: 300_000})

  await page.locator("#map-options-button").click()
  // Places are noise when the subject is track: switch them off so a shop
  // opening or closing never re-approves a junction drawing.
  await page.locator("#group-toggle-places").click({force: true})
  if (stripes) await page.locator("#map-detail-ribbons").click({force: true})
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
