import {expect, test} from "@playwright/test"
import {openStableMap, setMapZoom} from "./support/map-fixtures.js"

const SUPPORTED_ZOOM_LEVELS = Array.from({length: 14}, (_, index) => index + 4)

test.describe("map visual regression at every supported zoom level", () => {
  test.describe.configure({mode: "serial"})

  for (const zoom of SUPPORTED_ZOOM_LEVELS) {
    test(`matches the approved design at zoom ${zoom}`, async ({page}) => {
      await openStableMap(page)
      await setMapZoom(page, zoom)

      await expect(page.locator("#transit-explorer")).toHaveScreenshot(`map-zoom-${zoom}.png`)
    })
  }
})

test("matches the desktop layers and settings menus", async ({page}) => {
  await openStableMap(page)
  await page.locator("#map-menu-layers").click()
  await expect(page.locator("#map-sidebar")).toHaveScreenshot("desktop-layers-menu.png")

  await page.locator("#map-options-button").click()
  await expect(page.locator("#map-options-menu")).toHaveScreenshot("desktop-settings-menu.png")
})

test("matches the responsive mobile sheet", async ({page}) => {
  await page.setViewportSize({width: 390, height: 844})
  await openStableMap(page)
  await expect(page.locator("#transit-explorer")).toHaveScreenshot("mobile-explore-sheet.png")

  await page.locator("#map-menu-layers").click()
  await expect(page.locator("#transit-explorer")).toHaveScreenshot("mobile-layers-sheet.png")
})
