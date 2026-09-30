import {expect, test} from "@playwright/test"
import {openStableMap} from "./support/map-fixtures.js"

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
