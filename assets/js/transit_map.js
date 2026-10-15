import maplibregl from "../vendor/maplibre-gl"
import {
  PLACES_LAYER_ID,
  groupForClass,
  placeFilter,
  placeLabelPaint,
  placeLayer,
  placePinId,
  placeSubtitle,
  renderPlacePin,
} from "./map_places"
import {DARK_LINE, readPalette, watchColorScheme, withAlpha} from "./map_palette"

const TILE_UPSTREAM = "https://tiles.openfreemap.org"
const tileProxyUrl = (path) => `${location.origin}/tiles${path}`
const BASEMAP_STYLE = tileProxyUrl("/styles/positron")

const routeThroughProxy = (url) =>
  url.startsWith(TILE_UPSTREAM) ? {url: tileProxyUrl(url.slice(TILE_UPSTREAM.length))} : {url}

// The query parameters MapLive reads the menu's state from.
const URL_STATE_KEYS = ["modes", "details", "places", "hide"]

// Where the map opens, unless the URL hash already names a view. The server
// warms its cache for the agencies here (GeoJsonCache's @opening_view).
const DEFAULT_VIEW = {center: [-2.0, 53.8], zoom: 5.5}

// Agencies are loaded for a view padded by this fraction on every side, so
// lines are already there when a pan brings them on screen.
const LOAD_PADDING = 0.5

// How much of each line's detail the server sends (Gtfs.sanitize_detail/1).
// A zoomed-out view spans dozens of national networks, and their full track
// would not fit in a phone's memory: Belgium at zoom 5 is over 100 MB of it.
const detailForZoom = (zoom) => (zoom < 8 ? "low" : zoom < 11 ? "mid" : "full")

// Stations are drawn from zoom 10.5 (the stops layers' minzoom), so they
// load from 10 and not before.
const STOPS_MIN_ZOOM = 10

// Zoomed in, lines and stations come in grid cells of this many degrees
// (Transitmaps.Gtfs.Cells), each with only what crosses it: a national
// network sent whole to a view of Paris was over 80 MB.
const CELL_DEGREES = {mid: 4, full: 1, stops: 1}

// The cells, as "x,y", of a part's grid covering the view's overlap with an
// agency's service area.
const cellsFor = (part, [west, south, east, north], [[feedWest, feedSouth], [feedEast, feedNorth]]) => {
  const size = CELL_DEGREES[part]
  const [w, s, e, n] = [Math.max(west, feedWest), Math.max(south, feedSouth), Math.min(east, feedEast), Math.min(north, feedNorth)]
  if (w > e || s > n) return []

  const clamp = (value, low, high) => Math.min(Math.max(value, low), high)
  const xs = [clamp(Math.floor(w / size), -180, 179), clamp(Math.floor(e / size), -180, 179)]
  const ys = [clamp(Math.floor(s / size), -90, 89), clamp(Math.floor(n / size), -90, 89)]
  const cells = []
  for (let x = xs[0]; x <= xs[1]; x++) for (let y = ys[0]; y <= ys[1]; y++) cells.push(`${x},${y}`)
  return cells
}

// Stations of different agencies this close together are one interchange —
// the same rule `Transitmaps.Gtfs.merge_colocated_stops/1` applies within an
// agency. Bus stops only merge when practically on top of one another.
const STATION_MERGE_KM = 0.25
const STOP_MERGE_KM = 0.05

const kmScale = (lat) => [111.32 * Math.cos((lat * Math.PI) / 180), 110.57]
const lineKey = (line) => line.key || `${line.name}|${line.agency}`

// One station out of several agencies' stops at the same place: the name of
// whichever serves the most lines, every line and mode, sat at their middle.
const combineStops = (features) => {
  const lines = [...new Map(features.flatMap((f) => f.properties.lines || []).map((l) => [lineKey(l), l])).values()]
  const best = features.reduce((a, b) => {
    const score = (f) => [(f.properties.lines || []).length, String(f.properties.name || "").length]
    const [la, na] = score(a)
    const [lb, nb] = score(b)
    return lb > la || (lb === la && nb > na) ? b : a
  })
  const mean = (i) => features.reduce((sum, f) => sum + f.geometry.coordinates[i], 0) / features.length

  return {
    type: "Feature",
    geometry: {type: "Point", coordinates: [mean(0), mean(1)]},
    properties: {
      ...best.properties,
      categories: [...new Set(features.flatMap((f) => f.properties.categories || []))],
      lines,
      station: features.some((f) => f.properties.station),
      interchange: new Set(lines.map(lineKey)).size || best.properties.interchange,
    },
  }
}

// Chains stops into one station while each hop stays inside the merge
// radius, using a grid one station radius across so every candidate
// neighbour is in the same cell or one touching it.
const mergeColocatedStops = (features) => {
  const points = features.map((feature) => {
    const [lon, lat] = feature.geometry.coordinates
    const [kx, ky] = kmScale(lat)
    return {x: lon * kx, y: lat * ky, station: Boolean(feature.properties.station)}
  })
  const cellOf = (point) => [Math.floor(point.x / STATION_MERGE_KM), Math.floor(point.y / STATION_MERGE_KM)]
  const cells = new Map()
  points.forEach((point, index) => {
    const key = cellOf(point).join(",")
    if (!cells.has(key)) cells.set(key, [])
    cells.get(key).push(index)
  })

  const visited = new Uint8Array(points.length)
  const merged = []

  points.forEach((_point, start) => {
    if (visited[start]) return
    visited[start] = 1
    const queue = [start]
    const members = []

    while (queue.length > 0) {
      const index = queue.pop()
      members.push(index)
      const point = points[index]
      const [cx, cy] = cellOf(point)

      for (let dx = -1; dx <= 1; dx++) {
        for (let dy = -1; dy <= 1; dy++) {
          ;(cells.get(`${cx + dx},${cy + dy}`) || []).forEach((other) => {
            if (visited[other]) return
            const candidate = points[other]
            const radius = point.station && candidate.station ? STATION_MERGE_KM : STOP_MERGE_KM
            const distance = Math.hypot(candidate.x - point.x, candidate.y - point.y)
            if (distance <= radius) {
              visited[other] = 1
              queue.push(other)
            }
          })
        }
      }
    }

    merged.push(members.length === 1 ? features[members[0]] : combineStops(members.map((i) => features[i])))
  })

  return merged
}

const MODE_ORDER = ["ferry", "coach", "bus", "rail", "intercity", "tram", "metro"]
const MODE_LABEL = {
  ferry: "Ferry",
  coach: "Coach",
  bus: "Bus",
  rail: "National Rail",
  intercity: "Intercity",
  tram: "Tram",
  metro: "Metro",
}
// Every mode draws at one flat width, at every zoom. A starting point, not a rule.
const LINE_WIDTH = 2

// Mode brand colours mirror Transitmaps.Gtfs.RouteTypes.default_color/1 so a
// station's mode headings read the same as the toggles in the layers menu.
const MODE_COLOR = {
  metro: "#E32017",
  tram: "#00A65F",
  rail: "#1D4ED8",
  intercity: "#7C3AED",
  bus: "#D97706",
  coach: "#B45309",
  ferry: "#0891B2",
}
// Reading order for a station's services: fixed rail modes first, then road,
// then water — the order a passenger scans an interchange, not alphabetical.
const STATION_MODE_ORDER = ["metro", "rail", "intercity", "tram", "bus", "coach", "ferry"]
const modeRank = (category) => {
  const index = STATION_MODE_ORDER.indexOf(category)
  return index === -1 ? STATION_MODE_ORDER.length : index
}
const titleCase = (value) =>
  String(value || "").replace(/(^|[\s-])\w/g, (match) => match.toUpperCase())

