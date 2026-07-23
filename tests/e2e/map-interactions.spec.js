import {expect, test} from "@playwright/test"
import {openStableMap} from "./support/map-fixtures.js"

test.beforeEach(async ({page}) => {
  await openStableMap(page)
})

test("opens every menu and preserves accessible state", async ({page}) => {
  await page.locator("#map-menu-layers").click()
  await expect(page.locator("#layers-menu")).toBeVisible()
  await expect(page.locator("#map-menu-layers")).toHaveAttribute("aria-current", "page")

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

  await page.locator("#map-menu-layers").click()
  const metro = page.locator("#layer-toggle-metro")
  await expect(metro).toHaveAttribute("aria-checked", "true")
  await metro.click({force: true})
  await expect(metro).toHaveAttribute("aria-checked", "false")
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
