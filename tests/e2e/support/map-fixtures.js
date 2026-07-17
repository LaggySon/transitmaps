const CATEGORY_COLORS = {
  metro: "#007AFF",
  tram: "#34C759",
  rail: "#5856D6",
  intercity: "#AF52DE",
  bus: "#FF9500",
  coach: "#A2632A",
  ferry: "#32ADE6",
}

const CATEGORY_OFFSETS = {ferry: -3, coach: -2, bus: -1, rail: 0, intercity: 1, tram: 2, metro: 3}

const ROUTE_COORDINATES = [
  [-0.5104, 51.4713],
  [-0.3019, 51.5154],
  [-0.1276, 51.5072],
  [0.0032, 51.5413],
  [0.129, 51.5681],
]

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
            geometry: {type: "MultiLineString", coordinates: [ROUTE_COORDINATES]},
            properties: {
              name: `${category[0].toUpperCase()}${category.slice(1)} Line`,
              long_name: `${category[0].toUpperCase()}${category.slice(1)} visual route`,
              agency: "Visual Transit",
              category,
              color,
              text_color: "#FFFFFF",
              offset: CATEGORY_OFFSETS[category] || 0,
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