// Grows a marker dimension with the number of services meeting at a stop.
// Responses cached before interchange counts were served carry no count, so
// those stops fall back to the single-service size.
const interchangeScale = (busy) => [
  "interpolate",
  ["linear"],
  ["coalesce", ["get", "interchange"], 1],
  1,
  1,
  6,
  busy,
]

// MapLibre only accepts a `zoom` expression as the input of a top-level
// interpolate, so the interchange factor cannot wrap one — it multiplies each
// zoom stop's output instead.
const byZoomAndInterchange = (stops, busy) => [
  "interpolate",
  ["linear"],
  ["zoom"],
  ...stops.flatMap(([zoom, size]) => [zoom, ["*", size, interchangeScale(busy)]]),
]

// Stations fade in as the view reaches neighbourhood level; other stops
// (bus stops, platforms without a station) follow once streets are legible.
const stopOpacity = [
  "interpolate",
  ["linear"],
  ["zoom"],
  10.5,
  0,
  11,
  ["case", ["get", "station"], 1, 0],
  12.5,
  ["case", ["get", "station"], 1, 0],
  13,
  1,
]

const layerIds = (cat) => ({
  casing: `${cat}-line-casing`,
  line: `${cat}-line`,
  lineLabels: `${cat}-line-labels`,
  stops: `${cat}-stops`,
  labels: `${cat}-station-labels`,
})

// A clicked line, drawn again above every other line while it has focus.
const FOCUS_SOURCE_ID = "focus-line"
const FOCUS_CASING_ID = "focus-line-casing"
const FOCUS_LINE_ID = "focus-line"
// How far the other lines and their names fade back while one has focus.
const UNFOCUSED_OPACITY = 0.16

// Lines first (a focused line above the rest), then their names, then stops
// and station names on top.
const desiredLayerOrder = () =>
  MODE_ORDER.flatMap((cat) => [layerIds(cat).casing, layerIds(cat).line]).concat(
    [FOCUS_CASING_ID, FOCUS_LINE_ID],
    MODE_ORDER.map((cat) => layerIds(cat).lineLabels),
    MODE_ORDER.map((cat) => layerIds(cat).stops),
    MODE_ORDER.map((cat) => layerIds(cat).labels)
  )

