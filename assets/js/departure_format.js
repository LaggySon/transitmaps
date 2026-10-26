// What a station's departure board and a service's run share: refresh
// timing, the state words, and the formats times are shown in.

export const REFRESH_MS = 30_000

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

export const minutes = (seconds) => Math.max(1, Math.round(seconds / 60))

export const escapeHtml = (value) =>
  String(value ?? "").replace(/[&<>'"]/g, (char) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"})[char])

export const safeColor = (value) => (/^#[0-9a-f]{6}$/i.test(value || "") ? value : "#6e6e73")

// Times are the station's own (a London board in London time, wherever the
// visitor is), 24-hour (DESIGN.md section 11).
export const clockFormat = (timeZone) =>
  new Intl.DateTimeFormat(undefined, {timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23"})
export const dayFormat = (timeZone) => new Intl.DateTimeFormat(undefined, {timeZone, weekday: "short", day: "numeric", month: "short"})
export const dayKey = (timeZone) => new Intl.DateTimeFormat("en-CA", {timeZone, year: "numeric", month: "2-digit", day: "2-digit"})
export const zoneName = (timeZone) =>
  new Intl.DateTimeFormat(undefined, {timeZone, timeZoneName: "short"}).formatToParts(new Date()).find((part) => part.type === "timeZoneName")?.value

export const viewerZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone
