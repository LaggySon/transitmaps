// One service's whole run, opened from a departure on a station's board
// (Transitmaps.Services): every stop it calls at that day, with its times,
// platforms, and live times where the agency publishes them. It takes the
// board's place in the popup until "Back to departures". With live times
// it asks /api/service again every 30 seconds; a timetable alone doesn't
// change, so it is read once.

import {REFRESH_MS, STALE_AFTER_S, DEPARTURE_STATES, minutes, escapeHtml, safeColor, clockFormat, dayFormat, dayKey} from "./departure_format"

// A stop counts as passed this long after the train leaves it.
const PASSED_AFTER_S = 30

export class ServiceTimetable {
  // `service` is the departure's service, `here` the ids of the station it
  // was opened from, `onBack` returns to the board and `onStation` opens a
  // stop's station on the map.
  constructor(panel, service, {here = [], onBack, onStation} = {}) {
    this.panel = panel
    this.service = service
    this.here = new Set(here)
    this.onBack = onBack
    this.onStation = onStation
    this.result = null
    this.error = null
    this.request = 0
    this.placed = false
  }

  start() {
    this.panel.scrollTop = 0
    this.panel.classList.add("tm-service-panel")
    this.panel.innerHTML = this.backHtml() + `<p class="tm-popup-empty" role="status">Loading stops…</p>`
    this.bind()
    this.panel.querySelector("[data-service-back]")?.focus()
    this.load()
    this.ageTimer = setInterval(() => this.renderAge(), 1000)
  }

  stop() {
    this.stopped = true
    this.panel.classList.remove("tm-service-panel")
    clearInterval(this.refreshTimer)
    clearInterval(this.ageTimer)
    this.controller?.abort()
  }

  async load() {
    if (this.stopped) return
    this.controller?.abort()
    this.controller = new AbortController()
    const request = ++this.request

    try {
      const params = new URLSearchParams({
        feed: String(this.service.feed),
        trip: this.service.trip,
        date: this.service.date,
        ...(this.service.seq != null ? {seq: String(this.service.seq)} : {}),
        ...(this.service.at != null ? {at: String(this.service.at)} : {}),
      })
      const response = await fetch(`/api/service?${params}`, {signal: this.controller.signal, headers: {accept: "application/json"}})
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const result = await response.json()
      if (this.stopped || request !== this.request) return
      this.result = result
      this.error = null
      // A timetable alone doesn't change; live times are asked for again.
      if (result.live === "live" && !this.refreshTimer) this.refreshTimer = setInterval(() => this.load(), REFRESH_MS)
    } catch (error) {
      if (error.name === "AbortError" || this.stopped || request !== this.request) return
      this.error = error.message
    }

    this.render()
  }

  backHtml() {
    return (
      `<div class="tm-service-back">` +
      `<button type="button" class="ui-button ui-button--quiet ui-button--small" data-service-back>Back to departures</button>` +
      `</div>`
    )
  }

  render() {
    if (this.stopped) return

    if (!this.result) {
      const sentence =
        this.error === "HTTP 404"
          ? `<p class="ui-empty tm-departures-empty">Service not found. Its timetable may have changed since the board loaded.</p>`
          : `<div class="ui-notice" data-status="failure" role="alert">` +
            `<span>Stops failed to load (${escapeHtml(this.error || "no answer")}).</span>` +
            `<button type="button" class="ui-button ui-button--quiet ui-button--small ui-notice-end" data-service-retry>Retry</button></div>`
      this.panel.innerHTML = this.backHtml() + sentence
      this.bind()
      return
    }

    // A failed refresh keeps the last stops and says so above them.
    const failure = this.error
      ? `<div class="ui-notice" data-status="failure" role="alert">` +
        `<span>Live times failed to load (${escapeHtml(this.error)}).</span>` +
        `<button type="button" class="ui-button ui-button--quiet ui-button--small ui-notice-end" data-service-retry>Retry</button></div>`
      : ""

    const scroll = this.panel.querySelector(".tm-service")?.scrollTop || 0
    const focused = document.activeElement
    const focusedStation = this.panel.contains(focused) ? focused.getAttribute("data-service-station") : null
    const backFocused = this.panel.contains(focused) && focused.hasAttribute("data-service-back")

    this.panel.innerHTML = this.backHtml() + failure + this.headHtml() + this.callsHtml()
    this.bind()
    this.renderAge()

    // The first time, the station it was opened from is brought into view;
    // a refresh keeps the reader's place and focus.
    const list = this.panel.querySelector(".tm-service")
    if (!this.placed) {
      this.placed = true
      const here = list?.querySelector(".tm-call[aria-current]")
      if (here) list.scrollTop = Math.max(0, here.offsetTop - list.offsetTop - list.clientHeight / 3)
    } else if (list) {
      list.scrollTop = scroll
    }

    // Focus comes back without scrolling, or the Back button would pull the
    // list to its top.
    if (backFocused) this.panel.querySelector("[data-service-back]")?.focus({preventScroll: true})
    else if (focusedStation) this.panel.querySelector(`[data-service-station="${focusedStation}"]`)?.focus({preventScroll: true})
  }

