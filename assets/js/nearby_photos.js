// Photos of what is around a station or a place, from Wikimedia Commons:
// free to show, no key, and geotagged, so a search by position finds the
// street itself rather than everything else that shares its name. Each
// thumbnail links to its Commons page, which carries the author and licence.
// Links to Street View and Google Images sit underneath for a closer look.

const COMMONS_API = "https://commons.wikimedia.org/w/api.php"
const SHOWN = 6
const PHOTO_TYPES = new Set(["image/jpeg", "image/png", "image/webp"])

// Commons' search turns away a good share of queries as "too busy" at busy
// times; a retry a moment later nearly always gets through.
const BUSY_ERROR = "cirrussearch-too-busy-error"
const RETRY_DELAYS = [800, 2000]

// Results by query, so reopening a popup shows its photos at once.
const cache = new Map()

const escapeHtml = (value) =>
  String(value ?? "").replace(/[&<>'"]/g, (char) =>
    ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[char]
  )

const wait = (ms, signal) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms)
    signal.addEventListener("abort", () => {
      clearTimeout(timer)
      reject(signal.reason)
    })
  })

const photoQuery = ({lng, lat}, radius) => {
  const point = `${lat.toFixed(5)}|${lng.toFixed(5)}`
  const params = new URLSearchParams({
    action: "query",
    format: "json",
    formatversion: "2",
    origin: "*",
    generator: "geosearch",
    ggscoord: point,
    ggsradius: String(radius),
    ggslimit: "24",
    ggsnamespace: "6",
    prop: "imageinfo|coordinates",
    colimit: "max",
    codistancefrompoint: point,
    iiprop: "url|mime",
    iiurlwidth: "240",
  })
  return `${COMMONS_API}?${params}`
}

// "File:Big Ben from the bridge.jpg" reads as "Big Ben from the bridge".
const photoTitle = (title) =>
  String(title)
    .replace(/^File:/, "")
    .replace(/\.[a-z0-9]+$/i, "")

// Nearest first, and only photographs: Commons also geotags maps, diagrams
// and scanned documents, which are mostly SVG, TIFF or PDF.
const toPhotos = (pages) =>
  pages
    .map((page) => ({page, info: page.imageinfo?.[0]}))
    .filter(({info}) => info?.thumburl && PHOTO_TYPES.has(info.mime))
    .map(({page, info}) => ({
      title: photoTitle(page.title),
      thumb: info.thumburl,
      href: info.descriptionurl,
      distance: page.coordinates?.[0]?.dist ?? Infinity,
    }))
    .sort((a, b) => a.distance - b.distance)
    .slice(0, SHOWN)

export const fetchNearbyPhotos = async (lngLat, radius, signal) => {
  const url = photoQuery(lngLat, radius)
  if (cache.has(url)) return cache.get(url)

  for (let attempt = 0; ; attempt++) {
    const response = await fetch(url, {signal})
    if (!response.ok) throw new Error(`Wikimedia Commons answered ${response.status}`)
    const body = await response.json()

    if (body.error) {
      if (body.error.code === BUSY_ERROR && attempt < RETRY_DELAYS.length) {
        await wait(RETRY_DELAYS[attempt], signal)
        continue
      }
      throw new Error(body.error.info || "Wikimedia Commons is busy")
    }

    const photos = toPhotos(body.query?.pages || [])
    cache.set(url, photos)
    return photos
  }
}

const streetViewUrl = ({lng, lat}) =>
  `https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${lat.toFixed(6)},${lng.toFixed(6)}`

const imageSearchUrl = (query) => `https://www.google.com/search?tbm=isch&q=${encodeURIComponent(query)}`

const externalLink = (href, label, id) =>
  `<a class="ui-link" id="${id}" href="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer">` +
  `${label} <span aria-hidden="true">↗</span></a>`

// The section the popup shows: the photos (filled in by NearbyPhotos) and
// links out. `query` is what to search Google Images for.
export const nearbyPhotosHtml = (lngLat, query) =>
  `<section class="tm-photos" aria-label="Photos nearby">` +
  `<div class="tm-photos-grid" data-photos aria-live="polite"></div>` +
  `<div class="tm-photos-links">` +
  externalLink(streetViewUrl(lngLat), "Street View", "photos-street-view") +
  externalLink(imageSearchUrl(query), "Google Images", "photos-image-search") +
  `</div>` +
  `</section>`

// Fills a `[data-photos]` element with the photos nearest `lngLat`. Loading
// starts on `start()` (a popup's Photos tab waits until it is opened) and
// stops with the popup. `onRender` runs whenever the section changes size.
export class NearbyPhotos {
  constructor(el, lngLat, {radius = 150, onRender = () => {}} = {}) {
    this.el = el
    this.lngLat = lngLat
    this.radius = radius
    this.onRender = onRender
    this.started = false
  }

  start() {
    if (this.started) return
    this.started = true
    this.load()
  }

  stop() {
    this.controller?.abort()
  }

  async load() {
    this.controller?.abort()
    const controller = new AbortController()
    this.controller = controller
    this.el.innerHTML = `<p class="tm-photos-status" role="status">Loading photos…</p>`

    try {
      const photos = await fetchNearbyPhotos(this.lngLat, this.radius, controller.signal)
      if (controller.signal.aborted) return
      this.render(photos)
    } catch (error) {
      if (controller.signal.aborted) return
      this.el.innerHTML =
        `<p class="tm-photos-status">Photos could not be loaded from Wikimedia Commons. ` +
        `<button type="button" class="ui-link tm-photos-retry" data-photos-retry>Try again</button></p>`
      this.el.querySelector("[data-photos-retry]").addEventListener("click", (event) => {
        event.stopPropagation()
        this.load()
      })
      this.onRender()
    }
  }

  render(photos) {
    if (photos.length === 0) {
      this.el.innerHTML = `<p class="tm-photos-status">No photos taken here on Wikimedia Commons yet.</p>`
      this.onRender()
      return
    }

    this.el.innerHTML =
      `<ul class="tm-photos-list">${photos
        .map(
          (photo) =>
            `<li><a class="tm-photo" href="${escapeHtml(photo.href)}" target="_blank" rel="noopener noreferrer"` +
            ` title="${escapeHtml(photo.title)}">` +
            `<img src="${escapeHtml(photo.thumb)}" alt="${escapeHtml(photo.title)}" loading="lazy" decoding="async" />` +
            `</a></li>`
        )
        .join("")}</ul>` +
      `<p class="tm-photos-credit">Photos from Wikimedia Commons. Select one for its author and licence.</p>`
    this.onRender()
  }
}
