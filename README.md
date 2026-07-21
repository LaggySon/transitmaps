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

## Visual testing

The Playwright suite uses deterministic transit fixtures and captures the map
at every supported integer zoom level (4 through 17), plus desktop and mobile
menu states:

```sh
npm install
npm run playwright:install
npm run test:e2e

# Deliberately approve a visual redesign:
npm run test:visual:update
```

Approved screenshots live under `tests/e2e/__screenshots__/`. Review snapshot
changes before committing them; they define the intended map appearance.

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

# TfL Tube, DLR, London Overground, Elizabeth line, and trams:
mix tfl.import

# Amtrak, including the complete Boston-Washington Northeast Corridor:
mix gtfs.import amtrak https://content.amtrak.com/content/gtfs/GTFS.zip

# Northeast Corridor commuter rail systems:
mix gtfs.import mbta-commuter https://cdn.mbta.com/MBTA_GTFS.zip
mix gtfs.import metro-north http://web.mta.info/developers/data/mnr/google_transit.zip
mix gtfs.import nj-transit-rail https://www.njtransit.com/rail_data.zip
mix gtfs.import septa-regional-rail https://www3.septa.org/developer/gtfs_public.zip
mix gtfs.import marc https://feeds.mta.maryland.gov/gtfs/marc

# Local rapid transit connecting to the Northeast Corridor:
mix gtfs.import mbta-rapid https://cdn.mbta.com/MBTA_GTFS.zip
mix gtfs.import nyc-subway http://web.mta.info/developers/data/nyct/subway/google_transit.zip
mix gtfs.import path http://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip
mix gtfs.import septa-rapid https://www3.septa.org/developer/gtfs_public.zip
mix gtfs.import baltimore-metro https://feeds.mta.maryland.gov/gtfs/metro
mix gtfs.import baltimore-light-rail https://feeds.mta.maryland.gov/gtfs/light-rail
WMATA_API_KEY=your_key mix gtfs.import wmata-rapid https://api.wmata.com/gtfs/rail-gtfs-static.zip
```

WMATA requires a free developer key; the importer sends `WMATA_API_KEY` as
the official feed's `api_key` request header.

The TfL importer uses the public Unified API. Anonymous access works for
occasional imports; set `TFL_APP_KEY` to a registered API key for a higher
rate limit.

Re-importing under the same name replaces that feed's data. Downloads are
cached in `priv/gtfs_cache/`.

## Railway deployment

Railway's standard Phoenix deployment uses Railpack's automatic Elixir
detection. This project uses Phoenix's generated release scripts to run
migrations before deployment and start the release, and configures:

```text
DATABASE_URL=${{Postgres.DATABASE_URL}}
ECTO_IPV6=true
LANG=en_US.UTF-8
LC_CTYPE=en_US.UTF-8
MIX_ENV=prod
PHX_HOST=transitmaps.laggi.sh
SECRET_KEY_BASE=<output of mix phx.gen.secret>
```

Add `transitmaps.laggi.sh` as the service's custom domain, then create the DNS
record Railway provides.

The importer is schedule-free: it stores each route with a simplified
representative geometry (up to 6 most-used service patterns) and each
station tagged with the mode categories serving it, keeping API payloads
small enough to render the whole country at once.

## Architecture

- `Transitmaps.Gtfs.Importer` — streaming GTFS zip import (routes, trips,
  shapes, stop_times, stops), never loads large files wholesale
- `Transitmaps.Gtfs.RouteTypes` — maps basic + extended GTFS route types to
  display categories
- `Transitmaps.Geometry` — Douglas-Peucker polyline simplification, plus
  station-area tidying: reversal hairpins are split and strands that only
  re-trace another strand of the same route are dropped
- `Transitmaps.Gtfs` — GeoJSON FeatureCollection queries per category
- `Transitmaps.Gtfs.GeoJsonCache` — ETS cache of encoded (and gzipped)
  GeoJSON responses with ETags, warmed at boot, invalidated on import and
  aged out hourly for imports run in a separate VM
- `TransitmapsWeb.GeoController` — `/api/routes.geojson`, `/api/stops.geojson`
- `TransitmapsWeb.MapLive` + `assets/js/transit_map.js` — LiveView page and
  MapLibre hook; layers lazy-load per category on first toggle
