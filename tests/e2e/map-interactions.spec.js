import {expect, test} from "@playwright/test"
import {openStableMap} from "./support/map-fixtures.js"

test.beforeEach(async ({page}) => {
  await openStableMap(page)
})

test("hides the loading overlay when every visible layer is ready", async ({page}) => {
  await expect(page.locator(".map-loading")).toBeHidden()
  await expect(page.locator("#transit-map")).toHaveAttribute("data-transit-ready", "true")
})

test("opens every menu and preserves accessible state", async ({page}) => {
  await page.locator("#map-menu-trip").click()
  await expect(page.locator("#trip-menu")).toBeVisible()
  await expect(page.locator("#map-menu-trip")).toHaveAttribute("aria-current", "page")

  await page.locator("#map-options-button").click()
  await expect(page.locator("#map-options-menu")).toBeVisible()
  await expect(page.locator("#map-options-button")).toHaveAttribute("aria-expanded", "true")

  await page.locator("#hide-map-sidebar").click()
  await expect(page.locator("#map-sidebar")).toHaveCount(0)
  await page.locator("#show-map-sidebar").click()
  await expect(page.locator("#map-sidebar")).toBeVisible()
})

test("toggles map details and transit layers", async ({page}) => {
  await page.locator("#map-options-button").click()
  const labels = page.locator("#map-detail-labels")
  await expect(labels).toHaveAttribute("aria-checked", "true")
  await labels.click()
  await expect(labels).toHaveAttribute("aria-checked", "false")

  // Transit layers now live in the same popover as the details toggles.
  const metro = page.locator("#layer-toggle-metro")
  await expect(metro).toHaveAttribute("aria-checked", "true")
  await metro.click({force: true})
  await expect(metro).toHaveAttribute("aria-checked", "false")
})

test("toggles place categories without disturbing the map", async ({page}) => {
  await page.locator("#map-options-button").click()

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

test("toggles the optional live train traffic layer", async ({page}) => {
  const map = page.locator("#transit-map")
  await expect(map).toHaveAttribute("data-live-traffic", "false")

  await page.locator("#map-options-button").click()
  const liveTrains = page.locator("#map-live-traffic")
  await expect(liveTrains).toHaveAttribute("aria-checked", "false")

  await liveTrains.click()
  await expect(liveTrains).toHaveAttribute("aria-checked", "true")
  await expect(map).toHaveAttribute("data-live-traffic", "true")

  await liveTrains.click()
  await expect(liveTrains).toHaveAttribute("aria-checked", "false")
  await expect(map).toHaveAttribute("data-live-traffic", "false")
})

test("searches visible station data and opens a result", async ({page}) => {
  await page.locator("#map-search-form input[type='search']").fill("London Central")
  await page.locator("#map-search-form input[type='search']").press("Enter")

  await expect(page.locator("#map-search-message")).toContainText("Showing London Central")
  await expect(page.locator(".station-popup__title")).toHaveText("London Central")
})

test("custom zoom buttons update the live map zoom", async ({page}) => {
  const map = page.locator("#transit-map")
  const initialZoom = Number(await map.getAttribute("data-map-zoom"))
  await page.locator("#map-zoom-in").click()
  await expect.poll(async () => Number(await map.getAttribute("data-map-zoom"))).toBeGreaterThan(initialZoom)
  await page.locator("#map-zoom-out").click()
  await expect.poll(async () => Number(await map.getAttribute("data-map-zoom"))).toBeLessThan(initialZoom + 1)
})
