const CATEGORY_COLORS = {
  metro: "#007AFF",
  tram: "#34C759",
  rail: "#5856D6",
  intercity: "#AF52DE",
  bus: "#FF9500",
  coach: "#A2632A",
  ferry: "#32ADE6",
}

const ROUTE_COORDINATES = [
  [-0.5104, 51.4713],
  [-0.3019, 51.5154],
  [-0.1276, 51.5072],
  [0.0032, 51.5413],
  [0.129, 51.5681],
]

const stopFeature = (name, coordinates, color, category, ids) => ({
  type: "Feature",
  geometry: {type: "Point", coordinates},
  properties: {
    name,
    station: true,
    categories: [category],
    lines: [{name: `${category[0].toUpperCase()}${category.slice(1)} Line`, agency: "Visual Transit", color}],
    ...(ids ? {ids} : {}),
  },
})

// London Central's departures: one on time, one late, one cancelled.
const departuresFixture = () => {
  const now = Math.floor(Date.now() / 1000)
  const line = {name: "Rail Line", agency: "Visual Transit", category: "rail", color: CATEGORY_COLORS.rail}
  return {
    timezone: "Europe/London",
    live: "live",
    updated_at: now - 5,
    timetable: "ok",
    more: true,
    departures: [
      {
        time: now + 240,
        scheduled: now + 240,
        delay: 0,
        status: "on_time",
        destination: "Stratford International",
        platform: "2",
        line,
        service: {feed: 1, trip: "T1", date: "2026-03-02", seq: 1, at: now + 240},
      },
      {time: now + 900, scheduled: now + 600, delay: 300, status: "late", destination: "Heathrow", platform: "4", line},
      {time: now + 1200, scheduled: now + 1200, delay: null, status: "cancelled", destination: "Reading", platform: null, line},
    ],
  }
}

export const mockTransitApis = async (page) => {
  await page.route("**/api/routes.geojson?*", async (route) => {
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
            },
          },
        ],
      }),
    })
  })

  await page.route("**/api/stops.geojson?*", async (route) => {
    const category = new URL(route.request().url()).searchParams.get("cats") || "rail"
    const color = CATEGORY_COLORS[category] || "#6E6E73"

    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: [
          stopFeature("London Central", [-0.1276, 51.5072], color, category, [101]),
          stopFeature("Stratford International", [0.0032, 51.5413], color, category),
        ],
      }),
    })
  })

  await page.route("**/api/departures?*", async (route) => {
    await route.fulfill({contentType: "application/json", body: JSON.stringify(departuresFixture())})
  })

  // The first departure's run: London Central to Stratford International.
  await page.route("**/api/service?*", async (route) => {
    const now = Math.floor(Date.now() / 1000)
    const call = (name, [lng, lat], time) => ({
      name, station: null, lng, lat, platform: null, arrival: time, departure: time,
      scheduled: time, time, delay: null, status: "scheduled", pickup: true, drop_off: true,
    })
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        line: departuresFixture().departures[0].line,
        destination: "Stratford International",
        date: "2026-03-02",
        timezone: "Europe/London",
        live: "none",
        updated_at: null,
        cancelled: false,
        calls: [
          call("London Central", ROUTE_COORDINATES[2], now + 240),
          call("Stratford International", ROUTE_COORDINATES[3], now + 840),
        ],
      }),
    })
  })

  await page.route("**/api/service/path?*", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            geometry: {type: "MultiLineString", coordinates: [ROUTE_COORDINATES.slice(2, 4)]},
            properties: departuresFixture().departures[0].line,
          },
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

  await page.locator("#map-menu-button").click()
  // Places are noise when the subject is track: switch them off so a shop
  // opening or closing never re-approves a junction drawing.
  await page.locator("#group-toggle-places").click({force: true})
  await page.locator("#map-menu-button").click()
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
