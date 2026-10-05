// Lines that share a path — two operators on one stretch of track, three bus
// routes down one street — draw side by side instead of on top of one
// another. Each line is cut into runs, and every run carries a `slot`: how
// many line-widths to shift it sideways (MapLibre's `line-offset`, which is
// measured to the right of the direction the geometry is drawn in).
//
// Lines are sampled every SAMPLE_M metres. A sample shares its path with
// every other line running within NEAR_M of it in roughly the same (or
// exactly opposite) direction. The lines sharing a sample are ordered by a
// fixed rank, so a corridor keeps the same order for as long as its members
// stay the same, and centred on the shared path. The first-ranked line's
// direction is the corridor's direction; a line drawn the other way flips the
// sign of its slot so it still lands on the same side.

const SAMPLE_M = 60
const NEAR_M = 30
const PROBE_M = 60
const PARALLEL_COSINE = Math.cos((25 * Math.PI) / 180)
// A run shorter than this takes its neighbour's slot, so a line does not
// jitter sideways where another merely brushes past it.
const MIN_RUN_M = 250

const CELL_M = NEAR_M + SAMPLE_M / 2
const M_PER_DEG_LAT = 110570

// Grid cells keyed by one small integer (fast as a Map key). Cells ~2,000 km
// apart share a key, which costs only a few candidates the distance check drops.
const cellKey = (cx, cy) => ((cx & 0x7fff) << 15) | (cy & 0x7fff)

const project = (lon, lat) => [lon * 111320 * Math.cos((lat * Math.PI) / 180), lat * M_PER_DEG_LAT]

const strandsOf = (geometry) => {
  if (!geometry) return []
  if (geometry.type === "LineString") return [geometry.coordinates]
  if (geometry.type === "MultiLineString") return geometry.coordinates
  return []
}

// A strand's vertices with extra points so no segment is longer than
// SAMPLE_M. Inserted points are only kept in the output where a run starts or
// ends; the original vertices always are.
const sampleStrand = (coords) => {
  const points = []

  coords.forEach(([lon, lat], i) => {
    const [x, y] = project(lon, lat)

    if (i > 0) {
      const prev = points[points.length - 1]
      const steps = Math.floor(Math.sqrt((x - prev.x) ** 2 + (y - prev.y) ** 2) / SAMPLE_M)

      for (let s = 1; s <= steps; s++) {
        const t = s / (steps + 1)
        points.push({
          x: prev.x + (x - prev.x) * t,
          y: prev.y + (y - prev.y) * t,
          coord: [prev.coord[0] + (lon - prev.coord[0]) * t, prev.coord[1] + (lat - prev.coord[1]) * t],
          original: false,
        })
      }
    }

    const last = points[points.length - 1]
    if (!last || last.x !== x || last.y !== y) points.push({x, y, coord: [lon, lat], original: true})
  })

  return points
}

const distanceToSegment = (px, py, x1, y1, x2, y2) => {
  const dx = x2 - x1
  const dy = y2 - y1
  const lengthSq = dx * dx + dy * dy
  const t = lengthSq === 0 ? 0 : Math.max(0, Math.min(1, ((px - x1) * dx + (py - y1) * dy) / lengthSq))
  const ex = px - (x1 + t * dx)
  const ey = py - (y1 + t * dy)
  return Math.sqrt(ex * ex + ey * ey)
}

// Every segment of every strand in one flat array — its ends, midpoint,
// unit direction and length, STRIDE numbers each — plus a grid over their
// midpoints.
const STRIDE = 9

const indexSegments = (strands) => {
  let total = 0
  strands.forEach(({points}) => (total += Math.max(0, points.length - 1)))

  const segments = new Float64Array(total * STRIDE)
  const lines = new Int32Array(total)
  const grid = new Map()
  let n = 0

  strands.forEach((strand) => {
    strand.firstSegment = n
    const {points, line} = strand

    for (let i = 0; i < points.length - 1; i++, n++) {
      const a = points[i]
      const b = points[i + 1]
      const length = Math.sqrt((b.x - a.x) ** 2 + (b.y - a.y) ** 2)
      const mx = (a.x + b.x) / 2
      const my = (a.y + b.y) / 2
      const hx = length === 0 ? 0 : (b.x - a.x) / length
      const hy = length === 0 ? 0 : (b.y - a.y) / length
      const s = n * STRIDE
      segments[s] = a.x
      segments[s + 1] = a.y
      segments[s + 2] = b.x
      segments[s + 3] = b.y
      segments[s + 4] = mx
      segments[s + 5] = my
      segments[s + 6] = hx
      segments[s + 7] = hy
      segments[s + 8] = length
      lines[n] = line

      const key = cellKey(Math.floor(mx / CELL_M), Math.floor(my / CELL_M))
      const cell = grid.get(key)
      if (cell) cell.push(n)
      else grid.set(key, [n])
    }
  })

  return {segments, lines, grid}
}

