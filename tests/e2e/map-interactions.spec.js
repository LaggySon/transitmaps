import {expect, test} from "@playwright/test"
import {mockTransitApis, openStableMap, setMapZoom} from "./support/map-fixtures.js"

test.beforeEach(async ({page}) => {
  await openStableMap(page)
})

test("opens and closes the filter menu", async ({page}) => {
  const button = page.locator("#map-menu-button")
  await expect(button).toHaveAttribute("aria-expanded", "false")

  await button.click()
  await expect(page.locator("#map-menu")).toBeVisible()
  await expect(button).toHaveAttribute("aria-expanded", "true")

  await page.keyboard.press("Escape")
  await expect(page.locator("#map-menu")).toHaveCount(0)

  // Clicking the map itself also dismisses it.
  await button.click()
  await page.locator("#transit-map canvas").click({position: {x: 700, y: 500}})
  await expect(page.locator("#map-menu")).toHaveCount(0)
})

test("toggles map details and transit layers", async ({page}) => {
  await page.locator("#map-menu-button").click()
  const labels = page.locator("#map-detail-labels")
  await expect(labels).toHaveAttribute("aria-checked", "true")
  await labels.click()
  await expect(labels).toHaveAttribute("aria-checked", "false")

  const metro = page.locator("#layer-toggle-metro")
  await expect(metro).toHaveAttribute("aria-checked", "true")
  await metro.click({force: true})
  await expect(metro).toHaveAttribute("aria-checked", "false")
})

test("toggles place categories without disturbing the map", async ({page}) => {
  await page.locator("#map-menu-button").click()

  const shopping = page.locator("#place-toggle-shopping")
  await expect(shopping).toHaveAttribute("aria-checked", "true")
  await shopping.click({force: true})
  await expect(shopping).toHaveAttribute("aria-checked", "false")

  // With one category off the group button offers "Show all", so it restores
  // the whole set. Forced, because relabelling the button changes its width
  // and that counts as the target moving under the cursor.
  await page.locator("#group-toggle-places").click({force: true})
  await expect(shopping).toHaveAttribute("aria-checked", "true")
  await expect(page.locator("#place-toggle-essentials")).toHaveAttribute("aria-checked", "true")

  // Now that everything is on it offers "Hide all" instead.
  await page.locator("#group-toggle-places").click({force: true})
  await expect(page.locator("#place-toggle-food")).toHaveAttribute("aria-checked", "false")

  // Switching places about must still let the map settle rather than leaving
  // it spinning on an unrenderable layer.
  await expect(page.locator("#transit-map[data-map-idle='true']")).toBeVisible()
})

test("custom zoom buttons update the live map zoom", async ({page}) => {
  const map = page.locator("#transit-map")
  const initialZoom = Number(await map.getAttribute("data-map-zoom"))
  await page.locator("#map-zoom-in").click()
  await expect.poll(async () => Number(await map.getAttribute("data-map-zoom"))).toBeGreaterThan(initialZoom)
  await page.locator("#map-zoom-out").click()
  await expect.poll(async () => Number(await map.getAttribute("data-map-zoom"))).toBeLessThan(initialZoom + 1)
})

// Transit data that lands before the basemap's tiles must still be drawn,
// without waiting for the visitor to move the map.
test("draws lines that arrive before the basemap tiles", async ({page}) => {
  await page.route(/\/tiles\/(?!styles)/, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 2500))
    await route.continue()
  })
  await mockTransitApis(page)
  await page.goto("/?visual_test=1")

  await expect(page.locator("#transit-map")).toHaveAttribute("data-transit-ready", "true", {timeout: 60_000})
  await expect.poll(async () => Number(await page.locator("#transit-map").getAttribute("data-drawn-lines"))).toBeGreaterThan(0)
})

// A station's popup opens on its departures, which refresh while it stays
// open, and keeps its lines a tab away.
test("shows a station's departures and lines", async ({page}) => {
  await setMapZoom(page, 14, [-0.1276, 51.5072])
  const canvas = page.locator("#transit-map canvas")
  const box = await canvas.boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)

  const departures = page.locator("#station-panel-departures")
  await expect(page.locator("#station-tab-departures")).toHaveAttribute("aria-selected", "true")
  await expect(departures.locator(".tm-departure")).toHaveCount(3)
  await expect(departures.locator(".tm-departure").nth(1)).toContainText("+5 min")
  await expect(departures.locator(".tm-departure[data-cancelled]")).toContainText("Cancelled")

  await page.locator("#station-tab-lines").click()
  await expect(page.locator("#station-panel-lines")).toBeVisible()
  await expect(departures).toBeHidden()

  await page.keyboard.press("Escape")
  await expect(page.locator("#station-panel-departures")).toHaveCount(0)
})

