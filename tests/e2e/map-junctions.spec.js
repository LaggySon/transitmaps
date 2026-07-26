import {expect, test} from "@playwright/test"
import {openLiveMap, setMapZoom} from "./support/map-fixtures.js"

// The places a person checks by hand after changing how track is drawn: big
// interchanges, and corridors where several lines run together. Both are where
// bundling and striping actually have to do something, and both are where the
// drawing goes wrong first.
const JUNCTIONS = [
  {name: "paddington", center: [-0.1780, 51.5150], zoom: 14.2},
  {name: "kings-cross", center: [-0.1240, 51.5308], zoom: 15.4},
  {name: "bank-monument", center: [-0.0886, 51.5125], zoom: 15.6},
  {name: "baker-street", center: [-0.1573, 51.5226], zoom: 15.4},
  {name: "earls-court", center: [-0.1935, 51.4917], zoom: 14.8},
  {name: "euston-corridor", center: [-0.1330, 51.5290], zoom: 13.8},
]

// Street level, where a bundle has the most room to go wrong. Ten metres of
// ground is about 54 px at zoom 19, so anything spaced on the ground rather
// than on the screen flies apart here.
const CLOSE_UPS = [
  {name: "baker-street-z18", center: [-0.1573, 51.5226], zoom: 18},
  {name: "kings-cross-z18", center: [-0.1235, 51.5305], zoom: 18},
  {name: "earls-court-z18", center: [-0.1935, 51.4915], zoom: 18.5},
  {name: "paddington-z19", center: [-0.1769, 51.5166], zoom: 19},
  {name: "baker-street-z19", center: [-0.1566, 51.5222], zoom: 19},
]

// Each rendering draws the same network a different way, so both are worth a
// picture at every junction.
const RENDERINGS = [
  {name: "bundled", stripes: false},
  {name: "striped", stripes: true},
]

// These load the real network rather than a handful of fixture shapes, which
// takes far longer than the default per-test budget allows.
const LOAD_BUDGET_MS = 240_000

test.beforeEach(({}, testInfo) => testInfo.setTimeout(LOAD_BUDGET_MS))

// One test per rendering rather than per junction: loading the real network
// costs far more than moving around it, so the map is opened once and then
// flown between the junctions.
for (const rendering of RENDERINGS) {
  test(`draws every close-up as approved, ${rendering.name}`, async ({page}) => {
    await openLiveMap(page, {stripes: rendering.stripes})

    for (const junction of CLOSE_UPS) {
      await setMapZoom(page, junction.zoom, junction.center)
      await page.waitForTimeout(2500)

      await expect(page.locator("#transit-map")).toHaveScreenshot(
        `${rendering.name}-${junction.name}.png`
      )
    }
  })

  test(`draws every junction as approved, ${rendering.name}`, async ({page}) => {
    await openLiveMap(page, {stripes: rendering.stripes})

    for (const junction of JUNCTIONS) {
      await setMapZoom(page, junction.zoom, junction.center)
      // Overzoomed basemap tiles and long corridors keep arriving after the
      // first idle, so settle before judging the drawing.
      await page.waitForTimeout(2500)

      await expect(page.locator("#transit-map")).toHaveScreenshot(
        `${rendering.name}-${junction.name}.png`
      )
    }
  })
}

// The eye catches these instantly and a screenshot diff does not explain them,
// so they are asserted directly against what the server serves.
test("every corridor stripe carries a usable colour", async ({page}) => {
  await openLiveMap(page)

  const problems = await page.evaluate(async () => {
    const found = []

    for (const category of ["metro", "rail", "intercity", "tram", "ferry"]) {
      const response = await fetch(`/api/corridors.geojson?cats=${category}`)
      const {features} = await response.json()

      features.forEach(({properties}) => {
        const {stripes, name} = properties

        if (!Number.isInteger(stripes) || stripes < 1) {
          found.push(`${category}: "${name}" has stripes=${stripes}`)
          return
        }

        for (let index = 0; index < stripes; index += 1) {
          const colour = properties[`stripe_${index}`]

          // A missing or malformed colour is not a subtle bug: MapLibre falls
          // back to black, and the band reads as a line that does not exist.
          if (!/^#[0-9a-f]{6}$/i.test(colour || "")) {
            found.push(`${category}: "${name}" band ${index} is ${colour}`)
          }
        }
      })
    }

    return found
  })

  expect(problems).toEqual([])
})

test("no ribbon carries more bands than the renderer can draw", async ({page}) => {
  await openLiveMap(page)

  const overflowing = await page.evaluate(async () => {
    // Mirrors MAX_STRIPES in the map hook: a band past the last stripe layer
    // is never drawn, so the operator silently disappears from its corridor.
    const drawable = 12
    const found = []

    for (const category of ["metro", "rail", "intercity", "tram", "ferry"]) {
      const response = await fetch(`/api/corridors.geojson?cats=${category}`)
      const {features} = await response.json()

      features.forEach(({properties}) => {
        if (properties.stripes > drawable) {
          found.push(`${category}: ${properties.stripes} bands on "${properties.name}"`)
        }
      })
    }

    return found
  })

  expect(overflowing).toEqual([])
})

test("corridor segments stay on the ground they describe", async ({page}) => {
  await openLiveMap(page)

  const jumps = await page.evaluate(async () => {
    const response = await fetch("/api/corridors.geojson?cats=metro")
    const {features} = await response.json()
    const found = []

    features.forEach(({geometry, properties}) => {
      geometry.coordinates.forEach((point, index) => {
        if (index === 0) return
        const [lon, lat] = point
        const [previousLon, previousLat] = geometry.coordinates[index - 1]
        // Rough kilometres around London; exact enough to spot a connector
        // jump stitched across the city, which is what these look like.
        const km = Math.hypot((lon - previousLon) * 69.2, (lat - previousLat) * 110.6)

        if (km > 3) found.push(`${properties.name}: ${km.toFixed(1)} km step`)
      })
    })

    return found
  })

  expect(jumps).toEqual([])
})
