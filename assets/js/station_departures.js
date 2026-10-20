// A station's departure board, inside its popup: the timetable, with live
// times where the agency publishes them (Transitmaps.Departures). It asks
// /api/departures when the station opens and every 30 seconds while it stays
// open, keeping the last list on screen while a new one loads. The
// "updated" readout ticks every second.

const REFRESH_MS = 30_000
// The server keeps a live feed for 30 seconds and the board asks every 30,
// so live times are normally under a minute old. Twice that is stale.
const STALE_AFTER_S = 120
const PAGE = 10
const MAX_DEPARTURES = 60

// A departure's state: its word and its role (DESIGN.md section 3.1). Every
// state the board shows is defined here.
export const DEPARTURE_STATES = {
  on_time: {role: "success", word: () => "On time"},
  late: {role: "warning", word: (d) => `+${minutes(d.delay)} min`},
  early: {role: null, word: (d) => `−${minutes(-d.delay)} min`},
  cancelled: {role: "failure", word: () => "Cancelled"},
  live: {role: null, word: (d, now) => (d.time - now < 60 ? "Due" : `${minutes(d.time - now)} min`)},
  scheduled: {role: null, word: () => ""},
}

const minutes = (seconds) => Math.max(1, Math.round(seconds / 60))

const escapeHtml = (value) =>
  String(value ?? "").replace(/[&<>'"]/g, (char) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[char])

const safeColor = (value) => (/^#[0-9a-f]{6}$/i.test(value || "") ? value : "#6e6e73")

// Times are the station's own (a London board in London time, wherever the
// visitor is), 24-hour (DESIGN.md section 11).
const clockFormat = (timeZone) =>
  new Intl.DateTimeFormat(undefined, {timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23"})
const dayFormat = (timeZone) => new Intl.DateTimeFormat(undefined, {timeZone, weekday: "short", day: "numeric", month: "short"})
const dayKey = (timeZone) => new Intl.DateTimeFormat("en-CA", {timeZone, year: "numeric", month: "2-digit", day: "2-digit"})
const zoneName = (timeZone) =>
  new Intl.DateTimeFormat(undefined, {timeZone, timeZoneName: "short"}).formatToParts(new Date()).find((part) => part.type === "timeZoneName")?.value

const viewerZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone

export class DepartureBoard {
  constructor(panel, ids) {
    this.panel = panel
    this.ids = ids
    this.limit = PAGE
    this.result = null
    this.error = null
    this.loading = false
    this.request = 0
  }

  start() {
    this.renderLoading()
    this.load()
    this.refreshTimer = setInterval(() => this.load(), REFRESH_MS)
    this.ageTimer = setInterval(() => this.renderAge(), 1000)
  }

  stop() {
    this.stopped = true
    clearInterval(this.refreshTimer)
    clearInterval(this.ageTimer)
    this.controller?.abort()
  }

  async load() {
    if (this.stopped) return
    this.controller?.abort()
    this.controller = new AbortController()
    const request = ++this.request
    this.loading = true

    try {
      const params = new URLSearchParams({stops: this.ids.join(","), limit: String(this.limit)})
      const response = await fetch(`/api/departures?${params}`, {signal: this.controller.signal, headers: {accept: "application/json"}})
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const result = await response.json()
      if (this.stopped || request !== this.request) return
      this.result = result
      this.error = null
    } catch (error) {
      if (error.name === "AbortError" || this.stopped || request !== this.request) return
      this.error = error.message.startsWith("HTTP") ? error.message : "no answer"
    } finally {
      if (request === this.request) this.loading = false
    }

    this.render()
  }

  renderLoading() {
    this.panel.innerHTML = `<p class="tm-popup-empty" role="status">Loading departures…</p>`
  }

  render() {
    if (this.stopped) return
    // A failed refresh keeps the last list and says so above it.
    const failure = this.error
      ? `<div class="ui-notice" data-status="failure" role="alert">` +
        `<span>Departures failed to load (${escapeHtml(this.error)}).</span>` +
        `<button type="button" class="ui-button ui-button--quiet ui-button--small ui-notice-end" data-departures-retry>Retry</button></div>`
      : ""

    if (!this.result) {
      this.panel.innerHTML = failure
      this.bind()
      return
    }

    const {departures, timezone, live, timetable, more} = this.result
    const now = Date.now() / 1000
    // A refresh keeps the reader's place: the scroll, and the focused button.
    const scroll = this.panel.scrollTop
    const focused = ["data-departures-more", "data-departures-retry"].find((name) =>
      document.activeElement?.hasAttribute?.(name)
    )

    this.panel.innerHTML =
      failure +
      this.headHtml(timezone, live, timetable) +
      (departures.length ? this.listHtml(departures, timezone, now) : this.emptyHtml(live, timetable)) +
      (more && this.limit < MAX_DEPARTURES
        ? `<button type="button" class="ui-button ui-button--quiet ui-button--small tm-departures-more" data-departures-more>Later departures</button>`
        : "")
    this.bind()
    this.renderAge()
    this.panel.scrollTop = scroll
    if (focused) this.panel.querySelector(`[${focused}]`)?.focus()
  }

  headHtml(timezone, live, timetable) {
    const source =
      live === "live"
        ? `<span class="ui-badge" data-status="progress"><span class="ui-dot"></span>Live</span>` +
          `<span class="tm-departures-age ui-mono" aria-live="off" data-departures-age></span>`
        : `<span class="ui-label">Timetable</span>`

    const zone =
      timezone && timezone !== viewerZone()
        ? `<span class="tm-departures-zone ui-mono" title="Times are the station's local time (${escapeHtml(timezone)})">` +
          `${escapeHtml(zoneName(timezone) || timezone)}</span>`
        : ""

    const notice =
      live === "unavailable"
        ? `<div class="ui-notice" data-status="warning" role="status">` +
          (timetable === "none" ? "Live times unavailable right now." : "Live times unavailable. Showing the timetable.") +
          `</div>`
        : ""

    return `<div class="tm-departures-head">${source}${zone}</div>${notice}`
  }

  listHtml(departures, timezone, now) {
    const clock = clockFormat(timezone)
    const day = dayFormat(timezone)
    const key = dayKey(timezone)
    let shownDay = key.format(new Date())

    const rows = departures.map((departure) => {
      const at = new Date((departure.scheduled ?? departure.time) * 1000)
      const thisDay = key.format(at)
      const separator =
        thisDay !== shownDay ? `<li class="tm-departures-day ui-label" aria-hidden="true">${escapeHtml(day.format(at))}</li>` : ""
      shownDay = thisDay
      return separator + this.rowHtml(departure, clock, now)
    })

    return `<ol class="tm-departures" aria-label="Departures">${rows.join("")}</ol>`
  }

  rowHtml(departure, clock, now) {
    const state = DEPARTURE_STATES[departure.status] || DEPARTURE_STATES.scheduled
    const word = state.word(departure, now)
    const shown = clock.format(new Date((departure.scheduled ?? departure.time) * 1000))
    const expected = departure.scheduled && departure.time !== departure.scheduled ? clock.format(new Date(departure.time * 1000)) : null
    const line = departure.line || {}
    const destination = departure.destination || line.name || "—"

    const sub = [
      `<span class="tm-swatch-line" style="--swatch: ${safeColor(line.color)}" aria-hidden="true"></span>`,
      `<span class="ui-truncate" title="${escapeHtml(line.agency && line.agency !== line.name ? `${line.name} · ${line.agency}` : line.name)}">${escapeHtml(line.name || "")}</span>`,
      departure.platform ? `<span class="ui-sep">·</span><span class="tm-departure-platform" title="Platform ${escapeHtml(departure.platform)}">Plat. ${escapeHtml(departure.platform)}</span>` : "",
    ].join("")

    const label = [
      `${shown} to ${destination}`,
      line.name,
      departure.platform ? `platform ${departure.platform}` : null,
      word ? (departure.status === "late" ? `${minutes(departure.delay)} minutes late, expected ${expected}` : word) : null,
    ]
      .filter(Boolean)
      .join(", ")

    const status = word
      ? `<span class="tm-departure-status" ${state.role ? `data-status="${state.role}"` : ""}` +
        `${expected ? ` title="Expected ${escapeHtml(expected)}"` : ""}>${escapeHtml(word)}</span>`
      : ""

    return (
      `<li class="tm-departure" ${departure.status === "cancelled" ? "data-cancelled" : ""} aria-label="${escapeHtml(label)}">` +
      `<span class="tm-departure-time ui-mono">${escapeHtml(shown)}</span>` +
      `<span class="tm-departure-main">` +
      `<span class="tm-departure-destination ui-truncate" title="${escapeHtml(destination)}">${escapeHtml(destination)}</span>` +
      `<span class="tm-departure-line">${sub}</span>` +
      `</span>${status}</li>`
    )
  }

  emptyHtml(live, timetable) {
    const sentence =
      timetable === "expired"
        ? "This timetable has run out. It comes back with the agency's next update."
        : timetable === "none" && live === "live"
          ? "No trains due right now."
          : timetable === "none"
            ? "No departures to show here."
            : "No departures in the coming week."
    return `<p class="ui-empty tm-departures-empty">${escapeHtml(sentence)}</p>`
  }

  // "updated 12s ago", from when the live times were fetched. It turns to
  // the warning colour once the times are stale.
  renderAge() {
    const age = this.panel.querySelector("[data-departures-age]")
    const updated = this.result?.updated_at
    if (!age || !updated) return
    const seconds = Math.max(0, Math.round(Date.now() / 1000 - updated))
    age.textContent = seconds < 60 ? `updated ${seconds}s ago` : `updated ${Math.floor(seconds / 60)}m ago`
    age.classList.toggle("tm-departures-age--stale", seconds > STALE_AFTER_S)
  }

  bind() {
    this.panel.querySelector("[data-departures-retry]")?.addEventListener("click", (event) => {
      event.stopPropagation()
      this.load()
    })

    this.panel.querySelector("[data-departures-more]")?.addEventListener("click", (event) => {
      event.stopPropagation()
      const button = event.currentTarget
      button.disabled = true
      button.textContent = "Loading…"
      this.limit = Math.min(this.limit + PAGE, MAX_DEPARTURES)
      this.load()
    })
  }
}