  headHtml() {
    const {line = {}, destination, live, timezone, cancelled, calls} = this.result
    const first = calls.find((call) => call.scheduled)
    const day =
      first && dayKey(timezone).format(new Date(first.scheduled * 1000)) !== dayKey(timezone).format(new Date())
        ? `<span class="ui-sep">·</span><span>${escapeHtml(dayFormat(timezone).format(new Date(first.scheduled * 1000)))}</span>`
        : ""

    const source =
      live === "live"
        ? `<span class="ui-badge" data-status="progress"><span class="ui-dot"></span>Live</span>` +
          `<span class="tm-departures-age ui-mono" aria-live="off" data-service-age></span>`
        : `<span class="ui-label">Timetable</span>`

    const notice = cancelled
      ? `<div class="ui-notice" data-status="${DEPARTURE_STATES.cancelled.role}" role="status">This service is cancelled.</div>`
      : live === "unavailable"
        ? `<div class="ui-notice" data-status="warning" role="status">Live times unavailable. Showing the timetable.</div>`
        : ""

    return (
      `<div class="tm-service-title">` +
      `<span class="tm-service-destination">${escapeHtml(destination ? `To ${destination}` : line.name || "Service")}</span>` +
      `<span class="tm-departure-line">` +
      `<span class="tm-swatch-line" style="--swatch: ${safeColor(line.color)}" aria-hidden="true"></span>` +
      `<span class="ui-truncate">${escapeHtml(line.name || "")}${line.agency && line.agency !== line.name ? ` · ${escapeHtml(line.agency)}` : ""}</span>` +
      day +
      `</span></div>` +
      `<div class="tm-departures-head">${source}</div>${notice}`
    )
  }

  callsHtml() {
    const {calls, timezone} = this.result
    const clock = clockFormat(timezone)
    const now = Date.now() / 1000
    const last = calls.length - 1

    const rows = calls.map((call, index) => {
      const state = DEPARTURE_STATES[call.status] || DEPARTURE_STATES.scheduled
      const word = state.word(call, now)
      const shown = call.scheduled ? clock.format(new Date(call.scheduled * 1000)) : "—"
      const expected = call.scheduled && call.time !== call.scheduled ? clock.format(new Date(call.time * 1000)) : null
      const here = call.station != null && this.here.has(call.station)
      const passed = call.time != null && call.time + PASSED_AFTER_S < now && call.status !== "cancelled"

      // A long stop shows when it arrives as well as when it leaves.
      const arrives =
        index > 0 && index < last && call.arrival && call.departure && call.departure - call.arrival >= 60
          ? `arr. ${clock.format(new Date(call.arrival * 1000))}`
          : null
      const only =
        index > 0 && index < last && !call.pickup ? "Set down only" : index > 0 && index < last && !call.drop_off ? "Pick up only" : null

      const notes = [
        call.platform ? `<span title="Platform ${escapeHtml(call.platform)}">Plat. ${escapeHtml(call.platform)}</span>` : null,
        arrives ? `<span class="ui-mono">${escapeHtml(arrives)}</span>` : null,
        only ? `<span>${only}</span>` : null,
        here ? `<span>This station</span>` : null,
      ].filter(Boolean)

      const name =
        call.station != null && call.lng != null && call.lat != null
          ? `<button type="button" class="tm-call-station ui-truncate" data-service-station="${index}"` +
            ` title="Show ${escapeHtml(call.name)} on the map">${escapeHtml(call.name)}</button>`
          : `<span class="tm-call-name ui-truncate">${escapeHtml(call.name || "—")}</span>`

      const label = [
        `${shown} ${index === last ? "arrives at" : "leaves"} ${call.name}`,
        call.platform ? `platform ${call.platform}` : null,
        arrives,
        only,
        here ? "this station" : null,
        passed ? "passed" : null,
        word ? (call.status === "late" ? `${minutes(call.delay)} minutes late, expected ${expected}` : word) : null,
      ]
        .filter(Boolean)
        .join(", ")

      // A stop left behind says so with a tick as well as its grey, unless
      // its live time already has a word.
      const status = word
        ? `<span class="tm-departure-status" ${state.role ? `data-status="${state.role}"` : ""}` +
          `${expected ? ` title="Expected ${escapeHtml(expected)}"` : ""}>${escapeHtml(word)}</span>`
        : passed
          ? `<span class="tm-departure-status" title="Passed"><span aria-hidden="true">✓</span></span>`
          : ""

      return (
        `<li class="tm-call" aria-label="${escapeHtml(label)}"` +
        `${here ? ` aria-current="location"` : ""}${passed ? " data-passed" : ""}${call.status === "cancelled" ? " data-cancelled" : ""}>` +
        `<span class="tm-departure-time ui-mono">${escapeHtml(shown)}</span>` +
        `<span class="tm-departure-main">${name}` +
        (notes.length ? `<span class="tm-departure-line">${notes.join(`<span class="ui-sep">·</span>`)}</span>` : "") +
        `</span>${status}</li>`
      )
    })

    return `<ol class="tm-departures tm-service" aria-label="Stops">${rows.join("")}</ol>`
  }

  renderAge() {
    const age = this.panel.querySelector("[data-service-age]")
    const updated = this.result?.updated_at
    if (!age || !updated) return
    const seconds = Math.max(0, Math.round(Date.now() / 1000 - updated))
    age.textContent = seconds < 60 ? `updated ${seconds}s ago` : `updated ${Math.floor(seconds / 60)}m ago`
    age.classList.toggle("tm-departures-age--stale", seconds > STALE_AFTER_S)
  }

  bind() {
    this.panel.querySelector("[data-service-back]")?.addEventListener("click", (event) => {
      event.stopPropagation()
      this.onBack?.()
    })

    this.panel.querySelector("[data-service-retry]")?.addEventListener("click", (event) => {
      event.stopPropagation()
      this.load()
    })

    this.panel.querySelectorAll("[data-service-station]").forEach((button) =>
      button.addEventListener("click", (event) => {
        event.stopPropagation()
        const call = this.result?.calls[Number(button.getAttribute("data-service-station"))]
        if (call) this.onStation?.({lng: call.lng, lat: call.lat, name: call.name})
      })
    )
  }
}
