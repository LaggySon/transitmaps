import {expect, test} from "@playwright/test"
import {openStableMap} from "./support/map-fixtures.js"

test.beforeEach(async ({page}) => {
  await openStableMap(page)
})

test("renders the map without side menus or filters", async ({page}) => {
  await expect(page.locator("#transit-map")).toBeVisible()
  await expect(page.locator("#map-sidebar")).toHaveCount(0)
  await expect(page.locator("#show-map-sidebar")).toHaveCount(0)
  await expect(page.locator("#map-options-button")).toHaveCount(0)
  await expect(page.locator("#map-options-menu")).toHaveCount(0)
})

test("keeps the mobile map unobstructed", async ({page}) => {
  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await page.locator("#transit-map[data-map-ready='true']").waitFor()

  await expect(page.locator("#transit-map")).toBeVisible()
  await expect(page.locator("#map-sidebar")).toHaveCount(0)
  await expect(page.locator("#map-options-menu")).toHaveCount(0)
})

test("custom zoom buttons update the live map zoom", async ({page}) => {
  const map = page.locator("#transit-map")
  const initialZoom = Number(await map.getAttribute("data-map-zoom"))
  await page.locator("#map-zoom-in").click()
  await expect.poll(async () => Number(await map.getAttribute("data-map-zoom"))).toBeGreaterThan(initialZoom)
  await page.locator("#map-zoom-out").click()
  await expect.poll(async () => Number(await map.getAttribute("data-map-zoom"))).toBeLessThan(initialZoom + 1)
})
