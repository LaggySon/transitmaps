"""Drops the shapes a GTFS feed gives its trains, so pfaedle traces them.

pfaedle only traces trips without a shape. Sweden's national feed shapes
its buses along the road but joins its trains' stations with straight
lines, which the map can't draw; clearing those trips' shape_id lets pfaedle
trace them along the railway, while every other trip keeps its own shape.

Trips timed past hour 255 (Norway has a multi-day one) are left out too:
pfaedle refuses the whole feed over them.

Usage: unshape_rail.py in.zip out.zip
"""

import csv
import io
import sys
import zipfile


def rail(route_type):
    try:
        t = int(route_type)
    except ValueError:
        return False
    return t == 2 or 100 <= t < 200


def field(fieldnames, name):
    """The column called `name`: Renfe pads its header names with spaces."""
    return next((f for f in fieldnames if f.strip() == name), None)


def too_late(time):
    hours = time.split(":", 1)[0].strip()
    return hours.isdigit() and int(hours) > 255


def main(src, dst):
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        with zin.open("stop_times.txt") as f:
            reader = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))
            trip_id = field(reader.fieldnames, "trip_id")
            times = [field(reader.fieldnames, name) for name in ("arrival_time", "departure_time")]
            late_trips = {
                row[trip_id].strip()
                for row in reader
                if any(too_late(row[time] or "") for time in times)
            }
        print(f"leaving out {len(late_trips)} trips timed past hour 255")

        with zin.open("routes.txt") as f:
            # Renfe pads its route ids with spaces in routes.txt, not trips.txt.
            reader = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))
            route_id, route_type = field(reader.fieldnames, "route_id"), field(reader.fieldnames, "route_type")
            rail_routes = {row[route_id].strip() for row in reader if rail(row[route_type].strip())}

        for info in zin.infolist():
            with zin.open(info) as fin, zout.open(info.filename, "w", force_zip64=True) as fout:
                if info.filename not in ("trips.txt", "stop_times.txt") or (
                    info.filename == "stop_times.txt" and not late_trips
                ):
                    while chunk := fin.read(1 << 20):
                        fout.write(chunk)
                    continue

                reader = csv.DictReader(io.TextIOWrapper(fin, encoding="utf-8-sig"))
                text = io.TextIOWrapper(fout, encoding="utf-8", newline="")
                writer = csv.DictWriter(text, fieldnames=reader.fieldnames, lineterminator="\n")
                writer.writeheader()
                trip_id = field(reader.fieldnames, "trip_id")
                if info.filename == "trips.txt":
                    route_id, shape_id = field(reader.fieldnames, "route_id"), field(reader.fieldnames, "shape_id")
                for row in reader:
                    if row[trip_id].strip() in late_trips:
                        continue
                    if info.filename == "trips.txt" and shape_id and row[route_id].strip() in rail_routes:
                        row[shape_id] = ""
                    writer.writerow(row)
                text.flush()
                text.detach()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
