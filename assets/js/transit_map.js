// MapLibre hook rendering an Apple Maps-style transit view: a muted basemap
// with bold, color-coded route lines and station markers, one toggleable
// layer group per mode category.

import maplibregl from "../vendor/maplibre-gl"

// Basemap resources are proxied through the app server (see
// TileProxyController) because some local networks/web-protection tools
// stall direct browser fetches of tile binaries.
const TILE_UPSTREAM = "https://tiles.openfreemap.org"
const tileProxyUrl = (path) => `${location.origin}/tiles${path}`
const BASEMAP_STYLE = tileProxyUrl("/styles/positron")

// Style and tilejson documents still reference the upstream host; rewrite
// those requests onto the proxy as MapLibre issues them.
const routeThroughProxy = (url) =>
  url.startsWith(TILE_UPSTREAM) ? {url: tileProxyUrl(url.slice(TILE_UPSTREAM.length))} : {url}

const UK_CENTER = [-2.0, 53.8]

// Draw order, lowest first: higher-frequency/short-distance modes sit on top.
const MODE_ORDER = ["ferry", "coach", "bus", "rail", "intercity", "tram", "metro"]

const LINE_WIDTH = {metro: 3.0, tram: 2.4, intercity: 2.6, rail: 2.2, bus: 1.4, coach: 1.4, ferry: 1.6}

const MODE_LABELS = {
  metro: "Metro",
  tram: "Tram",
  rail: "Rail",
  intercity: "Intercity",
  bus: "Bus",
  coach: "Coach",
  ferry: "Ferry",
}

const layerIds = (cat) => ({
  casing: `${cat}-casing`,
  line: `${cat}-line`,
  lineLabels: `${cat}-line-labels`,
  stops: `${cat}-stops`,
  labels: `${cat}-station-labels`,
})

// Global stacking: all line layers (in mode order), then line-name labels,
// then all stop layers.
const desiredLayerOrder = () =>
  MODE_ORDER.flatMap((cat) => [layerIds(cat).casing, layerIds(cat).line]).concat(
    MODE_ORDER.map((cat) => layerIds(cat).lineLabels),
    MODE_ORDER.map((cat) => layerIds(cat).stops),
    MODE_ORDER.map((cat) => layerIds(cat).labels)
  )

