// Points of interest — shops, restaurants, museums, parks — drawn straight
// from the basemap's OpenMapTiles `poi` vector layer. That layer already
// travels with every tile the proxy caches, so places cost no extra request
// and need no import: the work here is deciding which of its ~80 raw classes
// are worth showing, and drawing a pin for each group.
//
// Labels and colours for the groups live server-side in `MapLive` (the sidebar
// renders them too); this module owns what a group means on the map — which
// OSM classes belong to it, and what its pin looks like.

// Raw `poi` classes, grouped into the categories the sidebar offers. Anything
// unlisted stays hidden, which is most of the layer: bollards, gates, waste
// baskets, bicycle parking and telephones outnumber real destinations roughly
// two to one and would bury the transit lines in clutter. Transit classes
// (`railway`, `bus`, `ferry_terminal`) are excluded too — the app draws its
// own stops from GTFS and would otherwise double up on them.
export const PLACE_CLASSES = {
  food: ["restaurant", "fast_food", "cafe", "bar", "beer", "ice_cream", "bakery"],
  shopping: [
    "shop",
    "grocery",
    "clothing_store",
    "alcohol_shop",
    "butcher",
    "florist",
    "music",
    "bicycle",
    "hairdresser",
    "laundry",
  ],
  culture: [
    "art_gallery",
    "museum",
    "theatre",
    "cinema",
    "attraction",
    "castle",
    "monument",
    "zoo",
    "aquarium",
    "library",
  ],
  outdoors: ["park", "playground", "dog_park", "picnic_site", "pitch", "sports_centre", "stadium", "golf"],
  essentials: [
    "hospital",
    "pharmacy",
    "doctors",
    "dentist",
    "bank",
    "atm",
    "post",
    "police",
    "fire_station",
    "fuel",
    "parking",
    "toilets",
    "lodging",
    "place_of_worship",
    "town_hall",
    "school",
    "college",
    "information",
  ],
}

// Pins are drawn on a 24×24 grid and scaled to the device pixel ratio, so a
// glyph only has to stay inside the disc: roughly (6,6) to (18,18).
const GRID = 24
const PIN_PX = 22
const DISC_RADIUS = 9.4
const RING_RADIUS = 10.6

const roundedBar = (ctx, x, y, width, height, radius) => {
  ctx.beginPath()
  ctx.moveTo(x + radius, y)
  ctx.arcTo(x + width, y, x + width, y + height, radius)
  ctx.arcTo(x + width, y + height, x, y + height, radius)
  ctx.arcTo(x, y + height, x, y, radius)
  ctx.arcTo(x, y, x + width, y, radius)
  ctx.closePath()
  ctx.fill()
}

const triangle = (ctx, apexY, baseY, halfWidth) => {
  ctx.beginPath()
  ctx.moveTo(12, apexY)
  ctx.lineTo(12 + halfWidth, baseY)
  ctx.lineTo(12 - halfWidth, baseY)
  ctx.closePath()
  ctx.fill()
}

// White glyphs, one per group, each unmistakable at 22 px.
const PLACE_GLYPHS = {
  // Fork and knife.
  food: (ctx) => {
    ;[7.2, 8.85, 10.5].forEach((x) => ctx.fillRect(x, 6.3, 0.95, 3.4))
    ctx.fillRect(7.2, 8.9, 4.25, 1.0)
    roundedBar(ctx, 8.35, 8.9, 1.15, 8.8, 0.5)

    ctx.beginPath()
    ctx.moveTo(15.05, 6.3)
    ctx.quadraticCurveTo(17.1, 8.6, 16.2, 12.1)
    ctx.lineTo(15.05, 12.1)
    ctx.closePath()
    ctx.fill()
    roundedBar(ctx, 15.05, 11.6, 1.15, 6.1, 0.5)
  },

  // Shopping bag.
  shopping: (ctx) => {
    ctx.strokeStyle = ctx.fillStyle
    ctx.lineWidth = 1.15
    ctx.beginPath()
    ctx.arc(12, 10.1, 2.75, Math.PI, 2 * Math.PI)
    ctx.stroke()
    roundedBar(ctx, 7.0, 9.7, 10.0, 8.0, 1.5)
  },

  // Five-pointed star.
  culture: (ctx) => {
    ctx.beginPath()
    for (let point = 0; point < 10; point++) {
      const radius = point % 2 === 0 ? 6.0 : 2.65
      const angle = (Math.PI / 5) * point - Math.PI / 2
      const x = 12 + radius * Math.cos(angle)
      const y = 12 + radius * Math.sin(angle)
      point === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
    }
    ctx.closePath()
    ctx.fill()
  },

  // Tree.
  outdoors: (ctx) => {
    roundedBar(ctx, 11.25, 12.6, 1.5, 5.1, 0.45)
    triangle(ctx, 5.8, 10.9, 3.9)
    triangle(ctx, 8.6, 14.3, 5.2)
  },

  // Plus sign.
  essentials: (ctx) => {
    roundedBar(ctx, 10.85, 6.4, 2.3, 11.2, 0.9)
    roundedBar(ctx, 6.4, 10.85, 11.2, 2.3, 0.9)
  },
}

export const placePinId = (group) => `place-pin-${group}`

