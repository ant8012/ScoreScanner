"""Measure the answer key: gaps inside chords vs between chords, and which part of a chord lines up with its note.

usage: python3.12 analyze.py DATA_DIR
"""

import glob
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

from find import load
from key import chord_boxes


def main(data):
    inner, between, anchors = [], [], {"left": [], "centre": [], "root": []}
    for meta_path in sorted(glob.glob(f"{data}/sheet*.json")):
        meta = json.load(open(meta_path))
        name = os.path.basename(meta_path)[:-5]
        offset = 0
        for page_png in sorted(glob.glob(f"{data}/{name}-[0-9].png")):
            pg = page_png[-5]
            cop = f"{data}/cop-{name}-{pg}"
            if not os.path.exists(f"{cop}/layout.json"):
                continue
            layout, tok = load(cop)
            boxes, mask = chord_boxes(f"{data}/{name}-key-{pg}.png")
            staves = sorted(range(len(layout["staves"])), key=lambda k: layout["staves"][k]["y0"])
            start, n = {}, offset
            for k in staves:
                start[k] = n
                n += len(layout["staves"][k]["bars"])
            offset = n
            rows = {}
            for i, (x0, y0, x1, y1) in boxes.items():
                k = min((s for s in staves if layout["staves"][s]["y0"] > y1), default=None,
                        key=lambda s: layout["staves"][s]["y0"])
                if k is None:
                    continue
                st = layout["staves"][k]
                sp = st["sp"]
                sub = mask[y0:y1, x0:x1] == i
                lab, m = ndi.label(sub, structure=np.ones((3, 3)))
                spans = sorted((sl[1].start, sl[1].stop, sl[0].start, sl[0].stop) for sl in ndi.find_objects(lab))
                h = y1 - y0
                reach = spans[0][1]
                for a, b, _, _ in spans[1:]:
                    if a > reach:
                        inner.append((a - reach) / h)
                    reach = max(reach, b)
                rows.setdefault(k, []).append((x0, x1, y0, y1, h))
                truth = meta["chords"][i]
                bar = truth["bar"] - start[k] - 1
                for si, s in enumerate(layout["syms"]):
                    on = tok.get(str(si), {}).get("onset")
                    if s.get("staff") == k and s.get("bar") == bar and on is not None and \
                            s["cls"].startswith(("note", "rest")) and abs(on + 1 - truth["beat"]) < 1e-6:
                        hx0, hx1 = s["box"][0], s["box"][2]
                        rx0, rx1 = spans[0][0] + x0, spans[0][1] + x0
                        anchors["left"].append((x0 - hx0) / sp)
                        anchors["centre"].append(((x0 + x1) / 2 - (hx0 + hx1) / 2) / sp)
                        anchors["root"].append(((rx0 + rx1) / 2 - (hx0 + hx1) / 2) / sp)
                        break
            for k, row in rows.items():
                row.sort()
                for a, b in zip(row, row[1:]):
                    if min(a[3], b[3]) - max(a[2], b[2]) > 0:
                        between.append((b[0] - a[1]) / max(a[4], b[4]))
    q = lambda v: np.percentile(v, [0, 1, 5, 50, 95, 99, 100]).round(2).tolist()
    print("gap inside a chord / chord height:", len(inner), q(inner))
    print("gap between chords / chord height:", len(between), q(between))
    for k, v in anchors.items():
        v = np.array(v)
        print(f"anchor {k}: n={len(v)} median {np.median(v):.2f} sp, within 0.75 sp of median: "
              f"{np.mean(np.abs(v - np.median(v)) < 0.75):.0%}", q(v))


if __name__ == "__main__":
    main(sys.argv[1])