const TransitMap = {
  mounted() {
    this.loaded = new Set()
    this.enabled = new Set(JSON.parse(this.el.dataset.enabled))

    try {
      this.map = new maplibregl.Map({
        container: this.el,
        style: BASEMAP_STYLE,
        center: UK_CENTER,
        zoom: 5.5,
        transformRequest: routeThroughProxy,
      })
    } catch (error) {
      this.showMapError(error)
      return
    }
    this.map.on("error", (event) => console.error("MapLibre error:", event.error))
    this.map.addControl(new maplibregl.NavigationControl(), "top-right")

    this.map.on("style.load", () => this.syncLayers())
    this.handleEvent("categories-changed", ({enabled}) => {
      this.enabled = new Set(enabled)
      if (this.map.isStyleLoaded()) this.syncLayers()
    })
    this.handleEvent("map-region", ({region}) => this.showRegion(region))
  },

  showMapError(error) {
    console.error("Map failed to initialize:", error)
    this.el.innerHTML =
      `<div style="display:flex;height:100%;align-items:center;justify-content:center;color:#991B1B;font-family:monospace;padding:2rem;text-align:center">` +
      `Map failed to initialize: ${error.message}</div>`
  },

  showRegion(region) {
    const bounds = {
      "great-britain": [[-8.8, 49.7], [2.1, 59.2]],
      "northeast-corridor": [[-77.25, 38.75], [-70.75, 42.55]],
    }[region]

    if (bounds) this.map.fitBounds(bounds, {padding: 42, duration: 1200})
  },

  destroyed() {
    if (this.map) this.map.remove()
  },

  syncLayers() {
    MODE_ORDER.forEach((cat) => {
      if (this.enabled.has(cat)) this.showCategory(cat)
      else this.hideCategory(cat)
    })
  },

  async showCategory(cat) {
    if (this.loaded.has(cat)) {
      this.setCategoryVisibility(cat, "visible")
      return
    }
    this.loaded.add(cat)

    const [routes, stops] = await Promise.all([
      fetch(`/api/routes.geojson?cats=${cat}`).then((r) => r.json()),
      fetch(`/api/stops.geojson?cats=${cat}`).then((r) => r.json()),
    ])

    this.map.addSource(`${cat}-routes`, {type: "geojson", data: routes})
    this.map.addSource(`${cat}-stops`, {type: "geojson", data: stops})
    this.addCategoryLayers(cat)
  },

  hideCategory(cat) {
    if (this.loaded.has(cat)) this.setCategoryVisibility(cat, "none")
  },

  setCategoryVisibility(cat, visibility) {
    Object.values(layerIds(cat)).forEach((id) => {
      if (this.map.getLayer(id)) this.map.setLayoutProperty(id, "visibility", visibility)
    })
  },

  addCategoryLayers(cat) {
    const ids = layerIds(cat)
    const width = LINE_WIDTH[cat] || 2.0
    const zoomedWidth = (base) => ["interpolate", ["linear"], ["zoom"], 6, base * 0.6, 10, base, 14, base * 2.2]

    // Apple Maps-style parallel strands: routes sharing a corridor carry
    // distinct server-assigned offset slots. Slots fan out perpendicular to
    // the line once zoomed in enough to tell the strands apart; at country
    // zoom they collapse back onto the corridor. The offset step matches the
    // rendered line width at each zoom stop (see zoomedWidth), minus a hair
    // of overlap, so neighbouring strands sit flush as one solid ribbon with
    // no gap between them.
    const slot = ["to-number", ["coalesce", ["get", "offset"], 0]]
    const parallelOffset = [
      "interpolate", ["linear"], ["zoom"],
      9, 0,
      11, ["*", slot, width * 1.3 - 0.3],
      14, ["*", slot, width * 2.2 - 0.3],
    ]

    this.addLayerInOrder({
      id: ids.casing,
      type: "line",
      source: `${cat}-routes`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": "#ffffff",
        "line-width": zoomedWidth(width + 2.2),
        "line-opacity": 0.9,
        "line-offset": parallelOffset,
      },
    })

    this.addLayerInOrder({
      id: ids.line,
      type: "line",
      source: `${cat}-routes`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": zoomedWidth(width),
        "line-offset": parallelOffset,
      },
    })

    // Route names set along the line in the line's own color, as in Apple's
    // transit view ("Bakerloo line", "Central line", ...).
    this.addLayerInOrder({
      id: ids.lineLabels,
      type: "symbol",
      source: `${cat}-routes`,
      minzoom: 11,
      layout: {
        "symbol-placement": "line",
        "symbol-spacing": 450,
        "text-field": ["get", "name"],
        "text-font": ["Noto Sans Regular"],
        "text-size": ["interpolate", ["linear"], ["zoom"], 11, 10, 16, 13],
        "text-padding": 4,
        "text-optional": true,
      },
      paint: {
        "text-color": ["get", "color"],
        "text-halo-color": "rgba(255, 255, 255, 0.95)",
        "text-halo-width": 1.6,
        "text-halo-blur": 0.4,
      },
    })

    this.addLayerInOrder({
      id: ids.stops,
      type: "circle",
      source: `${cat}-stops`,
      minzoom: 9,
      paint: {
        "circle-color": "#ffffff",
        "circle-stroke-color": "#374151",
        "circle-radius": ["interpolate", ["linear"], ["zoom"], 9, 1.5, 12, 3.5, 15, 6],
        "circle-stroke-width": ["case", ["get", "station"], 1.6, 1.0],
        // Minor (bus-only) stops stay hidden until street-level zoom.
        "circle-opacity": ["step", ["zoom"], ["case", ["get", "station"], 1, 0], 13, 1],
        "circle-stroke-opacity": ["step", ["zoom"], ["case", ["get", "station"], 1, 0], 13, 1],
      },
    })

    this.addLayerInOrder({
      id: ids.labels,
      type: "symbol",
      source: `${cat}-stops`,
      minzoom: 8,
      filter: ["==", ["get", "station"], true],
      layout: {
        "text-field": ["get", "name"],
        "text-font": ["Noto Sans Regular"],
        "text-size": ["interpolate", ["linear"], ["zoom"], 8, 10, 12, 12, 16, 14],
        "text-anchor": "top",
        "text-offset": [0, 0.75],
        "text-max-width": 12,
        "text-padding": 3,
        "text-optional": true,
      },
      paint: {
        "text-color": "#1f2937",
        "text-halo-color": "rgba(255, 255, 255, 0.95)",
        "text-halo-width": 1.5,
        "text-halo-blur": 0.5,
      },
    })

    this.bindPopups(cat)
  },

  addLayerInOrder(layer) {
    const order = desiredLayerOrder()
    const beforeId = order
      .slice(order.indexOf(layer.id) + 1)
      .find((id) => this.map.getLayer(id))

    this.map.addLayer(layer, beforeId)
  },

  bindPopups(cat) {
    const ids = layerIds(cat)

    this.map.on("click", ids.stops, (e) => {
      this.openPopup(e.lngLat, this.stationPopupHtml(e.features[0].properties))
    })

    this.map.on("click", ids.line, (e) => {
      const stopLayers = MODE_ORDER.map((mode) => layerIds(mode).stops).filter((id) => this.map.getLayer(id))
      if (this.map.queryRenderedFeatures(e.point, {layers: stopLayers}).length > 0) return

      this.openPopup(e.lngLat, this.linePopupHtml(e.features[0].properties))
    })

    const setPointer = (on) => () => (this.map.getCanvas().style.cursor = on ? "pointer" : "")
    ;[ids.stops, ids.line].forEach((id) => {
      this.map.on("mouseenter", id, setPointer(true))
      this.map.on("mouseleave", id, setPointer(false))
    })
  },

  stationPopupHtml(props) {
    const lines = typeof props.lines === "string" ? JSON.parse(props.lines) : props.lines || []
    const groups = this.stationServiceGroups(lines)
    const lineCount = groups.reduce((count, group) => count + group.lines.length, 0)

    const summary = lineCount
      ? `<div class="station-popup__summary">` +
        `${lineCount} ${lineCount === 1 ? "line" : "lines"} · ` +
        `${groups.length} ${groups.length === 1 ? "operator" : "operators"}</div>`
      : ""

    const body = groups.length
      ? groups.map((group) => this.serviceGroupHtml(group)).join("")
      : `<div class="station-popup__empty">No service information available</div>`

    return (
      `<div class="station-popup">` +
      `<header class="station-popup__header"><div class="station-popup__heading">` +
      `<div class="station-popup__title">${this.escapeHtml(props.name || "Stop")}</div>${summary}` +
      `</div></header>` +
      `<div class="station-popup__body">${body}</div></div>`
    )
  },

  serviceGroupHtml(group) {
    const rows = group.lines
      .map((line) => {
        // Rail is the assumed default; only other modes are called out.
        const mode =
          line.category && line.category !== "rail"
            ? `<span class="station-popup__mode">${this.escapeHtml(MODE_LABELS[line.category] || line.category)}</span>`
            : ""

        return (
          `<li class="station-popup__line">` +
          `<span class="station-popup__swatch" style="background:${this.safeColor(line.color)}"></span>` +
          `<span class="station-popup__line-name">${this.escapeHtml(line.label)}</span>${mode}</li>`
        )
      })
      .join("")

    return (
      `<section class="station-popup__group">` +
      `<h3 class="station-popup__operator">${this.escapeHtml(group.agency)}</h3>` +
      `<ul class="station-popup__lines">${rows}</ul></section>`
    )
  },

  linePopupHtml(props) {
    const agency = props.agency
      ? `<div class="station-popup__summary">${this.escapeHtml(props.agency)}</div>`
      : ""

    return (
      `<div class="station-popup">` +
      `<header class="station-popup__header">` +
      `<span class="station-popup__swatch station-popup__swatch--header" style="background:${this.safeColor(props.color)}"></span>` +
      `<div class="station-popup__heading">` +
      `<div class="station-popup__title">${this.escapeHtml(props.long_name || props.name || "Route")}</div>${agency}` +
      `</div></header></div>`
    )
  },

  openPopup(lngLat, html) {
    if (this.popup) this.popup.remove()

    this.popup = new maplibregl.Popup({closeButton: true, maxWidth: "280px"})
      .setLngLat(lngLat)
      .setHTML(html)
      .addTo(this.map)
  },

  escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (char) =>
      ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[char]
    )
  },

  safeColor(value) {
    return /^#[0-9a-f]{6}$/i.test(value || "") ? value : "#6b7280"
  },

  stationServices(lines) {
    const services = new Map()

    lines.forEach((line) => {
      const label = line.name || line.agency
      if (!label) return

      const agency = line.agency && line.agency !== label ? line.agency : null
      const key = `${label}:${agency || ""}`
      if (!services.has(key)) services.set(key, {label, agency, color: line.color, category: line.category})
    })

    return [...services.values()].sort(
      (a, b) => (a.agency || "").localeCompare(b.agency || "") || a.label.localeCompare(b.label)
    )
  },

  stationServiceGroups(lines) {
    const groups = new Map()

    this.stationServices(lines).forEach((line) => {
      const agency = line.agency || "Transit service"
      const group = groups.get(agency) || {agency, lines: []}
      group.lines.push(line)
      groups.set(agency, group)
    })

    return [...groups.values()].sort((a, b) => a.agency.localeCompare(b.agency))
  },

}

export default TransitMap
