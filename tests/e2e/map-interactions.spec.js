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
