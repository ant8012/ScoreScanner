"""Score the chord finder against the coloured answer key.

usage: python3.12 evaluate.py DATA_DIR [--draw OUT_DIR] [--quiet]

Per chord: isolated (one word box holds >=90% of its ink and no other chord), merged (its box also holds another
chord), split (spread over several boxes), missed. Also: bar and beat of isolated chords, and the word boxes that
hold no chord at all (junk a reader has to reject).
"""

import glob
import json
import os
import sys
from collections import Counter

import numpy as np
from PIL import Image, ImageDraw

from find import find, load
from key import chord_boxes


def evaluate(data, draw=None, quiet=False, params=None):
    tally = Counter()
    fails = []
    for meta_path in sorted(glob.glob(f"{data}/sheet*.json")):
        meta = json.load(open(meta_path))
        name = os.path.basename(meta_path)[:-5]
        bar_offset = 0
        for page_png in sorted(glob.glob(f"{data}/{name}-[0-9].png")):
            pg = page_png[-5]
            cop = f"{data}/cop-{name}-{pg}"
            if not os.path.exists(f"{cop}/layout.json"):
                tally["pages_without_copista"] += 1
                continue
            layout, tok = load(cop)
            gray = np.asarray(Image.open(page_png).convert("L"))
            boxes, mask = chord_boxes(f"{data}/{name}-key-{pg}.png")
            props, _ = find(gray, layout, tok, **({"p": params} if params else {}))
            text = [p for p in props if p["kind"] == "text"]
            # global bar numbers: staves top to bottom, bars left to right
            staves = sorted(range(len(layout["staves"])), key=lambda k: layout["staves"][k]["y0"])
            start, n = {}, bar_offset
            for k in staves:
                start[k] = n
                n += len(layout["staves"][k]["bars"])
            bar_offset = n
            totals = {i: int((mask == i).sum()) for i in boxes}
            per = []
            for p in text:
                sub = mask[p["y0"]:p["y1"], p["x0"]:p["x1"]]
                ids, counts = np.unique(sub[sub >= 0], return_counts=True)
                per.append(dict(zip(ids.tolist(), counts.tolist())))
                p["gbar"] = start[p["staff"]] + p["bar"] + 1
            for i, tb in boxes.items():
                truth = meta["chords"][i]
                tally["chords"] += 1
                cover = [(d.get(i, 0) / totals[i], j) for j, d in enumerate(per)]
                f, j = max(cover) if cover else (0, None)
                status = "missed"
                if f >= 0.9:
                    others = [o for o, c in per[j].items() if o != i and c >= 0.1 * totals[o]]
                    status = "merged" if others else "isolated"
                elif sum(c for c, _ in cover) >= 0.9:
                    status = "split"
                tally[status] += 1
                if status == "isolated":
                    p = text[j]
                    tight = iou(tb, (p["x0"], p["y0"], p["x1"], p["y1"]))
                    tally["tight"] += tight >= 0.8
                    tally["bar_ok"] += p["gbar"] == truth["bar"]
                    tally["beat_ok"] += p["gbar"] == truth["bar"] and p["beat"] == truth["beat"]
                    tally["beat_known"] += p["beat"] is not None
                    if p["gbar"] != truth["bar"] or p["beat"] != truth["beat"]:
                        fails.append((name, pg, truth["name"], "bar/beat", truth["bar"], truth["beat"],
                                      p["gbar"], p["beat"], p["beat_dist"]))
                else:
                    fails.append((name, pg, truth["name"], status, truth["bar"], truth["beat"]))
            junk = [p for p, d in zip(text, per) if sum(d.values()) == 0]
            tally["junk"] += len(junk)
            tally["words"] += len(text)
            tally["frames"] += sum(p["kind"] == "rehearsal" for p in props)
            if draw:
                os.makedirs(draw, exist_ok=True)
                im = Image.open(page_png).convert("RGB")
                d = ImageDraw.Draw(im)
                for (x0, y0, x1, y1) in boxes.values():
                    d.rectangle((x0 - 1, y0 - 1, x1, y1), outline=(0, 170, 0), width=1)
                for p, dd in zip(props, per + [{}] * (len(props) - len(per))):
                    colour = (0, 90, 255) if p["kind"] == "rehearsal" else ((220, 0, 0) if not dd else (255, 140, 0))
                    d.rectangle((p["x0"] - 3, p["y0"] - 3, p["x1"] + 2, p["y1"] + 2), outline=colour, width=2)
                    if p["kind"] == "text" and p["beat"] is not None:
                        d.text((p["x0"], p["y1"] + 2), f"{p['bar']}:{p['beat']:g}", fill=(120, 0, 160))
                im.save(f"{draw}/{name}-{pg}.png")
    c = tally["chords"]
    summary = {k: int(tally[k]) for k in ("chords", "isolated", "merged", "split", "missed", "tight", "bar_ok",
                                       "beat_ok", "beat_known", "words", "junk", "frames")}
    if not quiet:
        print(json.dumps(summary))
        print(f"isolated {tally['isolated']}/{c} ({100 * tally['isolated'] / max(1, c):.1f}%)  "
              f"beat right {tally['beat_ok']}/{tally['isolated']}  junk words {tally['junk']}/{tally['words']}")
    return summary, fails


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua else 0


if __name__ == "__main__":
    data = sys.argv[1]
    draw = sys.argv[sys.argv.index("--draw") + 1] if "--draw" in sys.argv else None
    summary, fails = evaluate(data, draw)
    if "--quiet" not in sys.argv:
        kinds = Counter(f[3] for f in fails)
        print(kinds)
        for f in fails[:40]:
            print(f)
