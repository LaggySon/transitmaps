// The map paints itself from the page's colour tokens (tokens.css, and the
// basemap block in ui-local.css) rather than from colours of its own, so it
// follows light and dark mode with the rest of the page. Every token is a
// `light-dark()` pair; reading it back through an element's computed colour
// resolves it for the current mode, as an rgb() string MapLibre accepts.

const TOKENS = {
  background: "--background",
  foreground: "--foreground",
  muted: "--muted-foreground",
  land: "--map-land",
  water: "--map-water",
  park: "--map-park",
  building: "--map-building",
  road: "--map-road",
  roadCasing: "--map-road-casing",
  motorway: "--map-motorway",
  motorwayCasing: "--map-motorway-casing",
  boundary: "--map-boundary",
  label: "--map-label",
  waterLabel: "--map-water-label",
}

const channels = (color) => (color.match(/[\d.]+/g) || [0, 0, 0]).slice(0, 3).map(Number)

export const withAlpha = (color, alpha) => `rgba(${channels(color).join(", ")}, ${alpha})`

export const readPalette = () => {
  const probe = document.createElement("span")
  probe.hidden = true
  document.body.appendChild(probe)

  const palette = {}
  for (const [key, token] of Object.entries(TOKENS)) {
    probe.style.color = `var(${token})`
    palette[key] = getComputedStyle(probe).color
  }
  probe.remove()

  const [r, g, b] = channels(palette.background)
  palette.dark = 0.2126 * r + 0.7152 * g + 0.0722 * b < 128
  return palette
}

// Calls `onChange` whenever the mode changes: the OS setting, or a
// `data-theme` choice on <html>. Returns a function that stops listening.
export const watchColorScheme = (onChange) => {
  const query = window.matchMedia("(prefers-color-scheme: dark)")
  const observer = new MutationObserver(onChange)
  query.addEventListener("change", onChange)
  observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})

  return () => {
    query.removeEventListener("change", onChange)
    observer.disconnect()
  }
}

// A line's colour comes from its agency's data, and a dark one (London's
// black Northern line, a navy metro) would vanish on the dark basemap. This
// is true for those lines: their perceived brightness, on a 0–255 scale, is
// low.
export const DARK_LINE = [
  "<",
  [
    "let",
    "rgba",
    ["to-rgba", ["to-color", ["get", "color"], "#6e6e73"]],
    [
      "+",
      ["*", 0.2126, ["at", 0, ["var", "rgba"]]],
      ["*", 0.7152, ["at", 1, ["var", "rgba"]]],
      ["*", 0.0722, ["at", 2, ["var", "rgba"]]],
    ],
  ],
  80,
]

// A line's own colour mixed `amount` of the way to `background` (an rgb()
// string), opaque, for lines that step back while another has focus.
export const fadedLineColor = (background, amount) => {
  const target = channels(background)
  const rgba = ["to-rgba", ["to-color", ["get", "color"], "#6e6e73"]]
  return [
    "let",
    "rgba",
    rgba,
    ["rgb", ...target.map((value, i) => ["+", ["*", ["at", i, ["var", "rgba"]], 1 - amount], value * amount])],
  ]
}
