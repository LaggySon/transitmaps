"""Shrinks a pfaedle-shaped GTFS zip's shapes.txt.

pfaedle traces every trip pattern at OpenStreetMap's resolution, a point
every few metres with a running distance, which makes a national feed's
shapes.txt gigabytes. The map simplifies shapes to ~2.5 m on import anyway,
so each shape is simplified here (Douglas-Peucker, 1 m) and written without
shape_dist_traveled, which nothing reads. Every other file is copied as is.

Usage: simplify_shapes.py in.zip out.zip
"""

import csv
import io
import sys
import zipfile

TOLERANCE = 0.00001  # degrees, ~1 m


def simplify(points):
    if len(points) <= 2:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        (x1, y1), (x2, y2) = points[first], points[last]
        dx, dy = x2 - x1, y2 - y1
        norm = (dx * dx + dy * dy) ** 0.5
        best, index = 0.0, None
        for i in range(first + 1, last):
            x, y = points[i]
            if norm == 0:
                d = ((x - x1) ** 2 + (y - y1) ** 2) ** 0.5
            else:
                d = abs(dy * (x - x1) - dx * (y - y1)) / norm
            if d > best:
                best, index = d, i
        if index is not None and best > TOLERANCE:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def write_shape(writer, shape_id, rows):
    rows.sort(key=lambda r: r[0])
    points = simplify([(lon, lat) for _, lon, lat in rows])
    for seq, (lon, lat) in enumerate(points, 1):
        writer.writerow([shape_id, f"{lat:.6f}", f"{lon:.6f}", seq])


def main(src, dst):
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            if info.filename != "shapes.txt":
                with zin.open(info) as fin, zout.open(info.filename, "w", force_zip64=True) as fout:
                    while chunk := fin.read(1 << 20):
                        fout.write(chunk)
                continue

            with zin.open(info) as fin, zout.open("shapes.txt", "w", force_zip64=True) as fout:
                reader = csv.DictReader(io.TextIOWrapper(fin, encoding="utf-8-sig"))
                text = io.TextIOWrapper(fout, encoding="utf-8", newline="")
                writer = csv.writer(text, lineterminator="\n")
                writer.writerow(["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"])
                # pfaedle writes each shape's points together, in order.
                current, rows = None, []
                for row in reader:
                    if row["shape_id"] != current:
                        if current is not None:
                            write_shape(writer, current, rows)
                        current, rows = row["shape_id"], []
                    rows.append((int(row["shape_pt_sequence"]), float(row["shape_pt_lon"]), float(row["shape_pt_lat"])))
                if current is not None:
                    write_shape(writer, current, rows)
                text.flush()
                text.detach()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
