import maplibregl from "../vendor/maplibre-gl"
import {
  PLACES_LAYER_ID,
  groupForClass,
  placeFilter,
  placeLayer,
  placePinId,
  placeSubtitle,
  renderPlacePin,
} from "./map_places"

const TILE_UPSTREAM = "https://tiles.openfreemap.org"
const tileProxyUrl = (path) => `${location.origin}/tiles${path}`
const BASEMAP_STYLE = tileProxyUrl("/styles/positron")

const routeThroughProxy = (url) =>
  url.startsWith(TILE_UPSTREAM) ? {url: tileProxyUrl(url.slice(TILE_UPSTREAM.length))} : {url}

const REGIONS = {
  "great-britain": {
    center: [-2.0, 53.8],
    zoom: 5.5,
    bounds: [[-8.8, 49.7], [2.1, 59.2]],
  },
  "northeast-corridor": {
    center: [-74.1, 40.2],
    zoom: 6.4,
    bounds: [[-77.25, 38.75], [-70.75, 42.55]],
  },
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
const LINE_WIDTH = {metro: 3.2, tram: 2.6, intercity: 2.8, rail: 2.35, bus: 1.55, coach: 1.55, ferry: 1.8}

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

// Optional "live train traffic": animated markers glide along the drawn
// track geometry of the rail-family modes. Positions are simulated from the
// served line shapes (the importer is schedule-free), giving a lively sense
// of movement without any external realtime feed.
const RAIL_TRAFFIC_MODES = ["metro", "tram", "rail", "intercity"]
const MAX_TRAINS = 140
// Latitude-corrected degrees per second; each train varies around this base.
const TRAIN_SPEED = 0.008
const MIN_TRAIN_LINE = 0.004
const TRAIN_LAYERS = ["live-trains-glow", "live-trains-dot"]

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

// Ribbon rendering: a run of track arrives as one line carrying the colours of
// every service on it, and is drawn as a single thicker line divided into a
// band per colour. One white casing spans the whole ribbon, and each band is
// drawn narrower than its share of the width, so the casing shows through
// between the bands and keeps them apart.
//
// Widths are in screen pixels, so a ribbon holds its proportions at any zoom
// rather than collapsing the way baked ground-metre offsets do.
// Enough bands for the busiest trunk route. The East Coast Main Line runs ten
// operators over one pair of tracks, and a band past this cap is simply never
// drawn — the operator vanishes from the ribbon with nothing to show for it.
const MAX_STRIPES = 12

// Spacing between band centres. It falls to nothing by the country zooms: a
// ribbon held open there would be a wide white casing carrying hairline
// colours across thousands of short segments, which reads as a dashed line
// rather than a railway. Closed up, the bands sit on one centreline and a
// corridor draws as the single line it looks like from that far out.
const STRIPE_PITCH = [
  [6, 0],
  [9, 0.8],
  [11, 2.4],
  [13, 4.2],
  [16, 6],
  [19, 7.5],
]

// Band thickness is set apart from the pitch, so bands stay drawable at the
// zooms where the pitch has closed to nothing.
const STRIPE_WIDTH = [
  [6, 1.3],
  [11, 2],
  [14, 3.2],
  [19, 4.6],
]
const RIBBON_EDGE = 1.4

const ribbonLayerIds = (cat) => ({
  casing: `${cat}-ribbon-casing`,
})

// Bundle rendering: a line is served once per run of track it holds one place
// along, carrying that place as a signed `slot`. The sideways shift is applied
// here, in screen pixels, so a corridor keeps its shape at every zoom — the
// one thing a shift baked into the served coordinates can never do, since the
// ground distance that reads correctly at z15 is a third of a pixel at z10 and
// fifty pixels at z19.
//
// The pitch between neighbours is the drawn width plus a casing's worth of
// white, and it closes to nothing by the country zooms, where a corridor
// should read as the single line it looks like from that far out.
const WIDTH_STOPS = [[4, 0.48], [7, 0.68], [10, 1], [14, 1.72], [17, 1.9]]
const OFFSET_FADE_STOPS = [[4, 0], [8, 0], [10, 0.35], [12, 0.7], [14, 1]]
const OFFSET_ZOOMS = [4, 7, 8, 10, 12, 14, 17, 19]
const OFFSET_GAP = 1.6

// Piecewise-linear read of a `[[zoom, value], …]` curve, clamped at both ends.
const valueAt = (stops, zoom) => {
  const [firstZoom, firstValue] = stops[0]
  if (zoom <= firstZoom) return firstValue

  for (let i = 1; i < stops.length; i++) {
    const [z0, v0] = stops[i - 1]
    const [z1, v1] = stops[i]
    if (zoom <= z1) return v0 + ((v1 - v0) * (zoom - z0)) / (z1 - z0)
  }

  return stops[stops.length - 1][1]
}

const offsetPitch = (base) =>
  OFFSET_ZOOMS.map((zoom) => [
    zoom,
    valueAt(OFFSET_FADE_STOPS, zoom) * (valueAt(WIDTH_STOPS, zoom) * base * 1.15 + OFFSET_GAP),
  ])

// Zoom has to be the input of a top-level interpolate, so anything varying by
// feature is applied to each zoom stop's output rather than wrapping it.
const byZoom = (stops, transform = (value) => value) => [
  "interpolate",
  ["linear"],
  ["zoom"],
  ...stops.flatMap(([zoom, value]) => [zoom, transform(value)]),
]

// Band i sits i places across a ribbon `stripes` wide, measured from its
// centre: with three bands the offsets are -1, 0 and +1 pitches.
const stripeOffset = (index) =>
  byZoom(STRIPE_PITCH, (pitch) => [
    "*",
    pitch,
    ["-", index, ["/", ["-", ["get", "stripes"], 1], 2]],
  ])

const stripeLayerId = (cat, index) => `${cat}-ribbon-stripe-${index}`

// Responses cached before slots were served carry none, so those lines fall
// back to the corridor centreline rather than failing to draw at all.
const lineOffset = (base) =>
  byZoom(offsetPitch(base), (pitch) => ["*", pitch, ["coalesce", ["get", "slot"], 0]])

const layerIds = (cat) => ({
  casing: `${cat}-casing`,
  line: `${cat}-line`,
  lineLabels: `${cat}-line-labels`,
  stops: `${cat}-stops`,
  labels: `${cat}-station-labels`,
})

// All casings render below all coloured lines, so in a mixed-mode bundle
// (a tube line running beside national rail) one mode's white casing can
// never cut into a neighbouring mode's line.
const desiredLayerOrder = () =>
  MODE_ORDER.map((cat) => ribbonLayerIds(cat).casing).concat(
    MODE_ORDER.map((cat) => layerIds(cat).casing),
    MODE_ORDER.flatMap((cat) =>
      Array.from({length: MAX_STRIPES}, (_, index) => stripeLayerId(cat, index))
    ),
    MODE_ORDER.map((cat) => layerIds(cat).line),
    MODE_ORDER.map((cat) => layerIds(cat).lineLabels),
    MODE_ORDER.map((cat) => layerIds(cat).stops),
    MODE_ORDER.map((cat) => layerIds(cat).labels)
  )

const TransitMap = {
  mounted() {
    this.loaded = new Set()
    this.pending = new Map()
    this.categoryData = new Map()
    this.dataLoadBatch = 0
    this.dataLoading = false
    this.enabled = new Set(this.parseData("enabled", []))
    this.details = new Set(this.parseData("details", ["labels", "stops"]))
    this.places = new Set(this.parseData("places", []))
    this.placeCatalog = this.parseData("placeCatalog", [])
    this.liveTraffic = this.el.dataset.liveTraffic === "true"
    this.trains = []
    this.trainFrame = null
    this.trainLastTs = 0
    this.region = this.el.dataset.region || "great-britain"
    this.root = this.el.closest("#transit-explorer")
    const initialView = REGIONS[this.region] || REGIONS["great-britain"]

    try {
      this.map = new maplibregl.Map({
        container: this.el,
        style: BASEMAP_STYLE,
        center: initialView.center,
        zoom: initialView.zoom,
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
    this.map.on("style.load", () => {
      this.applyAppleBasemap()
      // Places are added before any transit layer exists, which leaves every
      // pin below the lines and stations the map is actually about.
      this.addPlaceLayers()
      this.syncLayers()
    })
    this.map.on("load", () => this.markMapReady())
    this.map.on("zoom", () => this.updateZoomReadout())
    this.map.on("idle", () => this.announceIdle())

    this.handleEvent("categories-changed", ({enabled}) => {
      this.enabled = new Set(enabled)
      if (this.map.isStyleLoaded()) this.syncLayers()
    })
    this.handleEvent("details-changed", ({enabled}) => {
      this.details = new Set(enabled)
      this.syncDetails()
    })
    this.handleEvent("places-changed", ({enabled}) => {
      this.places = new Set(enabled)
      this.syncPlaces()
    })
    this.handleEvent("live-traffic-changed", ({enabled}) => this.setLiveTraffic(enabled))
    this.handleEvent("map-region", ({region}) => this.showRegion(region))
    this.handleEvent("map-search", ({query}) => this.searchStop(query))

    this.zoomInHandler = () => this.map.easeTo({zoom: this.map.getZoom() + 1, duration: 300})
    this.zoomOutHandler = () => this.map.easeTo({zoom: this.map.getZoom() - 1, duration: 300})
    this.locateHandler = () => this.locateUser()
    this.setZoomHandler = (event) => {
      const zoom = Number(event.detail?.zoom)
      const center = event.detail?.center
      if (Number.isFinite(zoom)) this.map.jumpTo({zoom, ...(Array.isArray(center) ? {center} : {})})
    }

    this.el.addEventListener("map:zoom-in", this.zoomInHandler)
    this.el.addEventListener("map:zoom-out", this.zoomOutHandler)
    this.el.addEventListener("map:locate", this.locateHandler)
    this.el.addEventListener("map:set-zoom", this.setZoomHandler)
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
      `<div class="grid h-full place-items-center bg-[#f3f2ee] p-8 text-center">` +
      `<div><strong class="text-sm text-[#3a3a3c]">The map could not be loaded</strong>` +
      `<p class="mt-1 text-xs text-[#77777c]">${this.escapeHtml(error.message)}</p></div></div>`
  },

  markMapReady() {
    this.el.dataset.mapReady = "true"
    if (!this.dataLoading && this.el.dataset.transitReady !== "error") this.hideLoading()
    this.updateZoomReadout()
  },

  showLoading(label, detail, progress = null) {
    const loading = this.el.querySelector(".map-loading")
    if (!loading) return

    const labelEl = loading.querySelector("[data-loading-label]")
    const detailEl = loading.querySelector("[data-loading-detail]")
    const progressEl = loading.querySelector("[data-loading-progress]")
    const barEl = loading.querySelector("[data-loading-bar]")

    loading.hidden = false
    if (labelEl) labelEl.textContent = label
    if (detailEl) detailEl.textContent = detail

    if (progressEl && barEl) {
      if (progress === null) {
        progressEl.removeAttribute("aria-valuenow")
        barEl.classList.add("map-loading__bar--indeterminate")
        barEl.style.width = ""
      } else {
        const value = Math.max(0, Math.min(100, Math.round(progress)))
        progressEl.setAttribute("aria-valuenow", String(value))
        barEl.classList.remove("map-loading__bar--indeterminate")
        barEl.style.width = `${value}%`
      }
    }
  },

  hideLoading() {
    const loading = this.el.querySelector(".map-loading")
    if (loading) loading.hidden = true
  },

  startDataLoading(batch, categories) {
    this.dataLoading = categories.length > 0
    this.dataLoadProgress = {batch, categories: new Set(categories), complete: new Set()}

    if (this.dataLoading) {
      this.showLoading(
        "Loading transit data",
        `Preparing 0 of ${categories.length} layers`,
        0
      )
    }
  },

  advanceDataLoading(batch, category) {
    const progress = this.dataLoadProgress
    if (!progress || progress.batch !== batch || !progress.categories.has(category)) return

    progress.complete.add(category)
    const complete = progress.complete.size
    const total = progress.categories.size
    const label = MODE_LABEL[category] || category
    this.showLoading(
      "Loading transit data",
      `${label} ready · ${complete} of ${total} layers`,
      (complete / total) * 100
    )
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

  showRegion(region) {
    const view = REGIONS[region]
    if (!view) return

    this.region = region
    this.map.fitBounds(view.bounds, {
      padding: this.mapPadding(),
      duration: 900,
      essential: true,
    })
  },

  mapPadding() {
    if (window.matchMedia("(min-width: 640px)").matches) {
      return {top: 56, right: 56, bottom: 56, left: 352}
    }

    return {top: 64, right: 28, bottom: Math.round(window.innerHeight * 0.44), left: 28}
  },

  destroyed() {
    this.stopTrainLoop()
    this.el.removeEventListener("map:zoom-in", this.zoomInHandler)
    this.el.removeEventListener("map:zoom-out", this.zoomOutHandler)
    this.el.removeEventListener("map:locate", this.locateHandler)
    this.el.removeEventListener("map:set-zoom", this.setZoomHandler)
    if (this.map) this.map.remove()
  },

  applyAppleBasemap() {
    const fills = {
      background: "#f3f2ee",
      park: "#dcebd4",
      water: "#b9ddf3",
      landcover_ice_shelf: "#edf5f7",
      landcover_glacier: "#e8f3f5",
      landuse_residential: "#ebeae6",
      landcover_wood: "#d7e7d0",
      building: "#dddcd7",
      aeroway_area: "#e6e4df",
      road_area_pier: "#e4e2dc",
    }

    const lines = {
      waterway: "#a8d2ec",
      aeroway_taxiway: "#d3d1cb",
      aeroway_runway_casing: "#d3d1cb",
      aeroway_runway: "#f7f6f3",
      road_pier: "#d0cec8",
      highway_path: "#ffffff",
      highway_minor: "#ffffff",
      highway_major_casing: "#d5d2ca",
      highway_major_inner: "#fffdf9",
      highway_major_subtle: "#fff4ce",
      highway_motorway_casing: "#d7c986",
      highway_motorway_inner: "#ffe89a",
      highway_motorway_subtle: "#fff0b8",
      highway_motorway_bridge_casing: "#d7c986",
      highway_motorway_bridge_inner: "#ffe89a",
      tunnel_motorway_casing: "#ddd4ad",
      tunnel_motorway_inner: "#fff1bd",
      boundary_3: "#b9b8b3",
      boundary_2: "#aaa9a4",
      boundary_disputed: "#aaa9a4",
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
        this.setPaint(layer.id, "text-color", layer.id.includes("water") ? "#4f86a6" : "#656569")
        this.setPaint(layer.id, "text-halo-color", "rgba(255,255,255,0.9)")
        this.setPaint(layer.id, "text-halo-width", 1.2)
      }

      if (layer.id.startsWith("railway")) this.map.setLayoutProperty(layer.id, "visibility", "none")
    })
  },

  setPaint(layerId, property, value) {
    try {
      this.map.setPaintProperty(layerId, property, value)
    } catch (_error) {
      // Style layers vary slightly between OpenFreeMap releases.
    }
  },

  addPlaceLayers() {
    const pixelRatio = window.devicePixelRatio || 1

    this.placeCatalog.forEach(({id, color}) => {
      if (!this.map.hasImage(placePinId(id))) {
        this.map.addImage(placePinId(id), renderPlacePin(color, id, pixelRatio), {pixelRatio})
      }
    })

    this.map.addLayer(placeLayer())
    this.bindPlacePopup()
    this.syncPlaces()
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
    this.map.on("click", PLACES_LAYER_ID, (event) => {
      // Transit comes first: a pin sitting under a station marker never steals
      // the click from it.
      if (this.transitFeaturesAt(event.point).length > 0) return

      const props = event.features[0].properties
      const group = this.placeCatalog.find(({id}) => id === groupForClass(props.class))
      const subtitle = placeSubtitle(props)
      const meta = [subtitle, group?.label].filter(Boolean).join(" · ")

      this.openPopup(
        event.lngLat,
        `<div class="place-popup"><div class="place-popup__name">${this.escapeHtml(props.name)}</div>` +
          `<div class="place-popup__meta"><span class="place-popup__dot" style="background:${this.safeColor(group?.color)}"></span>` +
          `${this.escapeHtml(meta)}</div></div>`
      )
    })

    const setPointer = (on) => () => (this.map.getCanvas().style.cursor = on ? "pointer" : "")
    this.map.on("mouseenter", PLACES_LAYER_ID, setPointer(true))
    this.map.on("mouseleave", PLACES_LAYER_ID, setPointer(false))
  },

  transitFeaturesAt(point) {
    const stopLayers = MODE_ORDER.map((mode) => layerIds(mode).stops).filter((id) =>
      this.map.getLayer(id)
    )

    return stopLayers.length > 0 ? this.map.queryRenderedFeatures(point, {layers: stopLayers}) : []
  },

  syncLayers() {
    this.el.dataset.transitReady = "false"
    this.el.dataset.mapIdle = "false"
    const batch = ++this.dataLoadBatch
    const categoriesToLoad = MODE_ORDER.filter(
      (cat) => this.enabled.has(cat) && !this.loaded.has(cat)
    )
    this.startDataLoading(batch, categoriesToLoad)

    const updates = MODE_ORDER.map((cat) => {
      if (this.enabled.has(cat)) {
        return this.showCategory(cat).then(() => this.advanceDataLoading(batch, cat))
      }
      this.hideCategory(cat)
      return Promise.resolve()
    })

    Promise.allSettled(updates).then((results) => {
      if (batch !== this.dataLoadBatch) return

      const failures = results.filter((result) => result.status === "rejected")
      this.dataLoading = false
      this.el.dataset.mapIdle = "false"
      this.el.dataset.transitReady = failures.length === 0 ? "true" : "error"

      if (failures.length > 0) {
        const total = Math.max(1, this.dataLoadProgress.categories.size)
        this.showLoading(
          "Some transit data could not be loaded",
          "Reload the page to try again",
          (this.dataLoadProgress.complete.size / total) * 100
        )
      } else {
        this.showLoading("Transit data ready", "All visible layers loaded", 100)
        if (this.liveTraffic) this.refreshTrains()
        if (this.map.loaded()) this.announceIdle()
      }
    })
  },

  async showCategory(cat) {
    if (this.loaded.has(cat)) {
      this.setCategoryVisibility(cat)
      return
    }

    if (this.pending.has(cat)) return this.pending.get(cat)

    const request = this.loadCategory(cat)
    this.pending.set(cat, request)

    try {
      await request
    } finally {
      this.pending.delete(cat)
    }
  },

  async loadCategory(cat) {
    try {
      const [routeResponse, stopResponse, corridorResponse] = await Promise.all([
        fetch(`/api/routes.geojson?cats=${encodeURIComponent(cat)}`),
        fetch(`/api/stops.geojson?cats=${encodeURIComponent(cat)}`),
        fetch(`/api/corridors.geojson?cats=${encodeURIComponent(cat)}`),
      ])

      if (!routeResponse.ok || !stopResponse.ok || !corridorResponse.ok) {
        throw new Error(`Could not load ${cat} data`)
      }

      const [routes, stops, corridors] = await Promise.all([
        routeResponse.json(),
        stopResponse.json(),
        corridorResponse.json(),
      ])
      this.categoryData.set(cat, {routes, stops})

      if (!this.map.getSource(`${cat}-routes`)) {
        this.map.addSource(`${cat}-routes`, {type: "geojson", data: routes})
        this.map.addSource(`${cat}-stops`, {type: "geojson", data: stops})
        this.map.addSource(`${cat}-corridors`, {type: "geojson", data: corridors})
        this.addCategoryLayers(cat)
      }

      this.loaded.add(cat)
      this.setCategoryVisibility(cat)
    } catch (error) {
      console.error(`Unable to load ${cat} transit data:`, error)
      throw error
    }
  },

  hideCategory(cat) {
    if (!this.loaded.has(cat)) return
    Object.values(layerIds(cat)).forEach((id) => this.setVisibility(id, "none"))
    this.stripeLayerIds(cat).forEach((id) => this.setVisibility(id, "none"))
  },

  stripeLayerIds(cat) {
    return [ribbonLayerIds(cat).casing].concat(
      Array.from({length: MAX_STRIPES}, (_, index) => stripeLayerId(cat, index))
    )
  },

  addStripeLayers(cat) {
    const ids = ribbonLayerIds(cat)

    // One casing spanning the whole ribbon, so a bundle reads as a single
    // thicker line rather than as a row of separate ones.
    this.addLayerInOrder({
      id: ids.casing,
      type: "line",
      source: `${cat}-corridors`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": "rgba(255,255,255,0.96)",
        // Wide enough to hold every band plus a rim. As the pitch closes at
        // country zooms this falls back to one band's worth, so the casing
        // never outgrows the colour it is meant to be edging.
        "line-width": [
          "+",
          byZoom(STRIPE_PITCH, (pitch) => ["*", pitch, ["-", ["get", "stripes"], 1]]),
          byZoom(STRIPE_WIDTH, (width) => width + RIBBON_EDGE),
        ],
      },
    })

    for (let index = 0; index < MAX_STRIPES; index++) {
      this.addLayerInOrder({
        id: stripeLayerId(cat, index),
        type: "line",
        source: `${cat}-corridors`,
        filter: [">", ["get", "stripes"], index],
        layout: {"line-join": "round", "line-cap": "butt"},
        paint: {
          "line-color": ["to-color", ["get", `stripe_${index}`]],
          "line-width": byZoom(STRIPE_WIDTH),
          "line-offset": stripeOffset(index),
        },
      })
    }
  },

  setCategoryVisibility(cat) {
    const ids = layerIds(cat)
    const visible = this.enabled.has(cat)
    // The two renderings draw the same network, so only one may be on at a
    // time or every shared corridor would be painted twice.
    const ribbons = visible && this.details.has("ribbons")
    const lines = visible && !this.details.has("ribbons")

    const named = this.details.has("labels")

    this.stripeLayerIds(cat).forEach((id) => this.setVisibility(id, ribbons ? "visible" : "none"))

    this.setVisibility(ids.casing, lines ? "visible" : "none")
    this.setVisibility(ids.line, lines ? "visible" : "none")
    // Names come off the corridor, which both renderings draw the same way.
    this.setVisibility(ids.lineLabels, visible && named ? "visible" : "none")
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
    const width = LINE_WIDTH[cat] || 2.0
    const zoomedWidth = (base) => [
      "interpolate", ["linear"], ["zoom"],
      4, base * 0.48,
      7, base * 0.68,
      10, base,
      14, base * 1.72,
      17, base * 1.9,
    ]
    // A line arrives on the track it runs on, carrying the place it holds
    // across the corridor. The shift into that place happens here and is
    // measured in screen pixels, so a bundle opens as the map zooms in and
    // closes back onto one centreline at the country zooms — rather than
    // holding one ground distance that is right at exactly one zoom.
    const offset = lineOffset(width)

    this.addLayerInOrder({
      id: ids.casing,
      type: "line",
      source: `${cat}-routes`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": "rgba(255,255,255,0.96)",
        "line-width": zoomedWidth(width + 2.15),
        "line-offset": offset,
        "line-opacity": ["interpolate", ["linear"], ["zoom"], 4, 0.82, 8, 0.94],
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
        "line-offset": offset,
        "line-opacity": ["interpolate", ["linear"], ["zoom"], 4, 0.88, 8, 1],
      },
    })

    // Names come off the corridor, not off the lines running along it. A
    // line's drawn position is a screen-space shift that a symbol layer has
    // no way to follow, so a name placed on a line's own geometry would sit
    // tens of pixels off the line it names by z18. The corridor is the one
    // place a label can point at honestly, and it is the same geometry in
    // both renderings — so the label says who runs along here.
    this.addLayerInOrder({
      id: ids.lineLabels,
      type: "symbol",
      source: `${cat}-corridors`,
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
        "text-color": ["get", "color"],
        "text-halo-color": "rgba(255,255,255,0.96)",
        "text-halo-width": 1.8,
        "text-halo-blur": 0.3,
      },
    })

    this.addLayerInOrder({
      id: ids.stops,
      type: "circle",
      source: `${cat}-stops`,
      minzoom: 7.5,
      paint: {
        "circle-color": "#ffffff",
        "circle-stroke-color": "#4a4a4f",
        // Scaled by how many services meet at the stop, so a six-line
        // interchange reads as a landmark and a single-line halt stays a dot.
        "circle-radius": byZoomAndInterchange(
          [
            [7.5, 1.2],
            [11, 3.2],
            [15, 5.8],
            [17, 7],
            [19, 8.5],
          ],
          1.5
        ),
        "circle-stroke-width": ["*", ["case", ["get", "station"], 1.7, 1.05], interchangeScale(1.35)],
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
        "text-color": "#414145",
        "text-halo-color": "rgba(255,255,255,0.96)",
        "text-halo-width": 1.7,
        "text-halo-blur": 0.35,
      },
    })

    this.addStripeLayers(cat)
    this.bindPopups(cat)
  },

  addLayerInOrder(layer) {
    const order = desiredLayerOrder()
    const beforeId = order.slice(order.indexOf(layer.id) + 1).find((id) => this.map.getLayer(id))
    this.map.addLayer(layer, beforeId)
  },

  bindPopups(cat) {
    const ids = layerIds(cat)

    this.map.on("click", ids.stops, (event) => {
      const props = event.features[0].properties
      this.openPopup(event.lngLat, this.stationPopupHtml(props))
    })

    this.map.on("click", ids.line, (event) => {
      if (this.transitFeaturesAt(event.point).length > 0) return

      const props = event.features[0].properties
      const title = props.long_name || props.name || "Transit route"
      const agency = props.agency && props.agency !== title
        ? `<div class="map-route-popup__agency">${this.escapeHtml(props.agency)}</div>`
        : ""
      this.openPopup(
        event.lngLat,
        `<div class="map-route-popup"><div class="map-route-popup__name" style="color:${this.safeColor(props.color)}">` +
          `${this.escapeHtml(title)}</div>${agency}</div>`
      )
    })

    const setPointer = (on) => () => (this.map.getCanvas().style.cursor = on ? "pointer" : "")
    ;[ids.stops, ids.line].forEach((id) => {
      this.map.on("mouseenter", id, setPointer(true))
      this.map.on("mouseleave", id, setPointer(false))
    })
  },

  stationPopupHtml(props) {
    const lines = typeof props.lines === "string" ? JSON.parse(props.lines) : props.lines || []
    const fallback = this.stationFallbackCategory(props)
    const groups = this.stationModeGroups(lines, fallback)
    const lineTotal = groups.reduce((sum, group) => sum + group.lines.length, 0)

    const meta = groups.length
      ? `<div class="station-popup__meta">${lineTotal} ${lineTotal === 1 ? "line" : "lines"}` +
        ` · ${groups.length} ${groups.length === 1 ? "mode" : "modes"}</div>`
      : ""

    const body = groups.length
      ? `<div class="station-popup__modes">${groups
          .map((group) => {
            const operator = this.sharedOperator(group.lines)
            const operatorHtml = operator
              ? `<span class="station-popup__operator">${this.escapeHtml(operator)}</span>`
              : ""
            return (
              `<section class="station-popup__mode">` +
              `<header class="station-popup__mode-head">` +
              `<span class="station-popup__dot" style="background:${this.safeColor(group.color)}"></span>` +
              `<span class="station-popup__mode-name">${this.escapeHtml(group.label)}</span>` +
              operatorHtml +
              `<span class="station-popup__count">${group.lines.length}</span>` +
              `</header>` +
              `<div class="station-popup__badges">${group.lines
                .map(
                  (line) =>
                    `<span class="station-popup__badge" style="--line-color:${this.safeColor(line.color)}">` +
                    `${this.escapeHtml(line.label)}</span>`
                )
                .join("")}</div>` +
              `</section>`
            )
          })
          .join("")}</div>`
      : `<div class="station-popup__empty">No service information available</div>`

    return (
      `<div class="station-popup">` +
      `<div class="station-popup__header">` +
      `<div class="station-popup__title">${this.escapeHtml(props.name || "Stop")}</div>` +
      meta +
      `</div>${body}</div>`
    )
  },

  async searchStop(query) {
    await Promise.allSettled([...this.enabled].map((cat) => this.showCategory(cat)))
    const needle = String(query || "").trim().toLocaleLowerCase()
    const candidates = []

    this.categoryData.forEach(({stops}, cat) => {
      if (!this.enabled.has(cat)) return
      ;(stops.features || []).forEach((feature) => {
        const name = String(feature.properties?.name || "")
        const normalized = name.toLocaleLowerCase()
        if (!normalized.includes(needle)) return
        const score = normalized === needle ? 0 : normalized.startsWith(needle) ? 1 : 2
        candidates.push({feature, name, score})
      })
    })

    const match = candidates.sort((a, b) => a.score - b.score || a.name.localeCompare(b.name))[0]
    if (!match) {
      this.pushEvent("search-result", {found: false})
      return
    }

    const coordinates = match.feature.geometry?.coordinates
    if (!Array.isArray(coordinates)) {
      this.pushEvent("search-result", {found: false})
      return
    }

    this.map.flyTo({center: coordinates, zoom: Math.max(this.map.getZoom(), 12.5), duration: 850, essential: true})
    this.map.once("moveend", () => this.openPopup(coordinates, this.stationPopupHtml(match.feature.properties || {})))
    this.pushEvent("search-result", {found: true, name: match.name})
  },

  locateUser() {
    if (!navigator.geolocation) return

    navigator.geolocation.getCurrentPosition(
      ({coords}) => {
        const lngLat = [coords.longitude, coords.latitude]

        if (!this.userMarker) {
          const marker = document.createElement("div")
          marker.className = "user-location-dot"
          marker.setAttribute("aria-label", "Your location")
          this.userMarker = new maplibregl.Marker({element: marker}).setLngLat(lngLat).addTo(this.map)
        } else {
          this.userMarker.setLngLat(lngLat)
        }

        this.map.flyTo({center: lngLat, zoom: Math.max(this.map.getZoom(), 13), duration: 850, essential: true})
      },
      (error) => console.warn("Location unavailable:", error.message),
      {enableHighAccuracy: true, timeout: 8000, maximumAge: 60000}
    )
  },

  openPopup(lngLat, html) {
    if (this.popup) this.popup.remove()
    this.popup = new maplibregl.Popup({closeButton: true, closeOnClick: true, maxWidth: "288px"})
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
      group.lines.push({label, agency, color: line.color})
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

  setLiveTraffic(enabled) {
    this.liveTraffic = enabled

    if (enabled) {
      this.refreshTrains()
      return
    }

    this.stopTrainLoop()
    this.setTrainVisibility("none")
    this.trains = []
    this.setTrainData([])
  },

  // Rebuild the animated train set from whatever rail-family lines are
  // currently loaded and enabled, then (re)start the animation. Safe to call
  // repeatedly — on category toggles, on data load, and on enabling.
  refreshTrains() {
    if (!this.liveTraffic || !this.map || !this.map.isStyleLoaded()) return

    this.ensureTrainLayers()
    this.buildTrains()
    this.setTrainVisibility("visible")

    if (this.trains.length === 0) {
      this.stopTrainLoop()
      this.setTrainData([])
      return
    }

    this.startTrainLoop()
  },

  buildTrains() {
    const lines = []

    RAIL_TRAFFIC_MODES.forEach((cat) => {
      if (!this.enabled.has(cat)) return
      const data = this.categoryData.get(cat)
      if (!data || !data.routes) return

      // A line is served as several runs — one per stretch it holds a single
      // place across its corridor along — so the runs are joined back up
      // before a train is put on one. Without that, trains shuttle back and
      // forth inside a junction throat instead of running the line.
      this.joinRuns(data.routes.features || []).forEach(({paths, color}) => {
        paths.forEach((coords) => {
          const line = this.measureLine(coords)
          if (line && line.total > MIN_TRAIN_LINE) lines.push({line, color})
        })
      })
    })

    // Even sampling keeps a dense metro from crowding out sparser networks
    // once we hit the train budget.
    const step = lines.length > MAX_TRAINS ? lines.length / MAX_TRAINS : 1
    const trains = []
    for (let i = 0; i < lines.length; i += step) {
      const {line, color} = lines[Math.floor(i)]
      trains.push({
        ...line,
        color,
        pos: Math.random() * line.total,
        dir: Math.random() < 0.5 ? 1 : -1,
        speed: TRAIN_SPEED * (0.7 + Math.random() * 0.6),
      })
    }

    this.trains = trains
  },

  // Groups a category's run features back into whole lines, stitching runs
  // that meet end to end. Runs of one line share their boundary coordinate
  // exactly, so matching endpoints is all it takes.
  joinRuns(features) {
    const grouped = new Map()

    features.forEach((feature) => {
      const parts = this.geometryParts(feature.geometry)
      if (parts.length === 0) return

      const key = feature.properties?.line ?? feature.properties?.name ?? ""
      const group =
        grouped.get(key) || {color: this.safeColor(feature.properties?.color), parts: []}
      group.parts.push(...parts)
      grouped.set(key, group)
    })

    return [...grouped.values()].map(({color, parts}) => ({color, paths: this.stitch(parts)}))
  },

  geometryParts(geometry) {
    if (!geometry) return []
    const parts =
      geometry.type === "LineString"
        ? [geometry.coordinates]
        : geometry.type === "MultiLineString"
          ? geometry.coordinates
          : []

    return parts.filter((coords) => Array.isArray(coords) && coords.length >= 2)
  },

  stitch(parts) {
    const at = (point) => `${point[0].toFixed(6)},${point[1].toFixed(6)}`
    const remaining = parts.slice()
    const paths = []

    while (remaining.length > 0) {
      let path = remaining.pop()

      for (let grew = true; grew; ) {
        grew = false

        for (let i = 0; i < remaining.length; i++) {
          const part = remaining[i]

          if (at(path[path.length - 1]) === at(part[0])) {
            path = path.concat(part.slice(1))
          } else if (at(path[0]) === at(part[part.length - 1])) {
            path = part.slice(0, -1).concat(path)
          } else {
            continue
          }

          remaining.splice(i, 1)
          grew = true
          break
        }
      }

      paths.push(path)
    }

    return paths
  },

  measureLine(coords) {
    if (!Array.isArray(coords) || coords.length < 2) return null

    const cum = [0]
    let total = 0
    for (let i = 1; i < coords.length; i++) {
      total += this.segmentLength(coords[i - 1], coords[i])
      cum.push(total)
    }

    return total > 0 ? {coords, cum, total} : null
  },

  segmentLength(a, b) {
    const latMid = (((a[1] + b[1]) / 2) * Math.PI) / 180
    const dx = (b[0] - a[0]) * Math.cos(latMid)
    const dy = b[1] - a[1]
    return Math.hypot(dx, dy)
  },

  pointAt(train) {
    const {coords, cum, total, pos} = train
    if (pos <= 0) return coords[0]
    if (pos >= total) return coords[coords.length - 1]

    let i = 1
    while (i < cum.length - 1 && cum[i] < pos) i++
    const segStart = cum[i - 1]
    const segLen = cum[i] - segStart || 1
    const t = (pos - segStart) / segLen
    const a = coords[i - 1]
    const b = coords[i]
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
  },

  startTrainLoop() {
    if (this.trainFrame != null) return

    if (this.reducedMotion()) {
      this.renderTrainsOnce()
      return
    }

    this.trainLastTs = 0
    this.trainFrame = requestAnimationFrame((ts) => this.tickTrains(ts))
  },

  stopTrainLoop() {
    if (this.trainFrame != null) {
      cancelAnimationFrame(this.trainFrame)
      this.trainFrame = null
    }
  },

  tickTrains(ts) {
    if (!this.liveTraffic) {
      this.trainFrame = null
      return
    }

    let dt = this.trainLastTs ? (ts - this.trainLastTs) / 1000 : 0
    this.trainLastTs = ts
    if (dt > 0.1) dt = 0.1 // clamp jumps after the tab was backgrounded

    const features = this.trains.map((train) => {
      train.pos += train.dir * train.speed * dt
      if (train.pos >= train.total) {
        train.pos = train.total
        train.dir = -1
      } else if (train.pos <= 0) {
        train.pos = 0
        train.dir = 1
      }
      return this.trainFeature(train)
    })

    this.setTrainData(features)
    this.trainFrame = requestAnimationFrame((next) => this.tickTrains(next))
  },

  renderTrainsOnce() {
    this.setTrainData(this.trains.map((train) => this.trainFeature(train)))
  },

  trainFeature(train) {
    return {
      type: "Feature",
      geometry: {type: "Point", coordinates: this.pointAt(train)},
      properties: {color: train.color},
    }
  },

  setTrainData(features) {
    const source = this.map.getSource("live-trains")
    if (source) source.setData({type: "FeatureCollection", features})
  },

  setTrainVisibility(visibility) {
    TRAIN_LAYERS.forEach((id) => this.setVisibility(id, visibility))
  },

  reducedMotion() {
    return Boolean(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)
  },

  ensureTrainLayers() {
    if (!this.map.getSource("live-trains")) {
      this.map.addSource("live-trains", {
        type: "geojson",
        data: {type: "FeatureCollection", features: []},
      })
    }

    if (!this.map.getLayer("live-trains-glow")) {
      this.map.addLayer({
        id: "live-trains-glow",
        type: "circle",
        source: "live-trains",
        paint: {
          "circle-color": ["get", "color"],
          "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 3, 10, 6, 14, 11, 17, 15],
          "circle-blur": 1,
          "circle-opacity": 0.35,
        },
      })
    }

    if (!this.map.getLayer("live-trains-dot")) {
      this.map.addLayer({
        id: "live-trains-dot",
        type: "circle",
        source: "live-trains",
        paint: {
          "circle-color": ["get", "color"],
          "circle-radius": ["interpolate", ["linear"], ["zoom"], 5, 1.6, 10, 3, 14, 5, 17, 6.5],
          "circle-stroke-color": "#ffffff",
          "circle-stroke-width": 1.4,
          "circle-opacity": 1,
          "circle-stroke-opacity": 0.95,
        },
      })
    }
  },
}

export default TransitMap
