# Transitmaps

An Apple Maps-style transit view built with Phoenix LiveView and MapLibre GL:
a muted basemap with bold, color-coded transit lines and station markers,
with per-mode toggles (metro, tram, rail, intercity, ferry, bus, coach).

Any GTFS feed in the world can be imported; the map shows whatever you've
loaded. Seeded with Great Britain's national rail network.

## Running

```sh
mix setup          # deps, database, assets
mix phx.server     # then visit http://localhost:4000
```

The local Postgres data directory lives in `.pgdata/` (no PostGIS required).
Start it with:

```sh
pg_ctl -D .pgdata -l .pgdata/pg.log start
```

## Importing GTFS feeds

```sh
mix gtfs.import <name> <url-or-zip-path>

# Great Britain national rail (updated daily, includes shapes):
mix gtfs.import gb-rail https://storage.travelwhiz.app/generated-gtfs/gb-nationalrail.gtfs.zip

# Regional bus/metro/tram feeds from the same project, e.g. South East + London:
mix gtfs.import se-busmetro https://storage.travelwhiz.app/generated-gtfs/uk-busmetro-SE.gtfs.zip
```

Re-importing under the same name replaces that feed's data. Downloads are
cached in `priv/gtfs_cache/`.

The importer is schedule-free: it stores each route with a simplified
representative geometry (up to 6 most-used service patterns) and each
station tagged with the mode categories serving it, keeping API payloads
small enough to render the whole country at once.

## Architecture

- `Transitmaps.Gtfs.Importer` — streaming GTFS zip import (routes, trips,
  shapes, stop_times, stops), never loads large files wholesale
- `Transitmaps.Gtfs.RouteTypes` — maps basic + extended GTFS route types to
  display categories
- `Transitmaps.Geometry` — Douglas-Peucker polyline simplification
- `Transitmaps.Gtfs` — GeoJSON FeatureCollection queries per category
- `TransitmapsWeb.GeoController` — `/api/routes.geojson`, `/api/stops.geojson`
- `TransitmapsWeb.MapLive` + `assets/js/transit_map.js` — LiveView page and
  MapLibre hook; layers lazy-load per category on first toggle