// MapLibre's sprite ships no SDF icons, so sprite glyphs cannot be tinted to a
// category colour. Painting each pin onto a canvas gives full control instead:
// a coloured disc, a white ring so pins stay legible over parks and water, and
// the group's glyph.
export const renderPlacePin = (color, group, pixelRatio) => {
  const size = Math.round(PIN_PX * pixelRatio)
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size

  const ctx = canvas.getContext("2d")
  const scale = size / GRID
  ctx.scale(scale, scale)

  ctx.fillStyle = "rgba(255,255,255,0.95)"
  ctx.beginPath()
  ctx.arc(12, 12, RING_RADIUS, 0, 2 * Math.PI)
  ctx.fill()

  ctx.fillStyle = color
  ctx.beginPath()
  ctx.arc(12, 12, DISC_RADIUS, 0, 2 * Math.PI)
  ctx.fill()

  ctx.fillStyle = "#ffffff"
  ctx.lineCap = "round"
  PLACE_GLYPHS[group]?.(ctx)

  return {width: size, height: size, data: ctx.getImageData(0, 0, size, size).data}
}

// `poi` features only carry shops and venues from zoom 14 — below that the
// layer holds nothing but stations and ferry terminals, which the app already
// draws itself.
export const PLACES_MIN_ZOOM = 14

export const PLACES_LAYER_ID = "places"

const allGroups = () => Object.keys(PLACE_CLASSES)

// One `match` sending every class to its group's pin. Because all the groups
// share a single layer, the class is what decides which pin a feature gets.
const placeIconImage = () => [
  "match",
  ["get", "class"],
  ...allGroups().flatMap((group) => [PLACE_CLASSES[group], placePinId(group)]),
  placePinId("essentials"),
]

// Every group lives in one layer rather than one layer each. MapLibre resolves
// collisions between symbol layers by layer order, so separate layers would let
// whichever group sits highest claim every free spot and turn a dense high
// street into a single colour. Sharing a layer puts all the pins into one
// contest that `symbol-sort-key` settles on prominence, so what survives is a
// mix — the notable restaurant and the notable museum, not ten sandwich shops.
export const placeFilter = (groups) => {
  const classes = groups.flatMap((group) => PLACE_CLASSES[group] || [])

  return ["all", ["has", "name"], ["match", ["get", "class"], classes, true, false]]
}

export const placeLayer = () => ({
  id: PLACES_LAYER_ID,
  type: "symbol",
  source: "openmaptiles",
  "source-layer": "poi",
  minzoom: PLACES_MIN_ZOOM,
  filter: placeFilter(allGroups()),
  layout: {
    "icon-image": placeIconImage(),
    "icon-size": ["interpolate", ["linear"], ["zoom"], 14, 0.56, 16, 0.78, 17, 0.92, 19, 1],
    // From zoom 16 every pin is drawn, overlapping or not: by then you are
    // reading a single neighbourhood and a place quietly missing from the map
    // is worse than two pins touching. Below 16 collision still thins the
    // field, since a whole city's worth of overlapping pins is unreadable.
    "icon-allow-overlap": ["step", ["zoom"], false, 16, true],
    // And under 16, barely any breathing room is demanded, so a place is
    // dropped only when it would genuinely overlap its neighbour rather than
    // merely crowd it.
    "icon-padding": ["interpolate", ["linear"], ["zoom"], 14, 2, 16, 1],
    // OSM ranks the most prominent place in a tile lowest, and symbols with the
    // lower sort key are placed first — so on the rare occasion two pins truly
    // cannot both fit, the landmark is the one that stays. Unranked features
    // sort last rather than becoming a null sort key, which is not a number.
    "symbol-sort-key": ["coalesce", ["get", "rank"], 999],
    "text-field": ["get", "name"],
    "text-font": ["Noto Sans Regular"],
    "text-size": ["interpolate", ["linear"], ["zoom"], 14, 9.5, 17, 11.5, 19, 12.5],
    "text-anchor": "top",
    "text-offset": [0, 0.72],
    "text-max-width": 9,
    "text-padding": ["interpolate", ["linear"], ["zoom"], 14, 2, 19, 1],
    "text-optional": true,
  },
  paint: {
    "text-color": "#55555a",
    "text-halo-color": "rgba(255,255,255,0.96)",
    "text-halo-width": 1.6,
    "text-halo-blur": 0.35,
  },
})

// How far place pins stand back while the network is the subject. A junction
// like Willesden carries sixty-odd pins in saturated orange and purple, each
// competing for exactly the attention the lines want, and the eye has no way
// to tell which layer it is meant to be reading. Held back they are still
// there to find, still clickable, and no longer the loudest thing on a map
// that is about trains.
export const PLACES_RECEDED = 0.45

export const setPlacesProminence = (map, receded) => {
  if (!map.getLayer(PLACES_LAYER_ID)) return
  const opacity = receded ? PLACES_RECEDED : 1

  map.setPaintProperty(PLACES_LAYER_ID, "icon-opacity", opacity)
  map.setPaintProperty(PLACES_LAYER_ID, "text-opacity", opacity)
}

export const groupForClass = (className) =>
  allGroups().find((group) => PLACE_CLASSES[group].includes(className))

// `fast_food` reads better as "Fast food" than as a raw OSM tag.
export const placeSubtitle = (properties) => {
  const raw = properties.subclass || properties.class || ""
  const words = String(raw).replaceAll("_", " ").trim()
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : ""
}
