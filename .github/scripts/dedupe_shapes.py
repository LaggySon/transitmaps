"""Keeps the shapes a GTFS feed's routes need to draw their track.

pfaedle gives every trip pattern its own traced shape, so a national feed
carries thousands that re-trace the same railway (1,772 for Germany's
long-distance trains), and the map's importer would read them all. Per
route, shapes are taken most-used first and kept only when they add track
the kept ones don't cover (100 m cells, at least 300 m new), which is what
the importer keeps anyway. Trips on a dropped shape are given the route's
busiest kept shape, and shapes no trip uses are left out.

Usage: dedupe_shapes.py in.zip out.zip
"""

import collections
import csv
import io
import math
import sys
import zipfile

CELL_KM = 0.1
MIN_NEW_CELLS = 3


def read_csv(zin, name):
    with zin.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig"))


def cells(points):
    """100 m cells a line passes through, sampled every 50 m."""
    out = set()
    if not points:
        return out
    ky = 110.574
    kx = 111.320 * math.cos(math.radians(points[0][1]))
    prev = None
    for lon, lat in points:
        x, y = lon * kx, lat * ky
        if prev is None:
            out.add((int(x // CELL_KM), int(y // CELL_KM)))
        else:
            px, py = prev
            steps = max(1, int(math.hypot(x - px, y - py) / (CELL_KM / 2)))
            for i in range(1, steps + 1):
                sx, sy = px + (x - px) * i / steps, py + (y - py) * i / steps
                out.add((int(sx // CELL_KM), int(sy // CELL_KM)))
        prev = (x, y)
    return out


def main(src, dst):
    with zipfile.ZipFile(src) as zin:
        uses = collections.defaultdict(collections.Counter)
        for trip in read_csv(zin, "trips.txt"):
            if trip.get("shape_id"):
                uses[trip["route_id"]][trip["shape_id"]] += 1

        shape_cells = {}
        current, points = None, []
        for row in read_csv(zin, "shapes.txt"):
            if row["shape_id"] != current:
                if current is not None:
                    shape_cells[current] = cells(points)
                current, points = row["shape_id"], []
            points.append((float(row["shape_pt_lon"]), float(row["shape_pt_lat"])))
        if current is not None:
            shape_cells[current] = cells(points)

        kept, replacement = set(), {}
        for route_id, counts in uses.items():
            covered, route_kept = set(), []
            for shape_id, _ in counts.most_common():
                shape = shape_cells.get(shape_id, set())
                if not route_kept or len(shape - covered) >= MIN_NEW_CELLS:
                    route_kept.append(shape_id)
                    covered |= shape
                else:
                    replacement[(route_id, shape_id)] = route_kept[0]
            kept.update(route_kept)
        del shape_cells

        print(f"{len(kept)} of {sum(len(c) for c in uses.values())} route shapes kept")

        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
            for info in zin.infolist():
                with zin.open(info) as fin, zout.open(info.filename, "w", force_zip64=True) as fout:
                    if info.filename not in ("trips.txt", "shapes.txt"):
                        while chunk := fin.read(1 << 20):
                            fout.write(chunk)
                        continue

                    reader = csv.DictReader(io.TextIOWrapper(fin, encoding="utf-8-sig"))
                    text = io.TextIOWrapper(fout, encoding="utf-8", newline="")
                    writer = csv.DictWriter(text, fieldnames=reader.fieldnames, lineterminator="\n")
                    writer.writeheader()
                    for row in reader:
                        if info.filename == "trips.txt":
                            key = (row["route_id"], row.get("shape_id"))
                            row["shape_id"] = replacement.get(key, row.get("shape_id"))
                            writer.writerow(row)
                        elif row["shape_id"] in kept:
                            writer.writerow(row)
                    text.flush()
                    text.detach()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
