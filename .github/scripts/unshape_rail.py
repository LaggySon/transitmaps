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


def too_late(time):
    hours = time.split(":", 1)[0].strip()
    return hours.isdigit() and int(hours) > 255


def main(src, dst):
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        with zin.open("stop_times.txt") as f:
            late_trips = {
                row["trip_id"]
                for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))
                if too_late(row.get("arrival_time") or "") or too_late(row.get("departure_time") or "")
            }
        print(f"leaving out {len(late_trips)} trips timed past hour 255")

        with zin.open("routes.txt") as f:
            # Renfe pads its route ids with spaces in routes.txt, not trips.txt.
            rail_routes = {
                row["route_id"].strip()
                for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))
                if rail(row["route_type"])
            }

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
                for row in reader:
                    if row["trip_id"] in late_trips:
                        continue
                    if info.filename == "trips.txt" and row["route_id"].strip() in rail_routes:
                        row["shape_id"] = ""
                    writer.writerow(row)
                text.flush()
                text.detach()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
