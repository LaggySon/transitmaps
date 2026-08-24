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

const station = (name, category, coordinates, color) => ({
  type: "Feature",
  geometry: {type: "Point", coordinates},
  properties: {
    name,
    station: true,
    categories: [category],
    lines: [{name: `${name} service`, category, agency: "London visual fixture", color}],
  },
})

export const CROWDED_NETWORKS = {
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
