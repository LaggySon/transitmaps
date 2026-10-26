# Transitmaps

A transit map built with Phoenix LiveView and MapLibre GL: a grayscale
basemap with bold, color-coded transit lines and station markers, with
per-mode toggles (metro, tram, rail, intercity, ferry, bus, coach). It
follows the system's light or dark mode.

The interface follows the Laggish design guide in [DESIGN.md](DESIGN.md):
`assets/css/tokens.css` and `assets/css/components.css` are unedited copies
from the guide, and the app's own rules live in `assets/css/ui-local.css`.

[![Railway deployment](https://github.com/LaggySon/transitmaps/actions/workflows/railway-deployment.yml/badge.svg?branch=main)](https://github.com/LaggySon/transitmaps/actions/workflows/railway-deployment.yml)
[Live production map](https://transitmaps.laggi.sh)

Visitors can add any transit agency with a public GTFS feed in the
[Mobility Database](https://mobilitydatabase.org) catalog by searching for it
in the map's menu; the server downloads it once and every visitor reads it
from this app. The map draws whichever agencies overlap the view, and the
same search box finds their stations. Opens on Great Britain's national
rail network.

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

## Agencies

Every imported feed is an agency the map can draw. Its service area (the
1st–99th percentile box of its stops) decides when the map considers it:
the browser fetches each agency in or near the view per mode
(`/api/routes.geojson?feed=ID&cats=rail&detail=low`), and merges stations
of different agencies within 250 m into one interchange marker.

- Lines come in three details: `low` below zoom 8, `mid` below 11, and
  full detail from there, each simplified to under half a pixel. Zoomed in,
  lines come in grid cells (`&cell=x,y`: 4° for mid, 1° for full) holding
  only the stretches that cross them, and stations (`/api/stops.geojson`,
  from zoom 10) in 1° cells: one train to Paris otherwise brings a whole
  national network along (`Transitmaps.Gtfs.Cells`). Data the view no
  longer needs is let go.
- The search box also finds stations: `Transitmaps.Stations` keeps an
  in-memory index of every rail, metro and tram station, one entry per
  place, rebuilt when an agency lands and hourly. Picking one flies there
  and opens its details.
- The Mobility Database feed list (`feeds_v2.csv`) is downloaded at boot and
  daily, cached in `priv/gtfs_cache/catalog.csv`; a failed download keeps the
  previous copy. Feeds that are inactive, need an API key, are listed
  without route shapes, or repeat another listing's download are left out.
- **Regional packs** (`Transitmaps.Packages`) bundle the agencies of a region
  — 16 of them, from the Bay Area and the Northeast Corridor to Central
  Europe, New Zealand and Latin American cities — for visitors who don't
  know the operators. They sit under one collapsible row in the menu,
  grouped by continent, and search finds them by the cities they cover.
  **Add** queues every member at once (one request against the queue limit)
  and flies the map there. Each member is vetted: under the import size
  limit, with trips drawn from shapes. A pack vouches for members the search
  would leave out, such as Muni (inactive in the catalog) or 511.org and
  WMATA feeds (keyed at the source, but public on MobilityData's mirror).
- Pressing **Add** on a search result queues the agency. One background
  worker downloads queued agencies one at a time from MobilityData's mirrors
  (up to 700 MB each: the importer streams the big files and keeps only
  simplified, packed lines, so even Norway's or Sweden's national feed
  peaks under 1 GB). Progress shows live in every open map, the visitor
  who asked is flown to it when it lands, and a restart resumes an
  interrupted download. At most 10 agencies can wait in the queue.
- Downloaded agencies refresh weekly. Download state lives in the
  `feed_imports` table.
- Some hand-curated feeds are partial copies of a catalog agency (MBTA,
  NYC Subway, Metro-North, NJ Transit Rail, SEPTA, MARC, Baltimore, Amtrak,
  WMATA).
  Adding the catalog agency deletes the hand-curated copy so nothing is
  drawn twice; the list lives in `Transitmaps.Agencies`.
- Visitors can hide an agency on their own map from the menu's in-view list;
  nothing is deleted.

## Departures

Clicking a station opens its departures: the next trains, with platform and
destination, and live delays and cancellations where the agency publishes
them. The board refreshes every 30 seconds while it is open, and the
station's lines are a tab away.

- **Timetables** are read at import (`Transitmaps.Gtfs.Timetable`) for
  metro, tram, rail, intercity and ferry stations, not bus stops, whose
  timetables would outweigh everything else. Only trips running in the 64
  days from two days before the import are kept, which weekly refreshes
  keep ahead of today. Each station's departures are one compressed row in
  `stop_departures` (Great Britain's 2,600 stations take about 34 MB).
  Times are shown in the agency's time zone.
- **Live times** come from GTFS Realtime trip updates the Mobility Database
  catalog lists for the agency without a key (`Transitmaps.Realtime`); a
  hand-curated feed uses the listings of the catalog agency that replaces
  it. A feed is fetched only while someone has one of its stations open, at
  most every 30 seconds, and dropped after 10 minutes unread.
- **TfL's stations** (Tube, DLR, Overground, Elizabeth line, trams) show
  TfL's live arrivals (`Transitmaps.Realtime.Tfl`); `TFL_APP_KEY` raises the
  rate limit. Where National Rail's timetable lists the same line at a
  station, the live arrivals replace it.
- National Rail has no live times: Network Rail's feeds need a registered
  account.
- `/api/departures?stops=12,34&limit=10` serves a station marker's stops
  (the `ids` on its feature).
- **A service's whole run**: clicking a departure shows every stop it
  calls at that day, with times, platforms and live times, and each stop
  opens its station on the map (`Transitmaps.Services`,
  `assets/js/service_timetable.js`). Imports keep each trip's calls in
  `trip_calls`, about 256 trips to a compressed row, hashed by trip id
  (Great Britain's 400,000 trips add about a fifth to its departures'
  size). `/api/service?feed=12&trip=T1&date=2026-10-26` serves one; the
  board's departures carry these parameters as `service`. TfL's live
  arrivals have no trip to open.

Imported data accumulates in Postgres; watch the database size on Railway
as more agencies are added.

## Importing GTFS feeds by hand

```sh
mix gtfs.import <name> <url-or-zip-path>

# Great Britain national rail (updated daily, includes shapes):
mix gtfs.import gb-rail https://storage.travelwhiz.app/generated-gtfs/gb-nationalrail.gtfs.zip

# TfL Tube, DLR, London Overground, Elizabeth line, and trams:
mix tfl.import

# Tyne and Wear Metro (see below):
mix gtfs.import tyne-wear-metro https://github.com/LaggySon/transitmaps/releases/download/shaped-feeds/tyne-wear-metro.zip

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

`--label "London Buses"` names a feed in the map's agency list; the feeds
above have labels of their own.

WMATA requires a free developer key; the importer sends `WMATA_API_KEY` as
the official feed's `api_key` request header.

Lines are drawn only from a feed's own shapes (`shapes.txt`), never by joining
stops with straight lines. Services without a shape still appear at their
stations, but aren't drawn. A feed with no shapes at all is refused, and the
agency search leaves out feeds the catalog lists as having none.

The TfL importer uses the public Unified API. Anonymous access works for
occasional imports; set `TFL_APP_KEY` to a registered API key for a higher
rate limit.

The Tyne and Wear Metro is only published in the Bus Open Data Service's
North East feed, among the region's buses, with coarse shapes. The weekly
"Shape rail feeds" workflow cuts the Metro out of it
(`.github/scripts/cut_agency.py`), traces it along OpenStreetMap, and
publishes it on the `shaped-feeds` release. The importer names its two
lines (filed as `GRN` and `YEL`) and gives them their colours.

Re-importing under the same name replaces that feed's data. Downloads are
cached in `priv/gtfs_cache/`. Railway refreshes Great Britain rail, the Tyne
and Wear Metro, and TfL in
the background after the web service is healthy; a failed upstream refresh
leaves the previously imported map data in place.

In a deployed Railway release, run imports from the service shell without
Mix. Restart the service afterward so its in-memory GeoJSON cache refreshes
immediately:

```sh
bin/transitmaps eval "Transitmaps.Release.import_tfl()"
bin/transitmaps eval "Transitmaps.Release.import_gb()"
bin/transitmaps eval "Transitmaps.Release.import_tyne_wear_metro()"
```

Railway also starts a TfL refresh in the background after every application
release. Deployment migrations remain a required pre-deploy step, while a
temporary TfL or OSM failure leaves the last successful import in place without
blocking the new release.

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

Add `transitmaps.laggi.sh` as the service's custom domain, then create the DNS
record Railway provides.

The importer stores each route with a simplified representative geometry
(up to 6 most-used service patterns) and each station tagged with the mode
categories serving it, keeping API payloads small enough to render the
whole country at once. Timetables are kept apart from that, one packed row
per station (see Departures).

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
  colours). No vertex is moved: every line sits on its own centreline and
  lines sharing track are drawn on top of one another. Track a line's
  service patterns re-trace is served once, which keeps Great Britain's
  rail response about a seventh of its raw size
- `Transitmaps.Gtfs` — GeoJSON FeatureCollection queries per category;
  rail-family categories (rail/intercity/metro/tram) are bundled
  together, so serving one loads the family
- `Transitmaps.Gtfs.GeoJsonCache` — ETS cache of encoded (and gzipped)
  GeoJSON responses with ETags, warmed at boot. Entries go stale on import
  and hourly (for imports run in a separate VM); a stale response keeps
  being served while it rebuilds in the background, one rebuild at a time
- `Transitmaps.Catalog` — the Mobility Database feed catalog and agency search
- `Transitmaps.Agencies` + `Agencies.Worker` — the feed index the map draws
  from, the on-demand download queue, progress broadcasts, weekly refresh,
  and retiring hand-curated copies
- `TransitmapsWeb.GeoController` — `/api/routes.geojson`, `/api/stops.geojson`,
  one agency per request (`?feed=`)
- `Transitmaps.Departures` + `TransitmapsWeb.DepartureController` — a
  station's next departures, its timetable with live times laid over it;
  `assets/js/station_departures.js` is the board in the station's popup
- `Transitmaps.Realtime` (with `Realtime.GtfsRt`, a reader for the trip
  updates in a GTFS Realtime feed) and `Realtime.Tfl` — live times, cached
  while stations are open
- `TransitmapsWeb.MapLive` + `assets/js/transit_map.js` — LiveView page and
  MapLibre hook. One floating menu filters what the map shows (agencies,
  modes, station names and stop markers, places). The view is kept in the
  URL hash (`#map=zoom/lat/lon`) so it can be shared