const TransitMap = {
  mounted() {
    // Categories whose sources and layers exist on the map.
    this.loaded = new Set()
    // Per agency, mode and part, keyed "feedId:category:part": a part is a
    // line detail (low, mid, full) or "stops".
    this.pending = new Map()
    this.feedData = new Map()
    this.feeds = this.parseData("feeds", [])
    this.hidden = new Set(this.parseData("hidden", []))
    this.reportedView = null
    this.renderedKey = null
    this.dataLoadBatch = 0
    this.dataLoading = false
    this.enabled = new Set(this.parseData("enabled", []))
    this.details = new Set(this.parseData("details", ["labels", "stops"]))
    this.places = new Set(this.parseData("places", []))
    this.placeCatalog = this.parseData("placeCatalog", [])
    this.palette = readPalette()

    try {
      this.map = new maplibregl.Map({
        container: this.el,
        style: BASEMAP_STYLE,
        ...DEFAULT_VIEW,
        // The view lives in the URL hash, so a place on the map can be shared.
        hash: "map",
        minZoom: 4,
        // Zoom 14 is as deep as the vector tiles go, so everything past it is
        // overzoom. Allowing three extra levels costs no new data and is what
        // makes a crowded high street readable: the same block covers eight
        // times the pixels at 19, so pins that lost the fight for space at 14
        // all find room and every name ends up on screen.
        maxZoom: 19,
        maxPitch: 0,
        renderWorldCopies: false,
        fadeDuration: 0,
        transformRequest: routeThroughProxy,
      })
    } catch (error) {
      this.showMapError(error)
      return
    }

    this.map.on("error", (event) => console.error("MapLibre error:", event.error))
    // Layers can be added once the style has loaded. isStyleLoaded() is no
    // guide to that: it stays false while any basemap tile is still loading,
    // and a redraw skipped then would not come back until the map moved.
    this.styleReady = false
    this.map.on("style.load", () => {
      this.styleReady = true
      this.compactLoading()
      this.updateZoomReadout()
      this.basemapLabelsId = this.map.getStyle().layers.find((layer) => layer.type === "symbol")?.id
      this.applyBasemap()
      // Places are added before any transit layer exists, which leaves every
      // pin below the lines and stations the map is actually about.
      this.addPlaceLayers()
      this.syncLayers()
    })
    this.map.on("load", () => this.markMapReady())
    this.map.on("zoom", () => this.updateZoomReadout())
    this.map.on("idle", () => this.announceIdle())
    this.map.on("moveend", () => {
      if (this.styleReady) this.syncLayers()
    })

    this.handleEvent("categories-changed", ({enabled}) => {
      this.enabled = new Set(enabled)
      if (this.styleReady) this.syncLayers()
    })
    this.handleEvent("details-changed", ({enabled}) => {
      this.details = new Set(enabled)
      this.syncDetails()
    })
    this.handleEvent("places-changed", ({enabled}) => {
      this.places = new Set(enabled)
      this.syncPlaces()
    })
    // An agency was added (or a hand-curated copy retired). What is drawn
    // stays put; a new agency in range simply loads, and a retired one
    // drops out of range. A weekly refresh shows on the next page load.
    this.handleEvent("feeds-changed", ({feeds}) => {
      this.feeds = feeds
      if (this.styleReady) this.syncLayers()
    })
    this.handleEvent("agencies-hidden", ({hidden}) => {
      this.hidden = new Set(hidden)
      this.render()
    })
    // What the map shows, kept in the query string so a refresh or a shared
    // link keeps it. Replaced rather than pushed: a toggle is not a page to go
    // back to. Other parameters and the map's #hash stay as they are.
    this.handleEvent("url-state", ({query}) => {
      const params = new URLSearchParams(location.search)
      URL_STATE_KEYS.forEach((key) => params.delete(key))
      new URLSearchParams(query).forEach((value, key) => params.set(key, value))
      const search = params.toString().replaceAll("%2C", ",")
      history.replaceState(history.state, "", `${location.pathname}${search ? `?${search}` : ""}${location.hash}`)
    })
    // A station picked in the search: fly to it, and open its details once
    // its stops are drawn (see openPendingStation).
    this.handleEvent("show-station", ({lng, lat, name}) => {
      this.closePopup()
      this.pendingStation = {lng, lat, name}
      this.map.flyTo({center: [lng, lat], zoom: Math.max(this.map.getZoom(), 15), duration: 900})
    })
    this.handleEvent("fly-to", ({bounds}) => {
      this.map.fitBounds(bounds, {padding: this.mapPadding(), duration: 900})
    })

    this.zoomInHandler = () => this.map.easeTo({zoom: this.map.getZoom() + 1, duration: 300})
    this.zoomOutHandler = () => this.map.easeTo({zoom: this.map.getZoom() - 1, duration: 300})
    this.locateHandler = () => this.locateUser()
    this.setZoomHandler = (event) => {
      const zoom = Number(event.detail?.zoom)
      const center = event.detail?.center
      if (Number.isFinite(zoom)) this.map.jumpTo({zoom, ...(Array.isArray(center) ? {center} : {})})
    }

    // Escape lets a focused line go (the menu has its own Escape).
    this.escapeHandler = (event) => {
      if (event.key !== "Escape" || !(this.focus || this.popupOnClose || this.popupElement())) return
      this.closePopup()
      this.clearFocus()
    }
    window.addEventListener("keydown", this.escapeHandler)

    this.el.addEventListener("map:zoom-in", this.zoomInHandler)
    this.el.addEventListener("map:zoom-out", this.zoomOutHandler)
    this.el.addEventListener("map:locate", this.locateHandler)
    this.el.addEventListener("map:set-zoom", this.setZoomHandler)

    this.stopWatchingScheme = watchColorScheme(() => this.applyPalette())

    this.map.on("click", (event) => this.handleMapClick(event))
    this.el.querySelector("[data-map-detail-close]")?.addEventListener("click", () => this.closePopup())

    this.el.querySelector("[data-map-notice-dismiss]")?.addEventListener("click", () => this.hideMapNotice())
    this.el.querySelector("[data-map-notice-retry]")?.addEventListener("click", () => {
      const retry = this.noticeRetry
      this.hideMapNotice()
      if (retry) retry()
    })
  },

  parseData(key, fallback) {
    try {
      return JSON.parse(this.el.dataset[key])
    } catch (_error) {
      return fallback
    }
  },

  showMapError(error) {
    console.error("Map failed to initialize:", error)
    this.el.dataset.mapReady = "error"
    this.el.innerHTML =
      `<div class="ui-page-state tm-map-error" data-status="failure" role="alert">` +
      `<h2 class="ui-page-state-title">Map failed to load</h2>` +
      `<p>${this.escapeHtml(error.message)}</p>` +
      `<p>Reload the page to try again. A browser without WebGL cannot draw the map.</p></div>`
  },

  markMapReady() {
    this.el.dataset.mapReady = "true"
    if (!this.dataLoading) this.hideLoading()
    this.updateZoomReadout()
  },

  // The basemap's style is in. Whatever is still loading steps aside to a
  // small status over the map, so tiles and lines fill in as they arrive and
  // the map can be moved meanwhile.
  compactLoading() {
    const loading = this.el.querySelector(".map-loading")
    if (!loading) return
    loading.classList.add("tm-loading--compact")
    if (!this.dataLoading) loading.hidden = true
  },

  showLoading(label, detail, progress = null) {
    const loading = this.el.querySelector(".map-loading")
    if (!loading) return

    const labelEl = loading.querySelector("[data-loading-label]")
    const detailEl = loading.querySelector("[data-loading-detail]")
    const progressEl = loading.querySelector("[data-loading-progress]")

    loading.hidden = false
    if (labelEl) labelEl.textContent = label
    if (detailEl) detailEl.textContent = detail

    // The bar jumps to its value; it never animates (DESIGN.md section 8).
    if (progressEl) {
      const value = progress === null ? 0 : Math.max(0, Math.min(100, Math.round(progress)))
      progressEl.style.setProperty("--value", `${value}%`)
      if (progress === null) progressEl.removeAttribute("aria-valuenow")
      else progressEl.setAttribute("aria-valuenow", String(value))
    }
  },

  hideLoading() {
    const loading = this.el.querySelector(".map-loading")
    if (loading) loading.hidden = true
  },

  // A problem with the map, named at its top, with a way to try again.
  showMapNotice(text, retry) {
    const notice = this.el.querySelector("[data-map-notice]")
    if (!notice) return
    notice.querySelector("[data-map-notice-text]").textContent = text
    this.noticeRetry = retry
    notice.querySelector("[data-map-notice-retry]").hidden = !retry
    notice.hidden = false
  },

  hideMapNotice() {
    const notice = this.el.querySelector("[data-map-notice]")
    if (notice) notice.hidden = true
  },

  // Loading shows only when it takes long enough to notice: a pan that
  // brings in one small agency should not flash a status.
  startDataLoading(batch, keys) {
    clearTimeout(this.loadingTimer)
    this.dataLoading = keys.length > 0
    this.dataLoadProgress = {batch, keys: new Set(keys), complete: new Set()}

    if (this.dataLoading) {
      const delay = this.styleReady ? 400 : 0
      this.loadingTimer = setTimeout(() => this.showDataProgress(batch), delay)
    }
  },

  advanceDataLoading(batch, key) {
    const progress = this.dataLoadProgress
    if (!progress || progress.batch !== batch || !progress.keys.has(key)) return

    progress.complete.add(key)
    if (!this.el.querySelector(".map-loading")?.hidden) this.showDataProgress(batch)
  },

  showDataProgress(batch) {
    const progress = this.dataLoadProgress
    if (!this.dataLoading || progress?.batch !== batch) return

    const complete = progress.complete.size
    const total = progress.keys.size
    this.showLoading(
      "Loading transit data…",
      `${complete} of ${total} ${total === 1 ? "layer" : "layers"}`,
      (complete / total) * 100
    )
  },

  // Lines are drawn as they arrive, at most a few times a second, rather
  // than once everything in view has loaded.
  scheduleRender() {
    if (this.renderTimer) return
    this.renderTimer = setTimeout(() => {
      this.renderTimer = null
      this.render()
    }, 250)
  },

  announceIdle() {
    if (!this.map?.loaded()) return
    this.markMapReady()
    this.el.dataset.mapIdle = "true"
    window.dispatchEvent(new CustomEvent("transit-map:idle", {detail: {zoom: this.map.getZoom()}}))
  },

  updateZoomReadout() {
    const zoom = this.map?.getZoom()
    if (!Number.isFinite(zoom)) return
    this.el.dataset.mapZoom = zoom.toFixed(1)
    const readout = document.querySelector("#map-zoom-readout")
    if (readout) readout.textContent = `z${zoom.toFixed(1)}`
  },

  // Room for what sits over the map: the filter button (and its menu when
  // it is open beside a wide map) at the top-left, the controls on the right.
  mapPadding() {
    if (this.narrow()) {
      const panel = this.el.querySelector("[data-map-detail]:not([hidden])")
      return {top: 56, right: 24, bottom: panel ? panel.offsetHeight + 24 : 72, left: 24}
    }

    const menu = document.getElementById("map-menu")
    const left = menu ? Math.round(menu.getBoundingClientRect().right) + 24 : 32
    return {top: 56, right: 64, bottom: 32, left}
  },

  destroyed() {
    window.removeEventListener("keydown", this.escapeHandler)
    this.el.removeEventListener("map:zoom-in", this.zoomInHandler)
    this.el.removeEventListener("map:zoom-out", this.zoomOutHandler)
    this.el.removeEventListener("map:locate", this.locateHandler)
    this.el.removeEventListener("map:set-zoom", this.setZoomHandler)
    if (this.stopWatchingScheme) this.stopWatchingScheme()
    if (this.map) this.map.remove()
  },

  // The basemap in the page's grays (the --map-* tokens), so the transit
  // lines carry the only hues on the map. Labels sit on a halo of the land.
  applyBasemap() {
    const p = this.palette
    const fills = {
      background: p.land,
      park: p.park,
      water: p.water,
      landcover_ice_shelf: p.land,
      landcover_glacier: p.land,
      landuse_residential: p.land,
      landcover_wood: p.park,
      building: p.building,
      aeroway_area: p.building,
      road_area_pier: p.building,
    }

    const lines = {
      waterway: p.water,
      aeroway_taxiway: p.roadCasing,
      aeroway_runway_casing: p.roadCasing,
      aeroway_runway: p.road,
      road_pier: p.roadCasing,
      highway_path: p.road,
      highway_minor: p.road,
      highway_major_casing: p.roadCasing,
      highway_major_inner: p.road,
      highway_major_subtle: p.road,
      highway_motorway_casing: p.motorwayCasing,
      highway_motorway_inner: p.motorway,
      highway_motorway_subtle: p.motorway,
      highway_motorway_bridge_casing: p.motorwayCasing,
      highway_motorway_bridge_inner: p.motorway,
      tunnel_motorway_casing: p.roadCasing,
      tunnel_motorway_inner: p.road,
      boundary_3: p.boundary,
      boundary_2: p.boundary,
      boundary_disputed: p.boundary,
    }

    this.map.getStyle().layers.forEach((layer) => {
      const key = layer.id.replaceAll("-", "_")

      if (layer.type === "background") {
        this.setPaint(layer.id, "background-color", fills.background)
      } else if (layer.type === "fill" && fills[key]) {
        this.setPaint(layer.id, "fill-color", fills[key])
      } else if (layer.type === "line" && lines[key]) {
        this.setPaint(layer.id, "line-color", lines[key])
      } else if (layer.type === "symbol") {
        this.setPaint(layer.id, "text-color", layer.id.includes("water") ? p.waterLabel : p.label)
        this.setPaint(layer.id, "text-halo-color", withAlpha(p.land, 0.9))
        this.setPaint(layer.id, "text-halo-width", 1.2)
      }

      // The app draws its own railways, and road shields are colour the map
      // doesn't need.
      if (layer.id.startsWith("railway") || key.includes("shield")) {
        this.map.setLayoutProperty(layer.id, "visibility", "none")
      }
    })
  },

  // The light or dark mode changed: read the tokens again and repaint
  // everything the map drew from them.
  applyPalette() {
    this.palette = readPalette()
    if (!this.styleReady) return

    this.applyBasemap()
    this.loaded.forEach((cat) => this.paintCategory(cat))
    this.setPaint(FOCUS_CASING_ID, "line-color", this.palette.background)
    this.paintPlaces()
  },

  setPaint(layerId, property, value) {
    try {
      this.map.setPaintProperty(layerId, property, value)
    } catch (_error) {
      // Style layers vary slightly between OpenFreeMap releases.
    }
  },

  addPlaceLayers() {
    this.placePins()
    // Pins go under the basemap's names, and so under the lines too.
    this.map.addLayer(placeLayer(this.palette), this.basemapLabelsId)
    this.bindPlacePopup()
    this.syncPlaces()
  },

  // One pin image per group, ringed in the current background colour.
  placePins() {
    const pixelRatio = window.devicePixelRatio || 1
    const ring = withAlpha(this.palette.background, 0.95)

    this.placeCatalog.forEach(({id, color}) => {
      const pin = renderPlacePin(color, id, pixelRatio, ring)
      if (this.map.hasImage(placePinId(id))) this.map.updateImage(placePinId(id), pin)
      else this.map.addImage(placePinId(id), pin, {pixelRatio})
    })
  },

  paintPlaces() {
    this.placePins()
    Object.entries(placeLabelPaint(this.palette)).forEach(([property, value]) =>
      this.setPaint(PLACES_LAYER_ID, property, value)
    )
  },

  // Categories are switched by narrowing the shared layer's filter rather than
  // by hiding layers, so the pins on screen always come from one ranked
  // contest between everything the user asked for.
  syncPlaces() {
    const groups = this.placeCatalog.map(({id}) => id).filter((id) => this.places.has(id))

    // An empty class list is not a valid `match`, so no categories means the
    // layer is simply switched off.
    if (groups.length > 0) this.map.setFilter(PLACES_LAYER_ID, placeFilter(groups))
    this.setVisibility(PLACES_LAYER_ID, groups.length > 0 ? "visible" : "none")
  },

  bindPlacePopup() {
    const setPointer = (on) => () => (this.map.getCanvas().style.cursor = on ? "pointer" : "")
    this.map.on("mouseenter", PLACES_LAYER_ID, setPointer(true))
    this.map.on("mouseleave", PLACES_LAYER_ID, setPointer(false))
  },

  // One handler for every click or tap on the map. It looks for a station,
  // then a line, then a place within a thumb's reach of the point (a station
  // marker is a few pixels wide) and opens the nearest; a click on nothing
  // closes what is open.
  handleMapClick(event) {
    const reach = window.matchMedia("(pointer: coarse)").matches ? 16 : 6
    const {x, y} = event.point
    const box = [[x - reach, y - reach], [x + reach, y + reach]]
    const shown = (ids) => ids.filter((id) => this.map.getLayer(id))
    const nearest = (features) =>
      features
        .map((feature) => {
          const [lng, lat] = feature.geometry.type === "Point" ? feature.geometry.coordinates : [event.lngLat.lng, event.lngLat.lat]
          const at = this.map.project([lng, lat])
          return {feature, distance: Math.hypot(at.x - x, at.y - y)}
        })
        .sort((a, b) => a.distance - b.distance)[0]?.feature

    const station = nearest(this.map.queryRenderedFeatures(box, {layers: shown(MODE_ORDER.map((cat) => layerIds(cat).stops))}))
    if (station) {
      const [lng, lat] = station.geometry.coordinates
      this.openPopup({lng, lat}, this.stationPopupHtml(station.properties), () => this.clearFocus())
      this.bindRouteBadges()
      return
    }

    const line = this.map.queryRenderedFeatures(box, {layers: shown(MODE_ORDER.map((cat) => layerIds(cat).line))})[0]
    if (line) {
      const cat = MODE_ORDER.find((mode) => layerIds(mode).line === line.layer.id)
      this.openLinePopup(event.lngLat, line.properties, cat)
      return
    }

    const place = nearest(this.map.queryRenderedFeatures(box, {layers: shown([PLACES_LAYER_ID])}))
    if (place) {
      const [lng, lat] = place.geometry.coordinates
      this.openPlacePopup({lng, lat}, place.properties)
      return
    }

    this.closePopup()
  },

  openLinePopup(lngLat, props, cat) {
    const title = props.long_name || props.name || "Transit route"
    const meta = [MODE_LABEL[cat] || titleCase(cat), props.agency !== title && props.agency]
      .filter(Boolean)
      .map((part) => this.escapeHtml(part))
      .join(`<span class="ui-sep">·</span>`)
    this.openPopup(
      lngLat,
      `<div class="tm-popup"><div class="tm-popup-header">` +
        `<div class="tm-popup-title">${this.escapeHtml(title)}</div>` +
        `<div class="tm-popup-meta">${this.swatchHtml(props.color)}<span>${meta}</span></div>` +
        `</div></div>`,
      // Closing the line's details (or clicking away) lets the line go.
      () => this.clearFocus()
    )
    this.focusLine({...props, category: cat})
  },

  openPlacePopup(lngLat, props) {
    const group = this.placeCatalog.find(({id}) => id === groupForClass(props.class))
    const meta = [placeSubtitle(props), group?.label].filter(Boolean).join(" · ")

    this.openPopup(
      lngLat,
      `<div class="tm-popup"><div class="tm-popup-header">` +
        `<div class="tm-popup-title">${this.escapeHtml(props.name)}</div>` +
        `<div class="tm-popup-meta">${this.swatchHtml(group?.color, "dot")}<span>${this.escapeHtml(meta)}</span></div>` +
        `</div></div>`
    )
  },

  // Agencies whose service area overlaps the view, padded by `padding` of
  // its size on every side.
  feedsNear(padding) {
    const [west, south, east, north] = this.viewBox(padding)

    return this.feeds
      .filter(({bounds: [[w, s], [e, n]]}) => w <= east && e >= west && s <= north && n >= south)
      .map((feed) => feed.id)
      .sort((a, b) => a - b)
  },

  // The view as [west, south, east, north], padded by `padding` of its size
  // on every side.
  viewBox(padding) {
    const bounds = this.map.getBounds()
    const padX = (bounds.getEast() - bounds.getWest()) * padding
    const padY = (bounds.getNorth() - bounds.getSouth()) * padding
    return [bounds.getWest() - padX, bounds.getSouth() - padY, bounds.getEast() + padX, bounds.getNorth() + padY]
  },

  // The agencies drawn right now: near the view and not hidden by the visitor.
  activeFeeds() {
    return this.feedsNear(LOAD_PADDING).filter((id) => !this.hidden.has(id))
  },

  // Reports what is on screen to the menu, then loads whatever the drawn
  // agencies are missing for the enabled modes and redraws as it lands.
  // `skip` holds layers that already failed in an earlier round of this
  // load, so a follow-up round doesn't ask for them again straight away.
  syncLayers(skip = new Set()) {
    const inView = this.feedsNear(0)
    const viewKey = inView.join(",")
    if (viewKey !== this.reportedView) {
      this.reportedView = viewKey
      this.pushEvent("view", {feeds: inView})
    }

    const missing = this.wantedKeys().filter((key) => !this.feedData.has(key) && !skip.has(key))

    this.el.dataset.transitReady = "false"
    this.el.dataset.mapIdle = "false"
    const batch = ++this.dataLoadBatch
    this.startDataLoading(batch, missing)
    this.render()

    const loads = missing.map((key) =>
      this.loadFeed(key).then(() => {
        this.advanceDataLoading(batch, key)
        this.scheduleRender()
      })
    )

    Promise.allSettled(loads).then((results) => {
      this.render()
      if (batch !== this.dataLoadBatch) return

      const failed = new Set([...skip, ...missing.filter((_key, index) => results[index].status === "rejected")])

      // Probes that landed may call for sharper lines: load those as the
      // next round rather than calling the view loaded.
      if (this.wantedKeys().some((key) => !this.feedData.has(key) && !failed.has(key))) {
        this.syncLayers(failed)
        return
      }

      clearTimeout(this.loadingTimer)
      this.dataLoading = false
      this.el.dataset.mapIdle = "false"
      this.el.dataset.transitReady = failed.size === 0 ? "true" : "error"

      // What did load stays on the map; what didn't is named in a notice
      // over it, with a retry that asks only for the missing layers.
      if (this.styleReady) this.hideLoading()
      if (failed.size > 0) {
        this.showMapNotice(
          `${failed.size} transit ${failed.size === 1 ? "layer" : "layers"} failed to load.`,
          () => this.syncLayers()
        )
      } else {
        this.hideMapNotice()
      }
      if (this.map.loaded()) this.announceIdle()
      this.openPendingStation(true)
    })
  },

  // Opens the searched-for station's details once it is drawn: the nearest
  // station within half a kilometre of where the search placed it. If the
  // view has finished loading without it (its agency or mode is switched
  // off), the details say only its name.
  openPendingStation(settled = false) {
    const pending = this.pendingStation
    if (!pending || this.map.isMoving() || this.map.getZoom() < STOPS_MIN_ZOOM) return

    const [kx, ky] = kmScale(pending.lat)
    const near = (this.stationFeatures || [])
      .map((feature) => {
        const [lng, lat] = feature.geometry.coordinates
        return {feature, km: Math.hypot((lng - pending.lng) * kx, (lat - pending.lat) * ky)}
      })
      .filter(({km}) => km <= 0.5)
      .sort((a, b) => a.km - b.km)[0]

    if (near) {
      this.pendingStation = null
      const [lng, lat] = near.feature.geometry.coordinates
      this.openPopup({lng, lat}, this.stationPopupHtml(near.feature.properties), () => this.clearFocus())
      this.bindRouteBadges()
    } else if (settled && !this.dataLoading) {
      this.pendingStation = null
      this.openPopup(
        {lng: pending.lng, lat: pending.lat},
        `<div class="tm-popup"><div class="tm-popup-header">` +
          `<div class="tm-popup-title">${this.escapeHtml(pending.name)}</div></div>` +
          `<p class="tm-popup-empty">No lines to show here. Its agency or mode may be switched off in Filters.</p></div>`
      )
    }
  },

  // What the view needs: each drawn agency's enabled modes, as lines at the
  // zoom's detail, and their stations once they can be drawn.
  // Keys are "feedId:mode:part" for low-detail lines, and
  // "feedId:mode:part:x,y" for a cell of mid or full lines or of stations.
  // An agency is asked only for the modes it runs.
  wantedKeys() {
    const zoom = this.map.getZoom()
    const detail = detailForZoom(zoom)
    const view = this.viewBox(LOAD_PADDING)

    return this.activeFeeds().flatMap((id) => {
      const feed = this.feeds.find((candidate) => candidate.id === id)
      return this.modesOf(feed).flatMap((cat) => {
        if (detail === "low") return [`${id}:${cat}:low`]

        const lines = cellsFor(detail, view, feed.bounds).map((cell) => `${id}:${cat}:${detail}:${cell}`)
        const stops =
          zoom >= STOPS_MIN_ZOOM ? cellsFor("stops", view, feed.bounds).map((cell) => `${id}:${cat}:stops:${cell}`) : []
        return [...lines, ...stops]
      })
    })
  },

  modesOf(feed) {
    return MODE_ORDER.filter((cat) => this.enabled.has(cat) && (!feed?.counts || (feed.counts[cat] || 0) > 0))
  },

  // The loaded keys of an agency's mode drawn as its lines: the view's own
  // cells once any has landed; until then whatever lines are already here,
  // so lines don't blink out while sharper ones arrive.
  lineKeys(id, cat, wanted) {
    const prefix = `${id}:${cat}:`
    const loaded = (key) => this.feedData.has(key)
    const own = wanted.filter((key) => key.startsWith(prefix) && !key.includes(":stops:") && loaded(key))
    if (own.length > 0) return own

    return [...this.feedData.keys()].filter((key) => key.startsWith(prefix) && !key.includes(":stops"))
  },

  lines(id, cat, wanted = this.wantedKeys()) {
    return this.lineKeys(id, cat, wanted).flatMap((key) => this.feedData.get(key).features)
  },

  // Lets go of everything the view does not draw: agencies out of range or
  // hidden, modes switched off, cells out of view, stations below their
  // zoom, and coarser lines once the view's own have landed. Panning across
  // a continent would otherwise keep every network it passed in memory.
  pruneFeedData(keep) {
    for (const key of this.feedData.keys()) {
      if (!keep.has(key)) this.feedData.delete(key)
    }
  },

  async loadFeed(key) {
    if (this.pending.has(key)) return this.pending.get(key)

    const [feedId, cat, part, cell] = key.split(":")
    const query = `feed=${feedId}&cats=${encodeURIComponent(cat)}${cell ? `&cell=${cell}` : ""}`
    const url = part === "stops" ? `/api/stops.geojson?${query}` : `/api/routes.geojson?${query}&detail=${part}`

    // A server error is often a first build of a big agency running long
    // while others build too, so one retry follows a short wait.
    const request = (async () => {
      let response = await fetch(url).catch(() => null)
      if (!response?.ok) {
        await new Promise((resolve) => setTimeout(resolve, 2000))
        response = await fetch(url)
      }
      if (!response.ok) throw new Error(`Could not load ${key}`)
      this.feedData.set(key, await response.json())
    })()

    this.pending.set(key, request)

    try {
      await request
    } catch (error) {
      console.error(`Unable to load transit data for ${key}:`, error)
      throw error
    } finally {
      this.pending.delete(key)
    }
  },

  // Draws every enabled mode from the active agencies' data: their lines
  // side by side, and their stations merged across agencies so a shared
  // interchange is one marker. Redrawing is skipped while nothing it depends
  // on has changed, since a pan alone must not re-tessellate a country.
  render() {
    if (!this.styleReady) return

    const active = this.activeFeeds()
    const wanted = this.wantedKeys()
    const drawn = active.flatMap((id) => MODE_ORDER.filter((cat) => this.enabled.has(cat)).map((cat) => [id, cat]))
    const lineKeys = drawn.flatMap(([id, cat]) => this.lineKeys(id, cat, wanted))
    const stopKeys = wanted.filter((key) => key.includes(":stops:") && this.feedData.has(key))
    this.pruneFeedData(new Set([...lineKeys, ...stopKeys]))
    const renderKey = [...lineKeys, ...stopKeys].join(",")

    if (renderKey !== this.renderedKey) {
      this.renderedKey = renderKey
      const stopsByCategory = this.mergedStops(stopKeys)
      this.stationFeatures = [...new Set([...stopsByCategory.values()].flat())]

      let drawnLines = 0
      MODE_ORDER.filter((cat) => this.enabled.has(cat)).forEach((cat) => {
        const routes = {
          type: "FeatureCollection",
          features: active.flatMap((id) => this.lines(id, cat, wanted)),
        }
        drawnLines += routes.features.length
        const stops = {type: "FeatureCollection", features: stopsByCategory.get(cat) || []}

        if (this.map.getSource(`${cat}-routes`)) {
          this.map.getSource(`${cat}-routes`).setData(routes)
          this.map.getSource(`${cat}-stops`).setData(stops)
        } else {
          this.map.addSource(`${cat}-routes`, {type: "geojson", data: routes})
          this.map.addSource(`${cat}-stops`, {type: "geojson", data: stops})
          this.addCategoryLayers(cat)
          this.loaded.add(cat)
        }
      })
      // How many lines the map hands MapLibre, for tests to read.
      this.el.dataset.drawnLines = String(drawnLines)
    }

    MODE_ORDER.forEach((cat) => (this.enabled.has(cat) ? this.setCategoryVisibility(cat) : this.hideCategory(cat)))
    this.openPendingStation()
    this.applyFocus()
  },

  // -- focusing a line ---------------------------------------------------------

  // Clicking a line picks it out: it is drawn again on top, wider and cased
  // in white, every other line fades back, and the map frames all of it. The
  // line is found by what it is (mode, operator, name, colour) in every loaded
  // agency, so the whole line is framed, not just the tiles on screen.
  focusLine(props) {
    const line = {agency: props.agency ?? null, name: props.name ?? null, color: props.color ?? null}
    this.focusFirstMatch(props.category, [line])
  },

  // A station lists routes, and the map draws lines that may group several
  // (New York's Q is drawn as the yellow "N Q R W"), so a route picked there
  // is matched by name and colour, else by its operator's line of that
  // colour, else by name alone. Returns whether anything matched.
  focusRoute({category, agency, name, color}) {
    return this.focusFirstMatch(category, [{agency, name, color}, {agency, color}, {agency, name}])
  },

  focusFirstMatch(category, candidates) {
    const match = candidates
      .map((fields) => ({category, fields}))
      .find((focus) => this.featuresMatching(focus).length > 0)

    if (!match) return false
    this.focus = match
    const features = this.featuresMatching(match)
    this.applyFocus()

    const bounds = new maplibregl.LngLatBounds()
    features.forEach((feature) =>
      feature.geometry.coordinates.forEach((line) => line.forEach((point) => bounds.extend(point)))
    )

    if (!bounds.isEmpty()) {
      this.map.fitBounds(bounds, {padding: this.mapPadding(), maxZoom: 15, duration: 900})
    }
    return true
  },

  clearFocus() {
    if (!this.focus) return
    this.focus = null
    this.applyFocus()
  },

  focusedFeatures() {
    return this.focus ? this.featuresMatching(this.focus) : []
  },

  // Loaded lines of `category` whose properties equal every one of `fields`.
  featuresMatching({category, fields}) {
    const entries = Object.entries(fields)

    return this.activeFeeds()
      .flatMap((id) => this.lines(id, category))
      .filter(({properties}) => entries.every(([key, value]) => (properties[key] ?? null) === (value ?? null)))
  },

  // Draws the focused line (or nothing) and fades the rest to match. Run on
  // every render, so the focus follows agencies loading as the map moves.
  applyFocus() {
    if (!this.styleReady) return

    const data = {type: "FeatureCollection", features: this.focusedFeatures()}

    if (this.map.getSource(FOCUS_SOURCE_ID)) {
      this.map.getSource(FOCUS_SOURCE_ID).setData(data)
    } else {
      this.map.addSource(FOCUS_SOURCE_ID, {type: "geojson", data})
      this.addLayerInOrder({
        id: FOCUS_CASING_ID,
        type: "line",
        source: FOCUS_SOURCE_ID,
        layout: {"line-join": "round", "line-cap": "round"},
        paint: {"line-color": this.palette.background, "line-width": LINE_WIDTH + 5},
      })
      this.addLayerInOrder({
        id: FOCUS_LINE_ID,
        type: "line",
        source: FOCUS_SOURCE_ID,
        layout: {"line-join": "round", "line-cap": "round"},
        paint: {"line-color": ["get", "color"], "line-width": LINE_WIDTH + 2},
      })
    }

    const opacity = this.focus ? UNFOCUSED_OPACITY : 1
    this.loaded.forEach((cat) => {
      const ids = layerIds(cat)
      if (this.map.getLayer(ids.line)) this.map.setPaintProperty(ids.line, "line-opacity", opacity)
      if (this.map.getLayer(ids.casing)) this.map.setPaintProperty(ids.casing, "line-opacity", opacity)
      if (this.map.getLayer(ids.lineLabels)) {
        // The focused line keeps its name; the rest fade with their lines.
        this.map.setPaintProperty(
          ids.lineLabels,
          "text-opacity",
          this.focus ? ["case", this.focusMatch(), 1, UNFOCUSED_OPACITY] : 1
        )
      }
    })
  },

  focusMatch() {
    return [
      "all",
      ...Object.entries(this.focus.fields).map(([key, value]) => ["==", ["get", key], value ?? null]),
    ]
  },

  // Each agency's stations, once each (a station serving two modes arrives in
  // both modes' responses), merged across agencies and handed to every mode
  // they serve.
  mergedStops(keys) {
    const unique = new Map()

    keys.forEach((key) => {
      const feedId = key.split(":")[0]
      ;(this.feedData.get(key)?.features || []).forEach((feature) => {
        const id = `${feedId}|${feature.geometry.coordinates.join(",")}|${feature.properties.name}`
        if (!unique.has(id)) unique.set(id, feature)
      })
    })

    const byCategory = new Map()
    mergeColocatedStops([...unique.values()]).forEach((station) => {
      ;(station.properties.categories || []).forEach((cat) => {
        if (!byCategory.has(cat)) byCategory.set(cat, [])
        byCategory.get(cat).push(station)
      })
    })

    return byCategory
  },

  hideCategory(cat) {
    if (!this.loaded.has(cat)) return
    Object.values(layerIds(cat)).forEach((id) => this.setVisibility(id, "none"))
  },

  setCategoryVisibility(cat) {
    const ids = layerIds(cat)
    const visible = this.enabled.has(cat)

    this.setVisibility(ids.casing, visible ? "visible" : "none")
    this.setVisibility(ids.line, visible ? "visible" : "none")
    this.setVisibility(ids.lineLabels, visible && this.details.has("labels") ? "visible" : "none")
    this.setVisibility(ids.stops, visible && this.details.has("stops") ? "visible" : "none")
    this.setVisibility(ids.labels, visible && this.details.has("labels") ? "visible" : "none")
  },

  syncDetails() {
    this.loaded.forEach((cat) => this.setCategoryVisibility(cat))
  },

  setVisibility(id, visibility) {
    if (this.map.getLayer(id)) this.map.setLayoutProperty(id, "visibility", visibility)
  },

  addCategoryLayers(cat) {
    const ids = layerIds(cat)

    // Lines that would fade into the basemap sit on a thin outline: bright
    // ones (yellows) on the light map, dark ones on the dark map.
    this.addLayerInOrder({
      id: ids.casing,
      type: "line",
      source: `${cat}-routes`,
      filter: this.casingFilter(),
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": this.casingColor(),
        "line-width": LINE_WIDTH + 1.5,
      },
    })

    // Every line on its own centreline, one flat colour, one flat width.
    // Lines sharing track draw on top of one another; nothing separates them.
    this.addLayerInOrder({
      id: ids.line,
      type: "line",
      source: `${cat}-routes`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": ["get", "color"],
        "line-width": LINE_WIDTH,
      },
    })

    this.addLayerInOrder({
      id: ids.lineLabels,
      type: "symbol",
      source: `${cat}-routes`,
      minzoom: 10.5,
      layout: {
        "symbol-placement": "line",
        "symbol-spacing": 420,
        "text-field": ["get", "name"],
        "text-font": ["Noto Sans Regular"],
        "text-size": ["interpolate", ["linear"], ["zoom"], 10.5, 9.5, 16, 12.5],
        "text-letter-spacing": -0.01,
        "text-padding": 4,
        "text-optional": true,
      },
      paint: {
        "text-color": this.lineLabelColor(),
        "text-halo-color": withAlpha(this.palette.background, 0.96),
        "text-halo-width": 1.8,
        "text-halo-blur": 0.3,
      },
    })

    this.addLayerInOrder({
      id: ids.stops,
      type: "circle",
      source: `${cat}-stops`,
      // Stations wait for a neighbourhood-level view (fading in from 10.5 to
      // 11); further out they only crowd the lines. Other stops wait for 13.
      minzoom: 10.5,
      paint: {
        "circle-color": this.palette.background,
        "circle-stroke-color": this.palette.muted,
        // Scaled by how many services meet at the stop, so a six-line
        // interchange reads as a landmark and a single-line halt stays a dot.
        // Below zoom 13 stations sit only a few pixels apart, so the markers
        // (radius and ring alike) shrink to stay separate small rings on the
        // line rather than running together into a chain.
        "circle-radius": byZoomAndInterchange(
          [
            [10, 1.4],
            [12, 3],
            [13, 4.5],
            [15, 5.8],
            [17, 7],
            [19, 8.5],
          ],
          1.5
        ),
        "circle-stroke-width": byZoomAndInterchange(
          [
            [10, 0.65],
            [12, 1],
          ].map(([zoom, factor]) => [zoom, ["*", factor, ["case", ["get", "station"], 1.7, 1.05]]]),
          1.35
        ),
        "circle-opacity": stopOpacity,
        "circle-stroke-opacity": stopOpacity,
      },
    })

    this.addLayerInOrder({
      id: ids.labels,
      type: "symbol",
      source: `${cat}-stops`,
      minzoom: 11,
      filter: ["==", ["get", "station"], true],
      layout: {
        "text-field": ["get", "name"],
        "text-font": ["Noto Sans Regular"],
        "text-size": byZoomAndInterchange(
          [
            [8, 9.5],
            [12, 11.5],
            [16, 13.5],
          ],
          1.12
        ),
        "text-anchor": "top",
        // Offset with the marker, so a big interchange's name clears its
        // larger dot instead of sitting on top of it.
        "text-offset": ["literal", [0, 0.78]],
        "text-max-width": 12,
        "text-padding": 3,
        "text-optional": true,
        // Busiest interchange first: when names compete for room, the place
        // people actually change at is the one that keeps its label.
        "symbol-sort-key": ["-", 0, ["coalesce", ["get", "interchange"], 1]],
      },
      paint: {
        "text-color": this.palette.muted,
        "text-halo-color": withAlpha(this.palette.background, 0.96),
        "text-halo-width": 1.7,
        "text-halo-blur": 0.35,
      },
    })

    this.bindPopups(cat)
  },

  casingFilter() {
    return this.palette.dark ? DARK_LINE : ["==", ["get", "light"], true]
  },

  casingColor() {
    return withAlpha(this.palette.foreground, 0.45)
  },

  // A line's name is written in its colour, unless that colour would vanish
  // on the dark map; then it is written in the foreground colour.
  lineLabelColor() {
    return this.palette.dark ? ["case", DARK_LINE, this.palette.foreground, ["get", "color"]] : ["get", "color"]
  },

  // Repaints a mode's layers from the current palette.
  paintCategory(cat) {
    const ids = layerIds(cat)
    const halo = withAlpha(this.palette.background, 0.96)

    if (this.map.getLayer(ids.casing)) this.map.setFilter(ids.casing, this.casingFilter())
    this.setPaint(ids.casing, "line-color", this.casingColor())
    this.setPaint(ids.lineLabels, "text-color", this.lineLabelColor())
    this.setPaint(ids.lineLabels, "text-halo-color", halo)
    this.setPaint(ids.stops, "circle-color", this.palette.background)
    this.setPaint(ids.stops, "circle-stroke-color", this.palette.muted)
    this.setPaint(ids.labels, "text-color", this.palette.muted)
    this.setPaint(ids.labels, "text-halo-color", halo)
  },

  // Lines go under the basemap's place names, as on a printed transit map,
  // so "Manchester" stays readable where a dozen lines meet; their own
  // names, the stations and the station names stay on top of everything.
  addLayerInOrder(layer) {
    const order = desiredLayerOrder()
    const isLine = (id) => this.map.getLayer(id)?.type === "line"
    const beforeId =
      order
        .slice(order.indexOf(layer.id) + 1)
        .find((id) => this.map.getLayer(id) && (layer.type !== "line" || isLine(id))) ??
      (layer.type === "line" ? this.basemapLabelsId : undefined)
    this.map.addLayer(layer, beforeId)
  },

  bindPopups(cat) {
    const ids = layerIds(cat)
    const setPointer = (on) => () => (this.map.getCanvas().style.cursor = on ? "pointer" : "")
    ;[ids.stops, ids.line].forEach((id) => {
      this.map.on("mouseenter", id, setPointer(true))
      this.map.on("mouseleave", id, setPointer(false))
    })
  },

  // A station's line badges focus their line on the map; the popup stays
  // open, with the picked badge marked.
  bindRouteBadges() {
    const element = this.popupElement()
    if (!element) return

    element.querySelectorAll("[data-focus-route]").forEach((badge) => {
      badge.addEventListener("click", (event) => {
        event.stopPropagation()
        const route = JSON.parse(badge.dataset.focusRoute)
        if (this.focusRoute(route)) {
          element.querySelectorAll("[data-focus-route]").forEach((other) =>
            other.setAttribute("aria-pressed", String(other === badge))
          )
        }
      })
    })
  },

  stationPopupHtml(props) {
    const lines = typeof props.lines === "string" ? JSON.parse(props.lines) : props.lines || []
    const fallback = this.stationFallbackCategory(props)
    const groups = this.stationModeGroups(lines, fallback)
    const lineTotal = groups.reduce((sum, group) => sum + group.lines.length, 0)
    const sep = `<span class="ui-sep">·</span>`

    const meta = groups.length
      ? `<div class="tm-popup-meta"><span>${lineTotal} ${lineTotal === 1 ? "line" : "lines"}` +
        `${sep}${groups.length} ${groups.length === 1 ? "mode" : "modes"}</span></div>`
      : ""

    const body = groups.length
      ? `<div class="tm-popup-body">${groups
          .map((group) => {
            const operator = this.sharedOperator(group.lines)
            const operatorHtml = operator
              ? `<span class="tm-popup-operator ui-truncate" title="${this.escapeHtml(operator)}">` +
                `${this.escapeHtml(operator)}</span>`
              : ""
            return (
              `<section class="tm-popup-mode">` +
              `<header class="tm-popup-mode-head">` +
              this.swatchHtml(group.color) +
              `<span class="ui-label">${this.escapeHtml(group.label)}</span>` +
              operatorHtml +
              `<span class="tm-popup-count ui-mono">${group.lines.length}</span>` +
              `</header>` +
              `<div class="tm-popup-lines">${group.lines
                .map(
                  (line) =>
                    `<button type="button" class="ui-chip" aria-pressed="false"` +
                    ` data-focus-route="${this.escapeHtml(JSON.stringify(line.route))}"` +
                    ` title="Show the ${this.escapeHtml(line.label)} line on the map">` +
                    `${this.swatchHtml(line.color)}<span class="ui-truncate">${this.escapeHtml(line.label)}</span></button>`
                )
                .join("")}</div>` +
              `</section>`
            )
          })
          .join("")}</div>`
      : `<p class="tm-popup-empty">No lines listed for this stop.</p>`

    return (
      `<div class="tm-popup">` +
      `<div class="tm-popup-header">` +
      `<div class="tm-popup-title">${this.escapeHtml(props.name || "Stop")}</div>` +
      meta +
      `</div>${body}</div>`
    )
  },

  // A colour from the data, shown as a swatch beside its name (DESIGN.md
  // section 3.6). It never colours text or chrome.
  // A short stroke for a line or a mode, a dot for a place: the marks the
  // menu's legend uses.
  swatchHtml(color, mark = "line") {
    return `<span class="tm-swatch-${mark}" style="--swatch: ${this.safeColor(color)}" aria-hidden="true"></span>`
  },

  // Flies to the visitor's location. The button says it is working while
  // the browser looks, and a failure says why rather than doing nothing.
  locateUser() {
    const button = document.getElementById("map-locate")

    if (!navigator.geolocation) {
      this.showMapNotice("This browser cannot share its location.")
      return
    }

    const settle = () => {
      if (!button) return
      button.disabled = false
      button.removeAttribute("aria-busy")
      button.setAttribute("aria-label", "Go to my location")
    }

    if (button) {
      button.disabled = true
      button.setAttribute("aria-busy", "true")
      button.setAttribute("aria-label", "Finding your location…")
    }

    navigator.geolocation.getCurrentPosition(
      ({coords}) => {
        settle()
        this.hideMapNotice()
        const lngLat = [coords.longitude, coords.latitude]

        if (!this.userMarker) {
          const marker = document.createElement("div")
          marker.className = "user-location-dot"
          marker.setAttribute("aria-label", "Your location")
          this.userMarker = new maplibregl.Marker({element: marker}).setLngLat(lngLat).addTo(this.map)
        } else {
          this.userMarker.setLngLat(lngLat)
        }

        this.map.flyTo({center: lngLat, zoom: Math.max(this.map.getZoom(), 13), duration: 850})
      },
      (error) => {
        settle()
        const reason =
          error.code === error.PERMISSION_DENIED
            ? "Location is blocked for this site. Allow it in the browser's settings to use it."
            : error.code === error.TIMEOUT
              ? "Finding your location took too long."
              : "Your location could not be found."
        // Retrying cannot get past a block; only the browser's settings can.
        this.showMapNotice(reason, error.code === error.PERMISSION_DENIED ? null : () => this.locateUser())
      },
      {enableHighAccuracy: true, timeout: 10000, maximumAge: 60000}
    )
  },

  // Details of what was clicked: a popup at the point on a wide screen, a
  // panel along the bottom of the map on a phone, where a popup would run
  // off the edge.
  openPopup(lngLat, html, onClose) {
    this.closePopup()
    this.popupOnClose = onClose

    if (this.narrow()) {
      const panel = this.el.querySelector("[data-map-detail]")
      panel.querySelector("[data-map-detail-body]").innerHTML = html
      panel.hidden = false
      panel.scrollTop = 0
      // The panel has no tip pointing at what it describes, so a ring marks it.
      const ring = document.createElement("div")
      ring.className = "tm-selected"
      this.selectedMarker = new maplibregl.Marker({element: ring}).setLngLat(lngLat).addTo(this.map)
      return
    }

    this.popup = new maplibregl.Popup({closeButton: true, closeOnClick: false, maxWidth: "288px"})
      .setLngLat(lngLat)
      .setHTML(html)
      .addTo(this.map)
    this.popup.on("close", () => this.closePopup())
  },

  closePopup() {
    const onClose = this.popupOnClose
    this.popupOnClose = null

    if (this.popup) {
      const popup = this.popup
      this.popup = null
      popup.remove()
    }

    this.selectedMarker?.remove()
    this.selectedMarker = null

    const panel = this.el.querySelector("[data-map-detail]")
    if (panel && !panel.hidden) {
      panel.hidden = true
      panel.querySelector("[data-map-detail-body]").innerHTML = ""
    }

    if (onClose) onClose()
  },

  popupElement() {
    return this.popup ? this.popup.getElement() : this.el.querySelector("[data-map-detail]:not([hidden])")
  },

  narrow() {
    return window.matchMedia("(max-width: 640px)").matches
  },

  escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, (char) =>
      ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[char]
    )
  },

  safeColor(value) {
    return /^#[0-9a-f]{6}$/i.test(value || "") ? value : "#6e6e73"
  },

  // A stop's single category when it only serves one mode, so fixture and
  // legacy lines that omit their own `category` still land in a named group.
  stationFallbackCategory(props) {
    const raw = props.categories
    const categories = typeof raw === "string" ? this.safeParse(raw, []) : raw || []
    return categories.length === 1 ? categories[0] : "other"
  },

  safeParse(value, fallback) {
    try {
      return JSON.parse(value)
    } catch (_error) {
      return fallback
    }
  },

  // Group a station's lines by transit mode (the way a passenger reads an
  // interchange), de-duplicating repeated lines and ordering modes by
  // STATION_MODE_ORDER, with each line sorted naturally within its mode.
  stationModeGroups(lines, fallbackCategory) {
    const groups = new Map()

    lines.forEach((line) => {
      const label = line.name || line.agency
      if (!label) return

      const category = line.category || fallbackCategory || "other"
      const agency = line.agency && line.agency !== label ? line.agency : null
      const group = groups.get(category) || {category, lines: [], seen: new Set()}

      const key = `${label}::${agency || ""}`
      if (group.seen.has(key)) return
      group.seen.add(key)
      group.lines.push({label, agency, color: line.color, route: {category, agency: line.agency ?? null, name: line.name ?? null, color: line.color ?? null}})
      groups.set(category, group)
    })

    return [...groups.values()]
      .sort((a, b) => modeRank(a.category) - modeRank(b.category) || a.category.localeCompare(b.category))
      .map((group) => ({
        category: group.category,
        label: MODE_LABEL[group.category] || titleCase(group.category),
        color: MODE_COLOR[group.category] || "#6e6e73",
        lines: group.lines.sort((a, b) =>
          a.label.localeCompare(b.label, undefined, {numeric: true, sensitivity: "base"})
        ),
      }))
  },

  // The operator to caption a mode group with — only when every line in the
  // group shares one, so the header stays quiet at mixed-operator stations.
  sharedOperator(lines) {
    const agencies = new Set(lines.map((line) => line.agency).filter(Boolean))
    return agencies.size === 1 ? [...agencies][0] : null
  },
}

export default TransitMap
