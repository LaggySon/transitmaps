// MapLibre hook rendering an Apple Maps-style transit view: a muted basemap
// with bold, color-coded route lines and station markers, one toggleable
// layer group per mode category.

const BASEMAP_STYLE = "https://tiles.openfreemap.org/styles/positron"
const UK_CENTER = [-2.0, 53.8]

// Draw order, lowest first: higher-frequency/short-distance modes sit on top.
const MODE_ORDER = ["ferry", "coach", "bus", "rail", "intercity", "tram", "metro"]

const LINE_WIDTH = {metro: 3.0, tram: 2.4, intercity: 2.6, rail: 2.2, bus: 1.4, coach: 1.4, ferry: 1.6}

const layerIds = (cat) => ({casing: `${cat}-casing`, line: `${cat}-line`, stops: `${cat}-stops`})

// Global stacking: all line layers (in mode order), then all stop layers.
const desiredLayerOrder = () =>
  MODE_ORDER.flatMap((cat) => [layerIds(cat).casing, layerIds(cat).line]).concat(
    MODE_ORDER.map((cat) => layerIds(cat).stops)
  )

const TransitMap = {
  mounted() {
    this.loaded = new Set()
    this.enabled = new Set(JSON.parse(this.el.dataset.enabled))

    this.map = new maplibregl.Map({
      container: this.el,
      style: BASEMAP_STYLE,
      center: UK_CENTER,
      zoom: 5.5,
    })
    this.map.addControl(new maplibregl.NavigationControl(), "top-right")

    this.map.on("load", () => this.syncLayers())
    this.handleEvent("categories-changed", ({enabled}) => {
      this.enabled = new Set(enabled)
      if (this.map.isStyleLoaded()) this.syncLayers()
    })
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

    this.addLayerInOrder({
      id: ids.casing,
      type: "line",
      source: `${cat}-routes`,
      layout: {"line-join": "round", "line-cap": "round"},
      paint: {
        "line-color": "#ffffff",
        "line-width": zoomedWidth(width + 2.5),
        "line-opacity": 0.85,
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
      const props = e.features[0].properties
      this.openPopup(e.lngLat, `<strong>${props.name || "Stop"}</strong>`)
    })

    this.map.on("click", ids.line, (e) => {
      const props = e.features[0].properties
      const title = props.long_name || props.name
      const subtitle = props.agency ? `<div class="text-xs opacity-70">${props.agency}</div>` : ""
      this.openPopup(e.lngLat, `<strong style="color:${props.color}">${title}</strong>${subtitle}`)
    })

    const setPointer = (on) => () => (this.map.getCanvas().style.cursor = on ? "pointer" : "")
    ;[ids.stops, ids.line].forEach((id) => {
      this.map.on("mouseenter", id, setPointer(true))
      this.map.on("mouseleave", id, setPointer(false))
    })
  },

  openPopup(lngLat, html) {
    new maplibregl.Popup({closeButton: false, maxWidth: "260px"}).setLngLat(lngLat).setHTML(html).addTo(this.map)
  },
}

export default TransitMap