// A departure opens to its whole run, and the map picks out the track it
// runs until the board comes back.
test("picks out a departure's run on the map", async ({page}) => {
  await setMapZoom(page, 14, [-0.1276, 51.5072])
  const canvas = page.locator("#transit-map canvas")
  const box = await canvas.boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)

  const map = page.locator("#transit-map")
  await page.locator("#station-panel-departures [data-service]").first().click()
  await expect(page.locator(".tm-service-destination")).toContainText("Stratford International")
  await expect(map).toHaveAttribute("data-focus", "service")
  // Its stations are marked along it.
  await expect(map).toHaveAttribute("data-focus-stops", "2")

  await page.locator("[data-service-back]").click()
  await expect(map).toHaveAttribute("data-focus", "")
  await expect(map).toHaveAttribute("data-focus-stops", "0")
})

// A popup in the way can be dragged aside by its header, and stays there
// while the map moves under it.
test("drags a station's popup out of the way", async ({page}) => {
  await setMapZoom(page, 14, [-0.1276, 51.5072])
  const box = await page.locator("#transit-map canvas").boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)

  const popup = page.locator(".maplibregl-popup")
  const header = popup.locator(".tm-popup-header")
  await expect(header).toBeVisible()
  // Measured once the departures are in, so the popup is done growing.
  await expect(popup.locator(".tm-departure")).toHaveCount(3)
  const before = await popup.boundingBox()
  const grip = await header.boundingBox()

  await page.mouse.move(grip.x + 20, grip.y + 10)
  await page.mouse.down()
  await page.mouse.move(grip.x - 180, grip.y + 160, {steps: 6})
  await page.mouse.up()

  const map = page.locator("#transit-map")
  await expect(map).toHaveAttribute("data-popup-moved", "true")
  const moved = await popup.boundingBox()
  expect(moved.x).toBeLessThan(before.x - 150)
  expect(moved.y).toBeGreaterThan(before.y + 130)

  // The map moves; the popup doesn't.
  await setMapZoom(page, 13, [-0.1, 51.52])
  const after = await popup.boundingBox()
  expect(Math.abs(after.x - moved.x)).toBeLessThan(2)
  expect(Math.abs(after.y - moved.y)).toBeLessThan(2)

  await page.keyboard.press("Escape")
  await expect(popup).toHaveCount(0)
  await expect(map).not.toHaveAttribute("data-popup-moved", "true")
})

// A station's Photos tab shows pictures taken nearby, from Wikimedia
// Commons, once it is opened; a "too busy" answer is retried.
test("shows photos taken near a station", async ({page}) => {
  let requests = 0
  await page.route("https://commons.wikimedia.org/w/api.php?*", async (route) => {
    requests += 1
    const body =
      requests === 1
        ? {error: {code: "cirrussearch-too-busy-error", info: "Search is currently too busy."}}
        : {
            query: {
              pages: [
                {
                  pageid: 2,
                  title: "File:Far away.jpg",
                  coordinates: [{dist: 90}],
                  imageinfo: [{thumburl: "/images/logo.svg", descriptionurl: "https://commons.wikimedia.org/wiki/File:Far_away.jpg", mime: "image/jpeg"}],
                },
                {
                  pageid: 1,
                  title: "File:Station entrance.jpg",
                  coordinates: [{dist: 12}],
                  imageinfo: [{thumburl: "/images/logo.svg", descriptionurl: "https://commons.wikimedia.org/wiki/File:Station_entrance.jpg", mime: "image/jpeg"}],
                },
                {
                  pageid: 3,
                  title: "File:Line diagram.svg",
                  coordinates: [{dist: 5}],
                  imageinfo: [{thumburl: "/images/logo.svg", descriptionurl: "https://commons.wikimedia.org/wiki/File:Line_diagram.svg", mime: "image/svg+xml"}],
                },
              ],
            },
          }
    await route.fulfill({json: body, headers: {"access-control-allow-origin": "*"}})
  })

  await setMapZoom(page, 14, [-0.1276, 51.5072])
  const box = await page.locator("#transit-map canvas").boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  await expect(page.locator("#station-tab-photos")).toBeVisible()
  // Nothing is fetched until the tab is opened.
  expect(requests).toBe(0)

  await page.locator("#station-tab-photos").click()
  const photos = page.locator("#station-panel-photos .tm-photo")
  // Nearest first, and the diagram left out.
  await expect(photos).toHaveCount(2)
  await expect(photos.first()).toHaveAttribute("title", "Station entrance")
  expect(requests).toBe(2)

  await expect(page.locator("#photos-street-view")).toHaveAttribute("href", /map_action=pano/)
  await expect(page.locator("#photos-image-search")).toHaveAttribute("href", /tbm=isch&q=/)
})
