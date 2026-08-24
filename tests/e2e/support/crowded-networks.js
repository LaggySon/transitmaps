const line = (name, category, color, coordinates) => ({
  type: "Feature",
  geometry: {type: "MultiLineString", coordinates: [coordinates]},
  properties: {
    name,
    long_name: name,
    agency: "London visual fixture",
    category,
    color,
    text_color: "#FFFFFF",
  },
})

// Catmull-Rom interpolation follows every supplied network point while
// replacing the long synthetic chords with the broad curves visible in the
// real Heathrow layout. Production geometry receives equivalent server-side
// corner rounding; this keeps the browser fixture representative of it.
const smooth = (coordinates, steps = 5) => {
  if (coordinates.length < 3) return coordinates

  const points = []
  for (let index = 0; index < coordinates.length - 1; index++) {
    const p0 = coordinates[Math.max(0, index - 1)]
    const p1 = coordinates[index]
    const p2 = coordinates[index + 1]
    const p3 = coordinates[Math.min(coordinates.length - 1, index + 2)]

    for (let step = 0; step < steps; step++) {
      const t = step / steps
      const t2 = t * t
      const t3 = t2 * t
      points.push([
        0.5 *
          (2 * p1[0] +
            (-p0[0] + p2[0]) * t +
            (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 +
            (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3),
        0.5 *
          (2 * p1[1] +
            (-p0[1] + p2[1]) * t +
            (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 +
            (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3),
      ])
    }
  }

  points.push(coordinates[coordinates.length - 1])
  return points
}

const curvedLine = (name, category, color, coordinates) =>
  line(name, category, color, smooth(coordinates))

const station = (name, category, coordinates, color) => ({
  type: "Feature",
  geometry: {type: "Point", coordinates},
  properties: {
    name,
    station: true,
    categories: [category],
    color,
    lines: [{name: `${name} service`, category, agency: "London visual fixture", color}],
  },
})

export const CROWDED_NETWORKS = {
  heathrow: {
    center: [-0.447, 51.478],
    zoom: 12.6,
    routes: [
      curvedLine("Elizabeth line", "rail", "#6950A1", [
        [-0.525, 51.520], [-0.472, 51.510], [-0.438, 51.501], [-0.420, 51.503],
        [-0.390, 51.505],
      ]),
      curvedLine("Elizabeth line", "rail", "#6950A1", [
        [-0.438, 51.501], [-0.448, 51.493], [-0.4541, 51.4719], [-0.468, 51.467],
        [-0.4906, 51.4701],
      ]),
      curvedLine("Elizabeth line", "rail", "#6950A1", [
        [-0.4541, 51.4719], [-0.444, 51.465], [-0.441, 51.459], [-0.4455, 51.4583],
        [-0.455, 51.462], [-0.4541, 51.4719],
      ]),
      curvedLine("Great Western Railway", "rail", "#1D56A5", [
        [-0.525, 51.521], [-0.472, 51.511], [-0.438, 51.502], [-0.420, 51.504],
        [-0.390, 51.506],
      ]),
      curvedLine("Piccadilly", "metro", "#2D65B0", [
        [-0.4906, 51.4695], [-0.474, 51.469], [-0.4541, 51.4714], [-0.438, 51.467],
        [-0.423, 51.466], [-0.405, 51.469],
      ]),
      curvedLine("Piccadilly", "metro", "#2D65B0", [
        [-0.4541, 51.4714], [-0.453, 51.464], [-0.4455, 51.4588], [-0.435, 51.461],
        [-0.423, 51.466],
      ]),
      curvedLine("South Western Railway", "rail", "#2467C9", [
        [-0.535, 51.443], [-0.480, 51.447], [-0.430, 51.452], [-0.382, 51.458],
      ]),
    ],
    stops: [
      station("West Drayton", "rail", [-0.472, 51.5105], "#1D56A5"),
      station("Hayes & Harlington", "rail", [-0.420, 51.5035], "#6950A1"),
      station("Terminal 5", "rail", [-0.4906, 51.4701], "#6950A1"),
      station("Heathrow Terminals 2 & 3", "rail", [-0.4541, 51.4719], "#6950A1"),
      station("Terminal 4", "rail", [-0.4455, 51.4583], "#6950A1"),
      station("Terminal 5", "metro", [-0.4896, 51.4711], "#2D65B0"),
      station("Heathrow Terminals 2 & 3", "metro", [-0.4533, 51.4714], "#2D65B0"),
      station("Terminal 4", "metro", [-0.4464, 51.4588], "#2D65B0"),
      station("Hatton Cross", "metro", [-0.423, 51.466], "#2D65B0"),
      station("Staines", "rail", [-0.505, 51.446], "#2467C9"),
    ],
  },
  clapham: {
    center: [-0.1703, 51.4642],
    zoom: 14.8,
    routes: [
      line("Southern", "rail", "#6ABF40", [
        [-0.205, 51.451], [-0.188, 51.456], [-0.177, 51.461], [-0.1703, 51.4642],
        [-0.161, 51.471], [-0.146, 51.482], [-0.129, 51.491],
      ]),
      line("South Western Railway", "rail", "#173B7A", [
        [-0.183, 51.441], [-0.179, 51.451], [-0.174, 51.460], [-0.1703, 51.4642],
        [-0.157, 51.472], [-0.139, 51.482], [-0.121, 51.494],
      ]),
      line("South Western Railway", "rail", "#173B7A", [
        [-0.211, 51.477], [-0.195, 51.473], [-0.180, 51.468], [-0.1703, 51.4642],
        [-0.163, 51.456], [-0.159, 51.445],
      ]),
      line("Windrush line", "metro", "#DC241F", [
        [-0.191, 51.447], [-0.181, 51.455], [-0.1703, 51.4642], [-0.160, 51.472],
        [-0.145, 51.480], [-0.129, 51.486],
      ]),
      line("Mildmay line", "metro", "#0B8F9C", [
        [-0.196, 51.474], [-0.184, 51.468], [-0.1703, 51.4642], [-0.154, 51.466],
        [-0.137, 51.471], [-0.120, 51.478],
      ]),
      line("Gatwick Express", "intercity", "#E5428C", [
        [-0.176, 51.441], [-0.174, 51.452], [-0.1703, 51.4642], [-0.157, 51.476],
        [-0.144, 51.489],
      ]),
    ],
    stops: [station("Clapham Junction", "rail", [-0.1703, 51.4642], "#173B7A")],
  },
  waterloo: {
    center: [-0.1132, 51.5033],
    zoom: 14.8,
    routes: [
      line("South Western Railway", "rail", "#173B7A", [
        [-0.151, 51.478], [-0.138, 51.486], [-0.126, 51.494], [-0.119, 51.500],
        [-0.1132, 51.5033],
      ]),
      line("South Western Railway", "rail", "#173B7A", [
        [-0.143, 51.468], [-0.132, 51.480], [-0.122, 51.493], [-0.1132, 51.5033],
      ]),
      line("Southeastern", "rail", "#12A8D4", [
        [-0.1132, 51.5033], [-0.101, 51.504], [-0.087, 51.505], [-0.070, 51.506],
      ]),
      line("Bakerloo", "metro", "#B36305", [
        [-0.126, 51.484], [-0.119, 51.494], [-0.1132, 51.5033], [-0.116, 51.512],
        [-0.125, 51.520],
      ]),
      line("Northern", "metro", "#111111", [
        [-0.099, 51.482], [-0.105, 51.493], [-0.1132, 51.5033], [-0.122, 51.510],
        [-0.135, 51.516],
      ]),
      line("Jubilee", "metro", "#8D979D", [
        [-0.145, 51.508], [-0.130, 51.506], [-0.1132, 51.5033], [-0.095, 51.500],
        [-0.076, 51.500],
      ]),
      line("Waterloo & City", "metro", "#76D0BD", [
        [-0.1132, 51.5033], [-0.105, 51.509], [-0.096, 51.514], [-0.087, 51.518],
      ]),
    ],
    stops: [station("London Waterloo", "rail", [-0.1132, 51.5033], "#173B7A")],
  },
  victoria: {
    center: [-0.1439, 51.4952],
    zoom: 14.8,
    routes: [
      line("Southern", "rail", "#6ABF40", [
        [-0.169, 51.467], [-0.160, 51.478], [-0.151, 51.488], [-0.1439, 51.4952],
      ]),
      line("Gatwick Express", "intercity", "#E5428C", [
        [-0.162, 51.463], [-0.155, 51.476], [-0.149, 51.488], [-0.1439, 51.4952],
      ]),
      line("Southeastern", "rail", "#12A8D4", [
        [-0.154, 51.468], [-0.150, 51.480], [-0.1439, 51.4952],
      ]),
      line("Victoria", "metro", "#0098D4", [
        [-0.151, 51.477], [-0.148, 51.486], [-0.1439, 51.4952], [-0.139, 51.504],
        [-0.136, 51.514],
      ]),
      line("Circle", "metro", "#FFD300", [
        [-0.170, 51.494], [-0.157, 51.494], [-0.1439, 51.4952], [-0.130, 51.498],
        [-0.116, 51.502],
      ]),
      line("District", "metro", "#00782A", [
        [-0.170, 51.4936], [-0.157, 51.4936], [-0.1439, 51.4948], [-0.130, 51.4976],
        [-0.116, 51.5016],
      ]),
    ],
    stops: [station("London Victoria", "rail", [-0.1439, 51.4952], "#12A8D4")],
  },
}

export const mockCrowdedTransitApis = async (page, scene) => {
  await page.route("**/api/routes.geojson?cats=*", async (request) => {
    const category = new URL(request.request().url()).searchParams.get("cats")
    await request.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: scene.routes.filter((feature) => feature.properties.category === category),
      }),
    })
  })

  await page.route("**/api/stops.geojson?cats=*", async (request) => {
    const category = new URL(request.request().url()).searchParams.get("cats")
    await request.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        type: "FeatureCollection",
        features: scene.stops.filter((feature) => feature.properties.categories.includes(category)),
      }),
    })
  })
}
