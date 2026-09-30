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

// Where the map opens, unless the URL hash already names a view. The server
// warms its cache for the agencies here (GeoJsonCache's @opening_view).
const DEFAULT_VIEW = {center: [-2.0, 53.8], zoom: 5.5}

// Agencies are loaded for a view padded by this fraction on every side, so
// lines are already there when a pan brings them on screen.
const LOAD_PADDING = 0.5

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

const layerIds = (cat) => ({
  line: `${cat}-line`,
  lineLabels: `${cat}-line-labels`,
  stops: `${cat}-stops`,
  labels: `${cat}-station-labels`,
})

// Lines first, then their names, then stops and station names on top.
const desiredLayerOrder = () =>
  MODE_ORDER.map((cat) => layerIds(cat).line).concat(
    MODE_ORDER.map((cat) => layerIds(cat).lineLabels),
    MODE_ORDER.map((cat) => layerIds(cat).stops),
    MODE_ORDER.map((cat) => layerIds(cat).labels)
  )

const TransitMap = {
  mounted() {
    // Categories whose sources and layers exist on the map.
    this.loaded = new Set()
    // Per agency and mode, keyed "feedId:category".
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
    this.map.on("moveend", () => {
      if (this.map.isStyleLoaded()) this.syncLayers()
    })

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
    // An agency finished downloading or refreshing: forget every agency's
    // data so what is on screen reloads (the server has it cached anyway).
    this.handleEvent("feeds-changed", ({feeds}) => {
      this.feeds = feeds
      this.feedData.clear()
      this.renderedKey = null
      if (this.map.isStyleLoaded()) this.syncLayers()
    })
    this.handleEvent("agencies-hidden", ({hidden}) => {
      this.hidden = new Set(hidden)
      this.render()
    })
    this.handleEvent("fly-to", ({bounds}) => {
      this.map.fitBounds(bounds, {padding: this.mapPadding(), duration: 900, essential: true})
    })

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

  advanceDataLoading(batch, key) {
    const progress = this.dataLoadProgress
    if (!progress || progress.batch !== batch || !progress.categories.has(key)) return

    progress.complete.add(key)
    const complete = progress.complete.size
    const total = progress.categories.size
    const category = key.split(":")[1]
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

  // Room for the floating menu button and map controls, which sit over the map.
  mapPadding() {
    if (window.matchMedia("(min-width: 640px)").matches) {
      return {top: 84, right: 72, bottom: 40, left: 40}
    }

    return {top: 76, right: 28, bottom: 28, left: 28}
  },

  destroyed() {
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

  // Agencies whose service area overlaps the view, padded by `padding` of
  // its size on every side.
  feedsNear(padding) {
    const bounds = this.map.getBounds()
    const padX = (bounds.getEast() - bounds.getWest()) * padding
    const padY = (bounds.getNorth() - bounds.getSouth()) * padding
    const [west, south, east, north] = [
      bounds.getWest() - padX,
      bounds.getSouth() - padY,
      bounds.getEast() + padX,
      bounds.getNorth() + padY,
    ]

    return this.feeds
      .filter(({bounds: [[w, s], [e, n]]}) => w <= east && e >= west && s <= north && n >= south)
      .map((feed) => feed.id)
      .sort((a, b) => a - b)
  },

  // The agencies drawn right now: near the view and not hidden by the visitor.
  activeFeeds() {
    return this.feedsNear(LOAD_PADDING).filter((id) => !this.hidden.has(id))
  },

  // Reports what is on screen to the menu, then loads whatever the drawn
  // agencies are missing for the enabled modes and redraws as it lands.
  syncLayers() {
    const inView = this.feedsNear(0)
    const viewKey = inView.join(",")
    if (viewKey !== this.reportedView) {
      this.reportedView = viewKey
      this.pushEvent("view", {feeds: inView})
    }

    const missing = this.activeFeeds().flatMap((id) =>
      MODE_ORDER.filter((cat) => this.enabled.has(cat) && !this.feedData.has(`${id}:${cat}`)).map(
        (cat) => `${id}:${cat}`
      )
    )

    this.el.dataset.transitReady = "false"
    this.el.dataset.mapIdle = "false"
    const batch = ++this.dataLoadBatch
    this.startDataLoading(batch, missing)
    this.render()

    const loads = missing.map((key) => this.loadFeed(key).then(() => this.advanceDataLoading(batch, key)))

    Promise.allSettled(loads).then((results) => {
      this.render()
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
        if (missing.length > 0) this.showLoading("Transit data ready", "All visible layers loaded", 100)
        if (this.map.loaded()) this.announceIdle()
      }
    })
  },

  async loadFeed(key) {
    if (this.pending.has(key)) return this.pending.get(key)

    const [feedId, cat] = key.split(":")
    const query = `feed=${feedId}&cats=${encodeURIComponent(cat)}`

    const request = (async () => {
      const [routeResponse, stopResponse] = await Promise.all([
        fetch(`/api/routes.geojson?${query}`),
        fetch(`/api/stops.geojson?${query}`),
      ])

      if (!routeResponse.ok || !stopResponse.ok) throw new Error(`Could not load ${key}`)

      const [routes, stops] = await Promise.all([routeResponse.json(), stopResponse.json()])
      this.feedData.set(key, {routes, stops})
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
    if (!this.map?.isStyleLoaded()) return

    const active = this.activeFeeds()
    const loadedKeys = active.flatMap((id) =>
      MODE_ORDER.filter((cat) => this.enabled.has(cat) && this.feedData.has(`${id}:${cat}`)).map(
        (cat) => `${id}:${cat}`
      )
    )
    const renderKey = loadedKeys.join(",")

    if (renderKey !== this.renderedKey) {
      this.renderedKey = renderKey
      const stopsByCategory = this.mergedStops(loadedKeys)

      MODE_ORDER.filter((cat) => this.enabled.has(cat)).forEach((cat) => {
        const routes = {
          type: "FeatureCollection",
          features: active.flatMap((id) => this.feedData.get(`${id}:${cat}`)?.routes.features || []),
        }
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
    }

    MODE_ORDER.forEach((cat) => (this.enabled.has(cat) ? this.setCategoryVisibility(cat) : this.hideCategory(cat)))
  },

  // Each agency's stations, once each (a station serving two modes arrives in
  // both modes' responses), merged across agencies and handed to every mode
  // they serve.
  mergedStops(keys) {
    const unique = new Map()

    keys.forEach((key) => {
      const feedId = key.split(":")[0]
      ;(this.feedData.get(key)?.stops.features || []).forEach((feature) => {
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
}

export default TransitMap
