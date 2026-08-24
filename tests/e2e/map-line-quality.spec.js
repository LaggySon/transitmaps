import {expect, test} from "@playwright/test"
import {CROWDED_NETWORKS, mockCrowdedTransitApis} from "./support/crowded-networks.js"
import {openStableMap, setMapZoom} from "./support/map-fixtures.js"

test.describe("continuous lines at crowded London stations", () => {
  test.describe.configure({mode: "serial"})

  for (const [name, scene] of Object.entries(CROWDED_NETWORKS)) {
    test(`${name} has clean curves and closed joins`, async ({page}) => {
      await openStableMap(page, {
        mockApis: (currentPage) => mockCrowdedTransitApis(currentPage, scene),
      })
      await setMapZoom(page, scene.zoom, scene.center)
      await page.locator("#hide-map-sidebar").click()
      await expect(page.locator("#transit-explorer")).toHaveScreenshot(`lines-${name}.png`)
    })
  }
})
