// A transit line is drawn as one uninterrupted geographic path. The visual
// separation comes from this layer stack, never from moving route coordinates
// or cutting a route into offset pieces. That keeps joins closed and curves
// faithful at every zoom, including dense station throats.

export const TRANSIT_MODE_ORDER = ["ferry", "coach", "bus", "rail", "intercity", "tram", "metro"]

const BASE_WIDTH = {
  metro: 3.15,
  tram: 2.75,
  intercity: 2.7,
  rail: 2.35,
  bus: 1.6,
  coach: 1.6,
  ferry: 1.9,
}

const byZoom = (stops) => [
  "interpolate",
  ["linear"],
  ["zoom"],
  ...stops.flatMap(([zoom, value]) => [zoom, value]),
]

const scaleStops = (base) =>
  byZoom([
    [4, base * 0.42],
    [7, base * 0.64],
    [10, base * 0.96],
    [13, base * 1.34],
    [16, base * 1.72],
    [19, base * 2.05],
  ])

const edgeWidth = byZoom([
  [4, 1.15],
  [8, 1.5],
  [12, 1.9],
  [16, 2.25],
  [19, 2.55],
])

const shadowWidth = byZoom([
  [4, 1.7],
  [8, 2.15],
  [12, 2.7],
  [16, 3.1],
  [19, 3.45],
])

export const routeLayerIds = (category) => ({
  shadow: `${category}-line-shadow`,
  casing: `${category}-casing`,
  line: `${category}-line`,
})

export const routeLayerOrder = (categories = TRANSIT_MODE_ORDER) =>
  categories.map((category) => routeLayerIds(category).shadow).concat(
    categories.map((category) => routeLayerIds(category).casing),
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
  const routeWidth = scaleStops(BASE_WIDTH[category] || 2)

  return [
    {
      id: ids.shadow,
      type: "line",
      source,
      layout: continuousLineLayout,
      paint: {
        "line-color": "rgba(28, 36, 43, 0.24)",
        "line-width": ["+", routeWidth, shadowWidth],
        "line-blur": byZoom([[4, 0.25], [10, 0.45], [16, 0.7]]),
        "line-opacity": byZoom([[4, 0.34], [9, 0.44], [14, 0.5]]),
      },
    },
    {
      id: ids.casing,
      type: "line",
      source,
      layout: continuousLineLayout,
      paint: {
        "line-color": "rgba(255, 255, 255, 0.97)",
        "line-width": ["+", routeWidth, edgeWidth],
        "line-opacity": byZoom([[4, 0.88], [8, 0.96], [12, 1]]),
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
