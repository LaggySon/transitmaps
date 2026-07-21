import maplibregl from "../vendor/maplibre-gl"

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
const LINE_WIDTH = {metro: 3.2, tram: 2.6, intercity: 2.8, rail: 2.35, bus: 1.55, coach: 1.55, ferry: 1.8}

const layerIds = (cat) => ({
  casing: `${cat}-casing`,
  line: `${cat}-line`,
  lineLabels: `${cat}-line-labels`,
  stops: `${cat}-stops`,
  labels: `${cat}-station-labels`,
})

const desiredLayerOrder = () =>
  MODE_ORDER.flatMap((cat) => [layerIds(cat).casing, layerIds(cat).line]).concat(
    MODE_ORDER.map((cat) => layerIds(cat).lineLabels),
    MODE_ORDER.map((cat) => layerIds(cat).stops),
    MODE_ORDER.map((cat) => layerIds(cat).labels)
  )

const TransitMap = {
  mounted() {
    this.loaded = new Set()
    this.pending = new Map()
    this.categoryData = new Map()
    this.enabled = new Set(this.parseData("enabled", []))
    this.details = new Set(this.parseData("details", ["labels", "stops"]))
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
        maxZoom: 17,
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
    const loading = this.el.querySelector(".map-loading")
    if (loading) loading.hidden = true
    this.updateZoomReadout()
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
      return {top: 56, right: 56, bottom: 56, left: 400}
    }

    return {top: 64, right: 28, bottom: Math.round(window.innerHeight * 0.44), left: 28}
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

  syncLayers() {
    this.el.dataset.transitReady = "false"
    this.el.dataset.mapIdle = "false"

    const updates = MODE_ORDER.map((cat) => {
      if (this.enabled.has(cat)) return this.showCategory(cat)
      this.hideCategory(cat)
      return Promise.resolve()
    })

    Promise.allSettled(updates).then(() => {
      this.el.dataset.mapIdle = "false"
      this.el.dataset.transitReady = "true"
      if (this.map.loaded()) this.announceIdle()
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
      const [routeResponse, stopResponse] = await Promise.all([
        fetch(`/api/routes.geojson?cats=${encodeURIComponent(cat)}`),
        fetch(`/api/stops.geojson?cats=${encodeURIComponent(cat)}`),
      ])

      if (!routeResponse.ok || !stopResponse.ok) throw new Error(`Could not load ${cat} data`)

      const [routes, stops] = await Promise.all([routeResponse.json(), stopResponse.json()])
      this.categoryData.set(cat, {routes, stops})

      if (!this.map.getSource(`${cat}-routes`)) {
        this.map.addSource(`${cat}-routes`, {type: "geojson", data: routes})
        this.map.addSource(`${cat}-stops`, {type: "geojson", data: stops})
        this.addCategoryLayers(cat)
      }

      this.loaded.add(cat)
      this.setCategoryVisibility(cat)
    } catch (error) {
      console.error(`Unable to load ${cat} transit data:`, error)
    }
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
    const width = LINE_WIDTH[cat] || 2.0
    const zoomedWidth = (base) => [
      "interpolate", ["linear"], ["zoom"],
      4, base * 0.48,
      7, base * 0.68,
      10, base,
      14, base * 1.72,
      17, base * 1.9,
    ]
    const slot = ["to-number", ["coalesce", ["get", "offset"], 0]]
    // Lines sharing a corridor sit in small offset slots (the server clamps
    // them to ±3), drawn on their shared centreline at country zooms and
    // fanned apart by roughly one line's width once there is room to tell
    // them apart.
    const spacing = (width + 2.15) * 1.6
    const parallelOffset = [
      "interpolate", ["linear"], ["zoom"],
      10, 0,
      13, ["*", slot, spacing],
      17, ["*", slot, spacing * 1.5],
    ]

    this.addLayerInOrder({
      id: ids.casing,
      type: "line",
      source: `${cat}-routes`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": "rgba(255,255,255,0.96)",
        "line-width": zoomedWidth(width + 2.15),
        "line-opacity": ["interpolate", ["linear"], ["zoom"], 4, 0.82, 8, 0.94],
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
        "line-opacity": ["interpolate", ["linear"], ["zoom"], 4, 0.88, 8, 1],
        "line-offset": parallelOffset,
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
        "circle-radius": ["interpolate", ["linear"], ["zoom"], 7.5, 1.2, 11, 3.2, 15, 5.8, 17, 7],
        "circle-stroke-width": ["case", ["get", "station"], 1.7, 1.05],
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
        "text-size": ["interpolate", ["linear"], ["zoom"], 8, 9.5, 12, 11.5, 16, 13.5],
        "text-anchor": "top",
        "text-offset": [0, 0.78],
        "text-max-width": 12,
        "text-padding": 3,
        "text-optional": true,
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
      const stopLayers = MODE_ORDER.map((mode) => layerIds(mode).stops).filter((id) => this.map.getLayer(id))
      if (this.map.queryRenderedFeatures(event.point, {layers: stopLayers}).length > 0) return

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
    const groups = this.stationServiceGroups(lines)
    const content = groups.length
      ? `<div class="station-popup__services"><div class="station-popup__eyebrow">Services</div>${groups
          .map(
            (group) =>
              `<section class="station-popup__group"><div class="station-popup__operator">${this.escapeHtml(group.agency)}</div>` +
              `<div class="station-popup__badges">${group.lines
                .map(
                  (line) =>
                    `<span class="station-popup__badge" style="--line-color:${this.safeColor(line.color)}">` +
                    `${this.escapeHtml(line.label)}</span>`
                )
                .join("")}</div></section>`
          )
          .join("")}</div>`
      : `<div class="station-popup__empty">No service information available</div>`

    return `<div class="station-popup"><div class="station-popup__title">${this.escapeHtml(props.name || "Stop")}</div>${content}</div>`
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

  stationServices(lines) {
    const services = new Map()

    lines.forEach((line) => {
      const label = line.name || line.agency
      if (!label) return

      const agency = line.agency && line.agency !== label ? line.agency : null
      const key = `${label}:${agency || ""}`
      if (!services.has(key)) services.set(key, {label, agency, color: line.color})
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
