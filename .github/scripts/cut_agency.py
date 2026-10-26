"""Cuts a GTFS feed down to one agency, leaving its shapes for pfaedle.

The Tyne and Wear Metro is published only in the Bus Open Data Service's
North East feed, among every bus in the region (a 95 MB download, 640 MB
unpacked), and its shapes there are coarse: a few points per kilometre,
with straight cuts of over 2 km. This keeps the one agency's routes, trips,
stop times, stations and calendars, and drops its shapes so pfaedle traces
every trip along OpenStreetMap's track.

`--strip-names` is a pattern cut out of stop names and trip headsigns:
BODS calls every Metro station "Haymarket (Tyne and Wear Metro Station)",
and some trips run to "South Shields Metro Station".

Usage: cut_agency.py in.zip out.zip "Agency Name" [--strip-names REGEX]
"""

import argparse
import csv
import io
import re
import zipfile


def read_csv(zin, name):
    with zin.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))


def fieldnames(zin, name):
    with zin.open(name) as f:
        return csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig")).fieldnames


def write_csv(zout, name, fields, rows):
    with zout.open(name, "w", force_zip64=True) as f:
        text = io.TextIOWrapper(f, encoding="utf-8", newline="")
        writer = csv.DictWriter(text, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        count = 0
        for row in rows:
            writer.writerow(row)
            count += 1
        text.flush()
        text.detach()
    print(f"{name}: {count} rows")


def main(src, dst, agency_name, strip_names):
    def clean(name):
        return re.sub(strip_names, "", name).strip() if strip_names else name

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        files = set(zin.namelist())

        agencies = [row for row in read_csv(zin, "agency.txt") if row["agency_name"] == agency_name]
        if not agencies:
            raise SystemExit(f"no agency called {agency_name!r}")
        agency_ids = {row["agency_id"] for row in agencies}

        routes = [row for row in read_csv(zin, "routes.txt") if row.get("agency_id") in agency_ids]
        route_ids = {row["route_id"] for row in routes}

        trips = [row for row in read_csv(zin, "trips.txt") if row["route_id"] in route_ids]
        for trip in trips:
            trip["shape_id"] = ""
            if trip.get("trip_headsign"):
                trip["trip_headsign"] = clean(trip["trip_headsign"])
        trip_ids = {row["trip_id"] for row in trips}
        service_ids = {row["service_id"] for row in trips}

        stop_times = [row for row in read_csv(zin, "stop_times.txt") if row["trip_id"] in trip_ids]
        stop_ids = {row["stop_id"] for row in stop_times}

        all_stops = {row["stop_id"]: row for row in read_csv(zin, "stops.txt")}
        parents = {all_stops[s].get("parent_station") for s in stop_ids if s in all_stops}
        stop_ids |= {p for p in parents if p and p in all_stops}

        def stops():
            for stop_id in sorted(stop_ids & all_stops.keys()):
                stop = all_stops[stop_id]
                stop["stop_name"] = clean(stop["stop_name"])
                yield stop

        write_csv(zout, "agency.txt", fieldnames(zin, "agency.txt"), agencies)
        write_csv(zout, "routes.txt", fieldnames(zin, "routes.txt"), routes)
        write_csv(zout, "trips.txt", fieldnames(zin, "trips.txt"), trips)
        write_csv(zout, "stop_times.txt", fieldnames(zin, "stop_times.txt"), stop_times)
        write_csv(zout, "stops.txt", fieldnames(zin, "stops.txt"), stops())

        for name in ("calendar.txt", "calendar_dates.txt"):
            if name in files:
                rows = (row for row in read_csv(zin, name) if row["service_id"] in service_ids)
                write_csv(zout, name, fieldnames(zin, name), rows)

        if "feed_info.txt" in files:
            zout.writestr("feed_info.txt", zin.read("feed_info.txt"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("src")
    parser.add_argument("dst")
    parser.add_argument("agency")
    parser.add_argument("--strip-names", default="")
    args = parser.parse_args()
    main(args.src, args.dst, args.agency, args.strip_names)