// The slot of segment `n` (of line `line`) among the lines sharing its path.
const slotOf = (n, line, {segments, lines, grid}, rank) => {
  const s = n * STRIDE
  if (segments[s + 8] === 0) return 0

  const mx = segments[s + 4]
  const my = segments[s + 5]
  const hx = segments[s + 6]
  const hy = segments[s + 7]
  const cx = Math.floor(mx / CELL_M)
  const cy = Math.floor(my / CELL_M)

  // Each line sharing the path, with how its direction compares to this
  // segment's (+1 the same way, -1 the opposite way).
  const sharing = [line]
  const directions = [1]

  for (let gx = cx - 1; gx <= cx + 1; gx++) {
    for (let gy = cy - 1; gy <= cy + 1; gy++) {
      const cell = grid.get(cellKey(gx, gy))
      if (!cell) continue

      for (let c = 0; c < cell.length; c++) {
        const m = cell[c]
        const other = lines[m]
        if (other === line) continue

        const o = m * STRIDE
        // Segments are at most SAMPLE_M long, so one whose midpoint is
        // further than CELL_M cannot come within NEAR_M.
        const ddx = segments[o + 4] - mx
        const ddy = segments[o + 5] - my
        if (ddx * ddx + ddy * ddy > CELL_M * CELL_M) continue

        const dot = hx * segments[o + 6] + hy * segments[o + 7]
        if (dot < PARALLEL_COSINE && dot > -PARALLEL_COSINE) continue
        if (sharing.includes(other)) continue
        if (distanceToSegment(mx, my, segments[o], segments[o + 1], segments[o + 2], segments[o + 3]) > NEAR_M) {
          continue
        }

        sharing.push(other)
        directions.push(dot > 0 ? 1 : -1)
      }
    }
  }

  if (sharing.length === 1) return 0

  let first = 0
  let below = 0
  for (let i = 1; i < sharing.length; i++) {
    if (rank[sharing[i]] < rank[sharing[first]]) first = i
    if (rank[sharing[i]] < rank[line]) below++
  }

  return (below - (sharing.length - 1) / 2) * directions[first]
}

// Runs of equal slot along a strand, with short runs folded into their
// neighbour so a brush past another line does not kink this one.
const runsOf = (slots, segmentLengths) => {
  const runs = []
  slots.forEach((slot, i) => {
    const last = runs[runs.length - 1]
    if (last && last.slot === slot) {
      last.end = i
      last.length += segmentLengths[i]
    } else {
      runs.push({slot, start: i, end: i, length: segmentLengths[i]})
    }
  })

  const merged = []
  runs.forEach((run) => {
    const last = merged[merged.length - 1]

    if (last && (last.slot === run.slot || run.length < MIN_RUN_M)) {
      last.end = run.end
      last.length += run.length
    } else {
      merged.push(run)
    }
  })

  // A short first run has no run before it, so it joins the one after.
  if (merged.length > 1 && merged[0].length < MIN_RUN_M) {
    merged[1].start = merged[0].start
    merged[1].length += merged[0].length
    merged.shift()
  }

  return merged
}

const runCoordinates = (points, run) => {
  const coords = [points[run.start].coord]
  for (let i = run.start + 1; i <= run.end; i++) {
    if (points[i].original) coords.push(points[i].coord)
  }
  coords.push(points[run.end + 1].coord)
  return coords
}

/**
 * Splits `features` (line features of any mode) into runs that each carry a
 * `slot` property: the line's sideways position, in line-widths, among the
 * lines sharing its path there. `rankOf(feature)` orders lines within a
 * shared path; `keyOf(feature)` says which features are the same line.
 */
export const sideBySide = (features, {keyOf, rankOf}) => {
  const keys = new Map()
  const rank = []

  features.forEach((feature) => {
    const key = keyOf(feature)
    if (!keys.has(key)) {
      keys.set(key, keys.size)
      rank.push(rankOf(feature))
    }
  })

  // Ties in rank fall back to first appearance, so the order stays stable.
  const order = [...rank.keys()].sort((a, b) => (rank[a] < rank[b] ? -1 : rank[a] > rank[b] ? 1 : a - b))
  const position = []
  order.forEach((line, i) => (position[line] = i))

  const strands = features.flatMap((feature, featureIndex) =>
    strandsOf(feature.geometry)
      .map((coords) => ({featureIndex, line: keys.get(keyOf(feature)), points: sampleStrand(coords)}))
      .filter(({points}) => points.length > 1)
  )

  const index = indexSegments(strands)
  const bySlot = features.map(() => new Map())

  strands.forEach((strand) => {
    const segmentCount = strand.points.length - 1
    const slots = new Array(segmentCount)
    const lengths = new Array(segmentCount)

    // Shapes are often far denser than the sampling, so the neighbourhood is
    // only probed every PROBE_M; the segments in between keep the last slot.
    let sinceProbe = Infinity

    for (let i = 0; i < segmentCount; i++) {
      const n = strand.firstSegment + i
      lengths[i] = index.segments[n * STRIDE + 8]

      if (sinceProbe >= PROBE_M) {
        slots[i] = slotOf(n, strand.line, index, position)
        sinceProbe = 0
      } else {
        slots[i] = slots[i - 1]
      }
      sinceProbe += lengths[i]
    }

    runsOf(slots, lengths).forEach((run) => {
      const groups = bySlot[strand.featureIndex]
      if (!groups.has(run.slot)) groups.set(run.slot, [])
      groups.get(run.slot).push(runCoordinates(strand.points, run))
    })
  })

  return features.flatMap((feature, i) =>
    [...bySlot[i]].map(([slot, lines]) => ({
      type: "Feature",
      geometry: {type: "MultiLineString", coordinates: lines},
      properties: {...feature.properties, slot},
    }))
  )
}
