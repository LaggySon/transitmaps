# Transitmaps

An Apple Maps-style transit view built with Phoenix LiveView and MapLibre GL:
a muted basemap with bold, color-coded transit lines and station markers,
with per-mode toggles (metro, tram, rail, intercity, ferry, bus, coach).

[![Railway deployment](https://github.com/LaggySon/transitmaps/actions/workflows/railway-deployment.yml/badge.svg?branch=main)](https://github.com/LaggySon/transitmaps/actions/workflows/railway-deployment.yml)
[Live production map](https://transitmaps.laggi.sh)

Any GTFS feed in the world can be imported; the map shows whatever you've
loaded. Seeded with Great Britain's national rail network.

## Running

```sh
mix setup          # deps, database, assets
mix phx.server     # then visit http://localhost:4000
```

## Visual testing

The Playwright suite uses deterministic transit fixtures and captures the map
at every supported integer zoom level (4 through 19), plus desktop and mobile
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

For `gb-rail`, only feed-provided shapes are used as drawable track geometry.
Services without a shape are retained for station and operator metadata, but
are not rendered as straight stop-to-stop lines.

The TfL importer uses the public Unified API. Anonymous access works for
occasional imports; set `TFL_APP_KEY` to a registered API key for a higher
rate limit.

Re-importing under the same name replaces that feed's data. Downloads are
cached in `priv/gtfs_cache/`. The Railway deployment for `main` refreshes Great
Britain rail and TfL in the background after the web service is healthy; a
failed upstream refresh leaves the previously imported map data in place. PR
environments do not run those slow upstream imports.

In a deployed Railway release, run imports from the service shell without
Mix. Restart the service afterward so its in-memory GeoJSON cache refreshes
immediately:

```sh
bin/transitmaps eval "Transitmaps.Release.import_tfl()"
bin/transitmaps eval "Transitmaps.Release.import_gb()"
```

The `main` deployment also starts a TfL refresh in the background after each
application release. Deployment migrations remain a required pre-deploy step,
while a temporary TfL or OSM failure leaves the last successful import in place
without blocking the new release.

The `Railway deployment` GitHub Actions workflow watches the live `/health`
endpoint for Railway's deployed commit SHA. Its `production` environment adds
Vercel-style deployment history and live-site links to GitHub without starting
a duplicate deployment.

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

### Railway PR environments

Every PR deployment migrates its isolated database, then transactionally
replaces its GTFS tables with a consistent snapshot of the data currently on
`main`. The copy streams directly between PostgreSQL connections, so it does
not depend on third-party GTFS services and does not hold the full data set in
memory. A missing or failed snapshot blocks the preview deployment instead of
publishing an empty map.

One-time Railway setup:

1. Enable public TCP networking on the production PostgreSQL service.
2. Create a PostgreSQL login with `CONNECT` on the production database,
   `USAGE` on its public schema, and `SELECT` on `feeds`, `routes`, and `stops`.
3. Set `GTFS_MAIN_DATABASE_URL` on the web service to that login's production
   public URL. Store the literal URL, not a `${{Postgres.*}}` reference, because
   references resolve inside each isolated PR environment. Leave this variable
   unsealed so Railway copies it into future PR environments.

Keep this account strictly read-only: PR code can read variables copied into
its environment. The account should expose only the same transit data that the
public map API already serves.

The checked-in `environments.pr` deploy override runs `bin/prepare_pr`, while
normal environments continue to run only `bin/migrate`. The task also refuses
to run for the `main` branch and verifies that source and destination are
different PostgreSQL databases before truncating the preview tables. If the
public URL needs TLS, append `?ssl=true`.

For example, create the least-privileged source login in the production
database (replace the generated password before use):

```sql
CREATE ROLE gtfs_preview_reader LOGIN PASSWORD 'generate-a-long-random-password';
GRANT CONNECT ON DATABASE railway TO gtfs_preview_reader;
GRANT USAGE ON SCHEMA public TO gtfs_preview_reader;
GRANT SELECT ON TABLE public.feeds, public.routes, public.stops TO gtfs_preview_reader;
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
- `Transitmaps.Geometry` — polyline primitives: Douglas-Peucker
  simplification, jump/reversal splitting, loop splicing, re-trace
  dedupe, fragment stitching, and corner rounding
- `Transitmaps.Display` — which drawn lines exist, via `Identity` (one
  line per national-rail operator or per TfL-style line, with brand
  colours). Geometry is served exactly as imported: every line on its own
  centreline, lines sharing track drawn on top of one another. The rules
  for how track should actually be drawn are being rewritten from scratch
- `Transitmaps.Gtfs` — GeoJSON FeatureCollection queries per category;
  rail-family categories (rail/intercity/metro/tram) are bundled
  together, so serving one loads the family
- `Transitmaps.Journey` — schedule-free trip planner: a breadth-first
  search over the line graph (two stations are connected when one line
  serves both) that returns the fewest-transfer itinerary between two
  named stations. Surfaced as the sidebar's "Trip" panel
- `Transitmaps.Gtfs.GeoJsonCache` — ETS cache of encoded (and gzipped)
  GeoJSON responses with ETags, warmed at boot, invalidated on import and
  aged out hourly for imports run in a separate VM
- `TransitmapsWeb.GeoController` — `/api/routes.geojson`, `/api/stops.geojson`
- `TransitmapsWeb.MapLive` + `assets/js/transit_map.js` — LiveView page and
  MapLibre hook; layers lazy-load per category on first toggle. An optional
  "Live trains" setting animates markers along the drawn rail-family track
  geometry — simulated client-side from the served line shapes (the importer
  is schedule-free), so it needs no realtime feed and respects
  `prefers-reduced-motion`
