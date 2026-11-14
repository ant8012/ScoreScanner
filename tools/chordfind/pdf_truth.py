"""Exact chord boxes from a PDF whose chord symbols are real text, and scoring the finder against them.

usage:
  python pdf_truth.py extract SONG.pdf DPI OUT.json        # chord text objects -> pixel boxes per page (pypdfium2)
  python3.12 pdf_truth.py score DATA_DIR [--draw DIR]      # finder vs boxes for every <name>-<page>.png in DATA_DIR

DATA_DIR holds <name>-<page>.png (rendered at DPI), cop-<name>-<page>/ (ScannerCheck --copista) and
<name>.truth.json from `extract`. Engravers such as Sibelius write each chord symbol as one text object in a chord
font, so its bounds are an exact answer key, for every chord row on the page. Scoring is by ink: a chord is
isolated when one word box holds at least 90% of its dark pixels and no other chord's majority.
"""

import glob
import json
import re
import os
import sys


def extract(pdf_path, dpi, out):
    import ctypes

    import pypdfium2 as pdfium
    import pypdfium2.raw as raw

    def text(o, tp):
        n = raw.FPDFTextObj_GetText(o.raw, tp.raw, None, 0)
        buf = (ctypes.c_ushort * (n // 2 + 1))()
        raw.FPDFTextObj_GetText(o.raw, tp.raw, buf, n)
        return bytes(buf)[: max(0, n - 2)].decode("utf-16-le", "ignore")

    scale = dpi / 72
    pdf = pdfium.PdfDocument(pdf_path)
    pages = []
    for pi in range(len(pdf)):
        page = pdf[pi]
        tp = page.get_textpage()
        H = page.get_height()
        chords = []
        for o in page.get_objects(filter=[raw.FPDF_PAGEOBJ_TEXT]):
            f = o.get_font()
            name = str(getattr(f, "base_name", "") or (f.get_base_name() if f is not None and hasattr(f, "get_base_name") else ""))
            if "Chord" not in name:
                continue
            l, b, r, t = o.get_bounds()
            chords.append(dict(text=text(o, tp), size=round(o.get_font_size(), 1),
                               box=[round(l * scale), round((H - t) * scale), round(r * scale), round((H - b) * scale)]))
        pages.append(chords)
    json.dump(pages, open(out, "w"), indent=1)
    print(out, [len(p) for p in pages])


def score(data, draw=None, params=None, quiet=False):
    import numpy as np
    from PIL import Image, ImageDraw

    from find import find, load

    tally = dict(chords=0, isolated=0, merged=0, split=0, missed=0, words=0, junk=0)
    fails = []
    for png in sorted(glob.glob(f"{data}/*-[0-9].png")):
        name, page = os.path.basename(png)[:-4].rsplit("-", 1)
        truth_path = f"{data}/{name}.truth.json"
        cop = f"{data}/cop-{name}-{page}"
        if not (os.path.exists(truth_path) and os.path.exists(f"{cop}/layout.json")):
            continue
        truth = json.load(open(truth_path))[int(page) - 1]
        # Engravers sometimes write several chords in one text object, or one chord as several; those objects are
        # left out of the count (their ink still marks a chord, so a word holding them is not junk).
        clean = [bool(re.fullmatch(r"[A-GN][^ ]*", c["text"].strip())) for c in truth]
        gray = np.asarray(Image.open(png).convert("L"))
        ink = gray < 160
        layout, tok = load(cop)
        props, _ = find(gray, layout, tok, **({"p": params} if params else {}))
        words = [p for p in props if p["kind"] == "text"]
        # label each chord's ink; overlapping boxes keep the first chord's label
        label = np.full(ink.shape, -1, dtype=np.int32)
        totals = []
        for i, c in enumerate(truth):
            x0, y0, x1, y1 = c["box"]
            sub = label[y0:y1, x0:x1]
            sel = ink[y0:y1, x0:x1] & (sub < 0)
            sub[sel] = i
            totals.append(int(sel.sum()))
        per = []
        for w in words:
            sub = label[w["y0"]:w["y1"], w["x0"]:w["x1"]]
            ids, counts = np.unique(sub[sub >= 0], return_counts=True)
            per.append(dict(zip(ids.tolist(), counts.tolist())))
        for i, c in enumerate(truth):
            if totals[i] == 0 or not clean[i]:
                continue
            tally["chords"] += 1
            cover = [(d.get(i, 0) / totals[i], j) for j, d in enumerate(per)]
            f, j = max(cover) if cover else (0, None)
            if f >= 0.9:
                others = [o for o, n in per[j].items() if o != i and clean[o] and totals[o] and n >= 0.5 * totals[o]]
                status = "merged" if others else "isolated"
            elif sum(v for v, _ in cover) >= 0.9:
                status = "split"
            else:
                status = "missed"
            tally[status] += 1
            if status != "isolated":
                fails.append((name, page, c["text"], status))
        tally["words"] += len(words)
        tally["junk"] += sum(1 for d in per if not d)
        if draw:
            os.makedirs(draw, exist_ok=True)
            im = Image.open(png).convert("RGB")
            d = ImageDraw.Draw(im)
            for c in truth:
                d.rectangle(c["box"], outline=(0, 170, 0), width=1)
            for w, dd in zip(words, per):
                d.rectangle((w["x0"] - 3, w["y0"] - 3, w["x1"] + 2, w["y1"] + 2),
                            outline=(220, 0, 0) if not dd else (255, 140, 0), width=2)
            for p in props:
                if p["kind"].startswith("dropped"):
                    d.rectangle((p["x0"] - 3, p["y0"] - 3, p["x1"] + 2, p["y1"] + 2), outline=(160, 160, 160), width=1)
            im.save(f"{draw}/{name}-{page}.png")
    if not quiet:
        c = tally["chords"]
        print(json.dumps(tally))
        print(f"isolated {tally['isolated']}/{c} ({100 * tally['isolated'] / max(1, c):.1f}%)  "
              f"junk words {tally['junk']}/{tally['words']}")
    return tally, fails


if __name__ == "__main__":
    if sys.argv[1] == "extract":
        extract(sys.argv[2], float(sys.argv[3]), sys.argv[4])
    else:
        draw = sys.argv[sys.argv.index("--draw") + 1] if "--draw" in sys.argv else None
        t, fails = score(sys.argv[2], draw)
        from collections import Counter
        print(Counter(f[3] for f in fails))
        for f in fails[:30]:
            print(f)
