"""Cut the finder's word boxes out of pages, for reading on the phone (ScoreScanner --crop-bench).

usage: python3.12 export_crops.py OUT_DIR [--all] NAME=IMAGE:COPISTA_DIR [NAME=IMAGE:COPISTA_DIR ...]

--all also cuts the words the finder sets aside as not chords: words stacked above the chord row (tempo, style,
directions), boxed rehearsal marks and text before the music starts. Lyrics of the line above stay out. The
manifest's "kind" says which, so a reader that names what each crop is can be tried on staff text as well.

Writes OUT_DIR/crop-<id>.png and OUT_DIR/manifest.json. Every word the finder keeps above a staff is cut, junk
included, so a reader is also scored on saying "not a chord". Specks under 0.6 staff spaces are left out: the
app would never send them.
"""

import json
import os
import sys

import numpy as np
from PIL import Image

from find import find, load


def main():
    out = sys.argv[1]
    every = "--all" in sys.argv
    kinds = {"text", "dropped:stacked", "rehearsal", "dropped:before-music"} if every else {"text"}
    os.makedirs(out, exist_ok=True)
    manifest, next_id = [], 0
    for arg in (a for a in sys.argv[2:] if a != "--all"):
        name, rest = arg.split("=", 1)
        image, cop = rest.split(":", 1)
        layout, tok = load(cop)
        page = Image.open(image).convert("L")
        gray = np.asarray(page)
        props, _ = find(gray, layout, tok)
        order = {k: i for i, k in enumerate(sorted(range(len(layout["staves"])), key=lambda k: layout["staves"][k]["y0"]))}
        words = [p for p in props if p["kind"] in kinds]
        words.sort(key=lambda p: (order[p["staff"]], p["y0"] if p["kind"] != "text" else 1e9, p["x0"]))
        for p in words:
            sp = layout["staves"][p["staff"]]["sp"]
            w, h = p["x1"] - p["x0"], p["y1"] - p["y0"]
            if max(w, h) < 0.6 * sp:
                continue
            pad = 0.35 * sp
            box = (int(max(0, p["x0"] - pad)), int(max(0, p["y0"] - pad)),
                   int(min(page.width, p["x1"] + pad)), int(min(page.height, p["y1"] + pad)))
            crop = page.crop(box)
            scale = min(4.0, max(1.0, 96 / crop.height))
            if scale > 1:
                crop = crop.resize((round(crop.width * scale), round(crop.height * scale)), Image.LANCZOS)
            file = f"crop-{next_id:04d}.png"
            crop.save(os.path.join(out, file))
            manifest.append(dict(id=next_id, file=file, chart=name, line=order[p["staff"]], x0=int(p["x0"]),
                                 bar=p.get("bar", -1) + 1, beat=p.get("beat"), box=list(box),
                                 kind=p["kind"]))
            next_id += 1
        print(name, len([m for m in manifest if m["chart"] == name]), "crops")
    json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
