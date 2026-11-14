"""Check the Swift chord finder (ScannerCore ChordFinder, via `ScannerCheck --chordfind`) against find.py.

usage: python3.12 finder_parity.py SCANNERCHECK PAGE.png:COPISTA_DIR [...]
       python3.12 finder_parity.py SCANNERCHECK --dir PAGES_DIR COP_DIR [--limit N]   (cop dir holds cop-<page>/)

For every page both finders run on the same image, layout.json and tok.json. Proposals are matched by kind and box;
matched ones must also agree on bar, beat, beat source and anchor. Prints the pages that differ and a total.
"""

import glob
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from find import find, load  # noqa: E402


def python_props(png, cop):
    gray = np.asarray(Image.open(png).convert("L"))
    layout, tok = load(cop)
    props, _ = find(gray, layout, tok)
    return [dict(x0=int(p["x0"]), y0=int(p["y0"]), x1=int(p["x1"]), y1=int(p["y1"]), kind=p["kind"],
                 bar=p.get("bar"), beat=p.get("beat"), beat_src=p.get("beat_src"), anchor=p.get("anchor"))
            for p in props]


def swift_props(check, png, cop):
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        out = f.name
    r = subprocess.run([check, "--chordfind", png, cop, out], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    props = json.load(open(out))
    os.unlink(out)
    return props


def compare(a, b):
    key = lambda p: (p["kind"], p["x0"], p["y0"], p["x1"], p["y1"])
    ka, kb = {}, {}
    for p in a:
        ka.setdefault(key(p), []).append(p)
    for p in b:
        kb.setdefault(key(p), []).append(p)
    only_py = [k for k in ka if k not in kb or len(ka[k]) != len(kb[k])]
    only_sw = [k for k in kb if k not in ka or len(ka[k]) != len(kb[k])]
    placed = []
    for k in ka.keys() & kb.keys():
        for p, q in zip(ka[k], kb[k]):
            bp = None if p["beat"] is None else round(float(p["beat"]), 6)
            bq = None if q.get("beat") is None else round(float(q["beat"]), 6)
            if (p["bar"], bp, p["beat_src"], p["anchor"]) != (q.get("bar"), bq, q.get("beat_src"), q.get("anchor")):
                placed.append((k, (p["bar"], bp, p["beat_src"], p["anchor"]),
                               (q.get("bar"), bq, q.get("beat_src"), q.get("anchor"))))
    return only_py, only_sw, placed


def main():
    check = sys.argv[1]
    pages = []
    if "--dir" in sys.argv:
        i = sys.argv.index("--dir")
        pdir, cdir = sys.argv[i + 1], sys.argv[i + 2]
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
        for png in sorted(glob.glob(f"{pdir}/*.png")):
            name = os.path.basename(png)[:-4]
            if "-key-" in name:
                continue
            cop = f"{cdir}/cop-{name}"
            if os.path.exists(f"{cop}/layout.json"):
                pages.append((png, cop))
        pages = pages[:limit] if limit else pages
    else:
        pages = [tuple(a.split(":", 1)) for a in sys.argv[2:]]
    same = props_total = 0
    for png, cop in pages:
        a, b = python_props(png, cop), swift_props(check, png, cop)
        props_total += len(a)
        only_py, only_sw, placed = compare(a, b)
        if not (only_py or only_sw or placed):
            same += 1
            continue
        print(f"DIFF {os.path.basename(png)}: python {len(a)} swift {len(b)}")
        for k in only_py[:5]:
            print("   only python:", k)
        for k in only_sw[:5]:
            print("   only swift: ", k)
        for k, p, q in placed[:5]:
            print("   placed:", k, "python", p, "swift", q)
    print(f"{same}/{len(pages)} pages identical ({props_total} proposals)")


if __name__ == "__main__":
    main()
