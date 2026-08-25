// A transit line is drawn as one uninterrupted geographic path. Crisp white
// casings separate neighbouring services without moving route coordinates or
// cutting paths into offset pieces, so joins stay closed at every zoom.

export const TRANSIT_MODE_ORDER = ["ferry", "coach", "bus", "rail", "intercity", "tram", "metro"]

const BASE_WIDTH = {
  metro: 2.3,
  tram: 2.15,
  intercity: 2.1,
  rail: 2.05,
  bus: 1.45,
  coach: 1.45,
  ferry: 1.75,
}

const byZoom = (stops) => [
  "interpolate",
  ["linear"],
  ["zoom"],
  ...stops.flatMap(([zoom, value]) => [zoom, value]),
]

const scaleStops = (base) => [
  [4, base * 0.42],
  [7, base * 0.64],
  [10, base * 0.96],
  [13, base * 1.34],
  [16, base * 1.72],
  [19, base * 2.05],
]

const edgeStops = [
  [4, 0.8],
  [8, 1.0],
  [12, 1.35],
  [16, 1.65],
  [19, 1.9],
]

// MapLibre permits only one zoom-driven interpolate in a style expression.
// Merge two ramps at their union of stops instead of adding interpolates —
// the latter is rejected and silently leaves a layer at its 1 px fallback.
const rampAt = (stops, zoom) => {
  if (zoom <= stops[0][0]) return stops[0][1]

  for (let index = 1; index < stops.length; index++) {
    const [previousZoom, previousValue] = stops[index - 1]
    const [nextZoom, nextValue] = stops[index]

    if (zoom <= nextZoom) {
      const progress = (zoom - previousZoom) / (nextZoom - previousZoom)
      return previousValue + (nextValue - previousValue) * progress
    }
  }

  return stops[stops.length - 1][1]
}

const addRamps = (left, right) => {
  const zooms = [...new Set([...left, ...right].map(([zoom]) => zoom))].sort((a, b) => a - b)
  return zooms.map((zoom) => [zoom, rampAt(left, zoom) + rampAt(right, zoom)])
}

export const routeLayerIds = (category) => ({
  casing: `${category}-casing`,
  line: `${category}-line`,
})

export const routeLayerOrder = (categories = TRANSIT_MODE_ORDER) =>
  categories.map((category) => routeLayerIds(category).casing).concat(
    categories.map((category) => routeLayerIds(category).line)
  )

const continuousLineLayout = {
  "line-cap": "round",
  "line-join": "round",
  // MapLibre may substitute a miter for very shallow turns. Keeping the
  // threshold close to one reserves that optimisation for visually straight
  // runs while every meaningful bend receives a true round join.
  "line-round-limit": 1.02,
}

export const transitLineLayers = (category, source = `${category}-routes`) => {
  const ids = routeLayerIds(category)
  const routeStops = scaleStops(BASE_WIDTH[category] || 2)
  const routeWidth = byZoom(routeStops)

  return [
    {
      id: ids.casing,
      type: "line",
      source,
      layout: continuousLineLayout,
      paint: {
        "line-color": "rgba(255, 255, 255, 0.98)",
        "line-width": byZoom(addRamps(routeStops, edgeStops)),
        "line-opacity": byZoom([[4, 0.9], [8, 0.97], [12, 1]]),
      },
    },
    {
      id: ids.line,
      type: "line",
      source,
      layout: continuousLineLayout,
      paint: {
        "line-color": ["get", "color"],
        "line-width": routeWidth,
        "line-opacity": byZoom([[4, 0.9], [8, 0.98], [11, 1]]),
      },
    },
  ]
}
