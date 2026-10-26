// A station's departure board, inside its popup: the timetable, with live
// times where the agency publishes them (Transitmaps.Departures). It asks
// /api/departures when the station opens and every 30 seconds while it stays
// open, keeping the last list on screen while a new one loads. A departure opens to its service's
// whole run (ServiceTimetable), which takes the board's place until it goes
// back.

import {REFRESH_MS, DEPARTURE_STATES, minutes, escapeHtml, safeColor, clockFormat, dayFormat, dayKey, zoneName, viewerZone} from "./departure_format"
import {ServiceTimetable} from "./service_timetable"

const PAGE = 10
const MAX_DEPARTURES = 60

export class DepartureBoard {
  // `onStation` opens a station on the map, from a stop on a service's run.
  constructor(panel, ids, {onStation} = {}) {
    this.panel = panel
    this.ids = ids
    this.onStation = onStation
    this.limit = PAGE
    this.result = null
    this.error = null
    this.loading = false
    this.request = 0
  }

  start() {
    this.renderLoading()
    this.load()
    this.startTimers()
  }

  startTimers() {
    this.refreshTimer = setInterval(() => this.load(), REFRESH_MS)
  }

  pause() {
    clearInterval(this.refreshTimer)
    this.controller?.abort()
    this.request++
    this.loading = false
  }

  stop() {
    this.stopped = true
    this.pause()
    this.serviceView?.stop()
  }

  // The board steps aside for one departure's whole run, and comes back
  // with the focus on that departure.
  openService(departure) {
    this.pause()
    this.serviceView = new ServiceTimetable(this.panel, departure.service, {
      here: this.ids,
      onStation: this.onStation,
      onBack: () => this.closeService(departure.service),
    })
    this.serviceView.start()
  }

  closeService(service) {
    this.serviceView?.stop()
    this.serviceView = null
    this.render()
    ;(this.serviceButton(service) || this.panel.querySelector("[data-service]"))?.focus()
    this.load()
    this.startTimers()
  }

  async load() {
    if (this.stopped || this.serviceView) return
    this.controller?.abort()
    this.controller = new AbortController()
    const request = ++this.request
    this.loading = true

    try {
      const params = new URLSearchParams({stops: this.ids.join(","), limit: String(this.limit)})
      const response = await fetch(`/api/departures?${params}`, {signal: this.controller.signal, headers: {accept: "application/json"}})
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const result = await response.json()
      if (this.stopped || this.serviceView || request !== this.request) return
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
    if (this.stopped || this.serviceView) return
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
    const active = this.panel.contains(document.activeElement) ? document.activeElement : null
    const focusedService = active?.hasAttribute("data-service")
      ? {trip: active.getAttribute("data-trip"), at: active.getAttribute("data-at")}
      : null

    this.panel.innerHTML =
      failure +
      this.headHtml(timezone, live, timetable) +
      (departures.length ? this.listHtml(departures, timezone, now) : this.emptyHtml(live, timetable)) +
      (more && this.limit < MAX_DEPARTURES
        ? `<button type="button" class="ui-button ui-button--quiet ui-button--small tm-departures-more" data-departures-more>Later departures</button>`
        : "")
    this.bind()
    this.panel.scrollTop = scroll
    if (focused) this.panel.querySelector(`[${focused}]`)?.focus()
    else if (focusedService) this.serviceButton(focusedService)?.focus()
  }

  serviceButton({trip, at}) {
    return [...this.panel.querySelectorAll("[data-service]")].find(
      (button) => button.getAttribute("data-trip") === trip && button.getAttribute("data-at") === String(at)
    )
  }

  headHtml(timezone, live, timetable) {
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

    return (zone ? `<div class="tm-departures-head">${zone}</div>` : "") + notice
  }

  listHtml(departures, timezone, now) {
    const clock = clockFormat(timezone)
    const day = dayFormat(timezone)
    const key = dayKey(timezone)
    let shownDay = key.format(new Date())

    const rows = departures.map((departure, index) => {
      const at = new Date((departure.scheduled ?? departure.time) * 1000)
      const thisDay = key.format(at)
      const separator =
        thisDay !== shownDay ? `<li class="tm-departures-day ui-label" aria-hidden="true">${escapeHtml(day.format(at))}</li>` : ""
      shownDay = thisDay
      return separator + this.rowHtml(departure, clock, now, index)
    })

    return `<ol class="tm-departures" aria-label="Departures">${rows.join("")}</ol>`
  }

  rowHtml(departure, clock, now, index) {
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

    const cells =
      `<span class="tm-departure-time ui-mono">${escapeHtml(shown)}</span>` +
      `<span class="tm-departure-main">` +
      `<span class="tm-departure-destination ui-truncate" title="${escapeHtml(destination)}">${escapeHtml(destination)}</span>` +
      `<span class="tm-departure-line">${sub}</span>` +
      `</span>${status}`
    const cancelled = departure.status === "cancelled" ? " data-cancelled" : ""

    // A departure with its service's run kept opens it; TfL's live arrivals
    // have none.
    if (!departure.service) return `<li class="tm-departure"${cancelled} aria-label="${escapeHtml(label)}">${cells}</li>`

    return (
      `<li class="tm-departure tm-departure--service"${cancelled}>` +
      `<button type="button" class="tm-departure-open" data-service="${index}"` +
      ` data-trip="${escapeHtml(departure.service.trip)}" data-at="${escapeHtml(departure.service.at)}"` +
      ` aria-label="${escapeHtml(`${label}. Show all stops`)}">${cells}</button></li>`
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

  bind() {
    this.panel.querySelector("[data-departures-retry]")?.addEventListener("click", (event) => {
      event.stopPropagation()
      this.load()
    })

    this.panel.querySelectorAll("[data-service]").forEach((button) =>
      button.addEventListener("click", (event) => {
        event.stopPropagation()
        const departure = this.result?.departures[Number(button.getAttribute("data-service"))]
        if (departure?.service) this.openService(departure)
      })
    )

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
