import {expect, test} from "@playwright/test"
import {openLiveMap, setMapZoom} from "./support/map-fixtures.js"

// The places a person checks by hand after changing how track is drawn: big
// interchanges, and corridors where several lines run together. Both are where
// any rule about drawing track has to earn its keep, and both are where the
// drawing goes wrong first.
const JUNCTIONS = [
  {name: "paddington", center: [-0.1780, 51.5150], zoom: 14.2},
  {name: "kings-cross", center: [-0.1240, 51.5308], zoom: 15.4},
  {name: "bank-monument", center: [-0.0886, 51.5125], zoom: 15.6},
  {name: "baker-street", center: [-0.1573, 51.5226], zoom: 15.4},
  {name: "earls-court", center: [-0.1935, 51.4917], zoom: 14.8},
  {name: "euston-corridor", center: [-0.1330, 51.5290], zoom: 13.8},
]

// Street level, where lines drawn on shared track have the most room to go
// wrong. Ten metres of ground is about 54 px at zoom 19, so anything spaced on
// the ground rather than on the screen flies apart here.
const CLOSE_UPS = [
  {name: "baker-street-z18", center: [-0.1573, 51.5226], zoom: 18},
  {name: "kings-cross-z18", center: [-0.1235, 51.5305], zoom: 18},
  {name: "earls-court-z18", center: [-0.1935, 51.4915], zoom: 18.5},
  {name: "paddington-z19", center: [-0.1769, 51.5166], zoom: 19},
  {name: "baker-street-z19", center: [-0.1566, 51.5222], zoom: 19},
]

// These load the real network rather than a handful of fixture shapes, which
// takes far longer than the default per-test budget allows.
const LOAD_BUDGET_MS = 240_000

test.beforeEach(({}, testInfo) => testInfo.setTimeout(LOAD_BUDGET_MS))

// One test per group of junctions rather than one each: loading the real
// network costs far more than moving around it, so the map is opened once and
// then flown between them.
test("draws every close-up as approved", async ({page}) => {
  await openLiveMap(page)

  for (const junction of CLOSE_UPS) {
    await setMapZoom(page, junction.zoom, junction.center)
    await page.waitForTimeout(2500)

    await expect(page.locator("#transit-map")).toHaveScreenshot(`${junction.name}.png`)
  }
})

test("draws every junction as approved", async ({page}) => {
  await openLiveMap(page)

  for (const junction of JUNCTIONS) {
    await setMapZoom(page, junction.zoom, junction.center)
    // Overzoomed basemap tiles and long corridors keep arriving after the
    // first idle, so settle before judging the drawing.
    await page.waitForTimeout(2500)

    await expect(page.locator("#transit-map")).toHaveScreenshot(`${junction.name}.png`)
  }
})

// The eye catches this instantly and a screenshot diff does not explain it, so
// it is asserted directly against what the server serves.
test("every drawn line carries a usable colour", async ({page}) => {
  await openLiveMap(page)

  const problems = await page.evaluate(async () => {
    const found = []

    for (const category of ["metro", "rail", "intercity", "tram", "ferry"]) {
      const response = await fetch(`/api/routes.geojson?cats=${category}`)
      const {features} = await response.json()

      features.forEach(({properties: {color, name}}) => {
        // A missing or malformed colour is not a subtle bug: MapLibre falls
        // back to black, and the line reads as one that does not exist.
        if (!/^#[0-9a-f]{6}$/i.test(color || "")) {
          found.push(`${category}: "${name}" is ${color}`)
        }
      })
    }

    return found
  })

  expect(problems).toEqual([])
})
