"""Build a chord-reader training set: one labelled crop per chord, plus the finder's junk words labelled "not a chord".

usage: python3.12 build_train.py OUT_DIR [--gen GEN_DIR ...] [--anthology PAGES_DIR COP_DIR] [--val 0.05] [--seed 1]
                                  [--literal] [--cap N]

--literal labels each crop with what is printed (D-7, Dmi7, CMA7, Bb7(b9)) instead of one canonical spelling; the
app converts the reading afterwards (score_reads.norm). A first fine-tune with canonical labels made the model
forget spellings it already read (D-7 came back Db7). --cap N keeps at most N training crops per label, so the
anthology's thousands of C7, F and D7 don't pull every reading toward them.

Sources
- Generated sheets (gen.py --variety): chord boxes from the coloured answer key (key.py), labels from what MuseScore
  printed (the sheet's "printed" list). Copisteria output in GEN_DIR/cop/cop-<page>/.
- The Public Domain Song Anthology: chord boxes and text from the PDFs (pdf_truth.py extract), translated from the
  Opus Chords font's private symbols (B¨ = Bb, D‹ = Dm, 7€5 = 7b5 ...).

Crops
- Every chord is cut from its exact box with the finder's padding (0.35 staff space, jittered for training).
- The finder also runs on every page: a word that holds one chord's ink is cut as the finder would cut it (same
  label); a word that holds no chord ink is junk, labelled "~" (not a chord). Partial and merged words are skipped.
- Training crops get random changes: margins, resolution, blur, noise, stroke weight, tilt, contrast, JPEG.

Labels are canonical chord names (score_reads.norm): Cmaj7, Dm7, F#m7b5, Bb7#9/D. Whole sheets and songs go to
either the training or the checking split. Writes OUT_DIR/images/..., train.txt and val.txt (path<TAB>label), the
format PaddleOCR's recogniser training reads, and stats.json.
"""

import glob
import io
import json
import os
import random
import re
import sys

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from find import find, load  # noqa: E402
from key import chord_boxes  # noqa: E402
from score_reads import is_chord, norm  # noqa: E402

NONE = "■"   # "not a chord". "~" looked like a minus sign and leaked into chords (D-7 read as D~7)
OPUS = [("Œ„Š", "maj"), ("¨", "b"), ("©", "#"), ("‹", "m"), ("º", "o"), ("€", "b"), ("&", "#"), ("“", "sus"),
        ("Ø", "ø")]
# What each Opus Chords symbol looks like on the page, for literal labels (the maj sign is left out: its glyph is
# not known)
OPUS_LITERAL = [("¨", "b"), ("©", "#"), ("‹", "m"), ("º", "°"), ("€", "b"), ("&", "#"), ("“", "sus"), ("Ø", "ø")]
LITERAL = False


def anthology_label(text):
    """Opus Chords text to a chord name (or, with --literal, to what it looks like), or None for unmapped glyphs."""
    t = text.strip()
    if LITERAL:
        if "Œ" in t or "„" in t or "Š" in t:
            return None
        for a, b in OPUS_LITERAL:
            t = t.replace(a, b)
        return t if is_chord(t.replace("°", "o")) and not re.search(r"[^A-Ga-z0-9#()/+\-.ø°]", t) else None
    for a, b in OPUS:
        t = t.replace(a, b)
    if re.search(r"[^A-Ga-z0-9#()/+\-.ø]", t) or not is_chord(t):
        return None
    return norm(t)


def page_sp(layout):
    sps = [s["sp"] for s in layout["staves"]] or [layout.get("sp", 12)]
    return float(np.median(sps))


def nudge(im, rng):
    """Move, tilt and resize each character (connected piece of ink) a little on its own, so a font's identical
    glyphs vary the way a copyist's hand does. The pieces are the rendered ink, only moved."""
    from scipy import ndimage
    a = np.asarray(im)
    lab, n = ndimage.label(a < 160)
    if n < 2 or n > 40:
        return im
    out = np.full(a.shape, 255, dtype=np.uint8)
    h = a.shape[0]
    for k, sl in enumerate(ndimage.find_objects(lab), 1):
        if sl is None:
            continue
        piece = np.where(lab[sl] == k, a[sl], 255).astype(np.uint8)
        p = Image.fromarray(piece)
        f = rng.uniform(0.9, 1.12)
        p = p.resize((max(1, round(p.width * f)), max(1, round(p.height * f))), Image.BILINEAR)
        p = p.rotate(rng.uniform(-7, 7), resample=Image.BILINEAR, expand=True, fillcolor=255)
        cy, cx = (sl[0].start + sl[0].stop) / 2, (sl[1].start + sl[1].stop) / 2
        cy += rng.uniform(-0.05, 0.05) * h
        cx += rng.uniform(-0.04, 0.04) * h
        y0, x0 = int(round(cy - p.height / 2)), int(round(cx - p.width / 2))
        q = np.asarray(p)
        ys, xs = max(0, -y0), max(0, -x0)
        y1, x1 = min(a.shape[0], y0 + q.shape[0]), min(a.shape[1], x0 + q.shape[1])
        if y1 <= max(0, y0) or x1 <= max(0, x0):
            continue
        region = out[max(0, y0):y1, max(0, x0):x1]
        np.minimum(region, q[ys:ys + region.shape[0], xs:xs + region.shape[1]], out=region)
    return Image.fromarray(out)


def augment(im, rng):
    """Random changes that make a clean render look like a scan or a phone photo."""
    if rng.random() < 0.35:
        im = nudge(im, rng)
    if rng.random() < 0.5:                                   # lower resolution, then back up
        f = rng.uniform(0.45, 0.9)
        w, h = im.size
        im = im.resize((max(8, int(w * f)), max(8, int(h * f))), Image.BILINEAR).resize((w, h), Image.BILINEAR)
    if rng.random() < 0.25:
        im = im.filter(ImageFilter.MinFilter(3))             # thicker strokes
    elif rng.random() < 0.2:
        im = im.filter(ImageFilter.MaxFilter(3))             # thinner strokes
    if rng.random() < 0.3:
        im = im.rotate(rng.uniform(-2.5, 2.5), resample=Image.BILINEAR, expand=False, fillcolor=255)
    if rng.random() < 0.4:
        im = im.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.3)))
    a = np.asarray(im).astype(np.float32)
    if rng.random() < 0.35:                                  # grey paper, faded ink
        bg, ink = rng.uniform(190, 255), rng.uniform(0, 90)
        a = ink + (bg - ink) * (a / 255.0)
    if rng.random() < 0.4:
        a = a + np.random.default_rng(rng.randrange(1 << 30)).normal(0, rng.uniform(3, 18), a.shape)
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    if rng.random() < 0.3:
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=rng.randint(25, 85))
        im = Image.open(io.BytesIO(buf.getvalue())).convert("L")
    return im


def cut(page, box, sp, rng, train):
    """The finder's crop (export_crops.py): 0.35 sp around the box, scaled to 96 px high. Training jitters it."""
    x0, y0, x1, y1 = box
    if train:
        pads = [rng.uniform(0.1, 0.7) * sp for _ in range(4)]
    else:
        pads = [0.35 * sp] * 4
    b = (int(max(0, x0 - pads[0])), int(max(0, y0 - pads[1])), int(min(page.width, x1 + pads[2])),
         int(min(page.height, y1 + pads[3])))
    if b[2] - b[0] < 4 or b[3] - b[1] < 4:
        return None
    im = page.crop(b)
    scale = min(4.0, max(1.0, 96 / im.height))
    if scale > 1:
        im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
    if im.width > 1200:
        return None
    return augment(im, rng) if train else im


def ink_labels(gray, chords):
    """Label every chord's dark pixels with its index (first chord wins on overlap); totals per chord."""
    ink = gray < 160
    lab = np.full(ink.shape, -1, dtype=np.int32)
    totals = []
    for i, (box, _) in enumerate(chords):
        x0, y0, x1, y1 = [int(v) for v in box]
        sub = lab[y0:y1, x0:x1]
        sel = ink[y0:y1, x0:x1] & (sub < 0)
        sub[sel] = i
        totals.append(int(sel.sum()))
    return lab, totals


def pages_gen(gen_dir):
    for meta_path in sorted(glob.glob(f"{gen_dir}/sheet*.json")):
        meta = json.load(open(meta_path))
        printed = meta.get("printed")
        if not printed:
            continue
        name = os.path.basename(meta_path)[:-5]
        for png in sorted(glob.glob(f"{gen_dir}/{name}-[0-9]*.png")):
            page = png[len(f"{gen_dir}/{name}-"):-4]
            key = f"{gen_dir}/{name}-key-{page}.png"
            cop = f"{gen_dir}/cop/cop-{name}-{page}"
            if not (os.path.exists(key) and os.path.exists(f"{cop}/layout.json")):
                continue
            boxes, _ = chord_boxes(key)
            chords = []
            for i, box in sorted(boxes.items()):
                if i < len(printed) and printed[i]:
                    literal = printed[i].replace(" ", "")
                    label = literal if LITERAL else norm(printed[i])
                    chords.append((box, label if is_chord(norm(printed[i])) else None))
            yield f"gen:{os.path.basename(gen_dir)}:{name}", png, cop, chords


def pages_anthology(pages_dir, cop_dir):
    for truth_path in sorted(glob.glob(f"{pages_dir}/*.truth.json")):
        song = os.path.basename(truth_path)[: -len(".truth.json")]
        truth = json.load(open(truth_path))
        for pi, objs in enumerate(truth, 1):
            png = f"{pages_dir}/{song}-{pi}.png"
            cop = f"{cop_dir}/cop-{song}-{pi}"
            if not (os.path.exists(png) and os.path.exists(f"{cop}/layout.json")):
                continue
            chords = []
            for o in objs:
                clean = re.fullmatch(r"[A-GN][^ ]*", o["text"].strip())
                chords.append((o["box"], anthology_label(o["text"]) if clean else None))
            yield f"anth:{song}", png, cop, chords


def main():
    global LITERAL
    args = sys.argv[1:]
    LITERAL = "--literal" in args
    cap = int(args[args.index("--cap") + 1]) if "--cap" in args else 0
    out = args[0]
    gens = [args[i + 1] for i, a in enumerate(args) if a == "--gen"]
    anth = [(args[i + 1], args[i + 2]) for i, a in enumerate(args) if a == "--anthology"]
    val_share = float(args[args.index("--val") + 1]) if "--val" in args else 0.05
    rng = random.Random(int(args[args.index("--seed") + 1]) if "--seed" in args else 1)
    os.makedirs(f"{out}/images", exist_ok=True)
    lines = {"train": [], "val": []}
    stats = {"pages": 0, "chord_box": 0, "chord_finder": 0, "junk": 0, "skipped_label": 0, "skipped_word": 0}
    split_of = {}
    sources = [s for g in gens for s in pages_gen(g)] + [s for p, c in anth for s in pages_anthology(p, c)]
    for n, (group, png, cop, chords) in enumerate(sources):
        split = split_of.setdefault(group, "val" if rng.random() < val_share else "train")
        train = split == "train"
        page = Image.open(png).convert("L")
        gray = np.asarray(page)
        layout, tok = load(cop)
        sp = page_sp(layout)
        stats["pages"] += 1
        # the group names the batch (gen:b3:sheet012) or song: generator batches reuse sheet names, so the page's file
        # name alone collided across batches and later crops overwrote earlier ones under the old labels
        stem = re.sub(r"[^A-Za-z0-9]+", "_", group.split(":", 1)[1] + "-" + os.path.basename(png)[:-4])
        sub = f"images/{split}/{group.split(':')[0]}"
        os.makedirs(f"{out}/{sub}", exist_ok=True)

        def save(im, tag, label):
            path = f"{sub}/{stem}-{tag}.png"
            im.save(f"{out}/{path}")
            lines[split].append(f"{path}\t{label}")

        for i, (box, label) in enumerate(chords):
            if label is None:
                stats["skipped_label"] += 1
                continue
            im = cut(page, box, sp, rng, train)
            if im is not None:
                save(im, f"c{i}", label)
                stats["chord_box"] += 1
        # the finder's words on this page: chords as it cuts them, and its junk
        lab, totals = ink_labels(gray, chords)
        props, _ = find(gray, layout, tok)
        for j, w in enumerate(p for p in props if p["kind"] == "text"):
            if max(w["x1"] - w["x0"], w["y1"] - w["y0"]) < 0.6 * sp:
                continue                                     # the app never sends specks
            sub_lab = lab[w["y0"]:w["y1"], w["x0"]:w["x1"]]
            ids, counts = np.unique(sub_lab[sub_lab >= 0], return_counts=True)
            hold = {int(i): int(c) for i, c in zip(ids, counts)}
            box = (w["x0"], w["y0"], w["x1"], w["y1"])
            if not hold:
                im = cut(page, box, sp, rng, train)
                if im is not None:
                    save(im, f"j{j}", NONE)
                    stats["junk"] += 1
                continue
            whole = [i for i, c in hold.items() if totals[i] and c >= 0.9 * totals[i]]
            majority = [i for i, c in hold.items() if totals[i] and c >= 0.5 * totals[i]]
            if len(whole) == 1 and majority == whole and chords[whole[0]][1]:
                im = cut(page, box, sp, rng, train)
                if im is not None:
                    save(im, f"w{j}", chords[whole[0]][1])
                    stats["chord_finder"] += 1
            else:
                stats["skipped_word"] += 1
        if n % 50 == 0:
            print(n, len(sources), stats, flush=True)
    if cap:
        rng.shuffle(lines["train"])
        seen, kept = {}, []
        for l in lines["train"]:
            label = l.split("\t")[1]
            seen[label] = seen.get(label, 0) + 1
            if label == NONE or seen[label] <= cap:
                kept.append(l)
        stats["capped_away"] = len(lines["train"]) - len(kept)
        lines["train"] = kept
    for split, ls in lines.items():
        paths = [l.split("\t")[0] for l in ls]
        if len(paths) != len(set(paths)):
            raise SystemExit(f"{split}: {len(paths) - len(set(paths))} crops share a file name; labels would be wrong")
        rng.shuffle(ls)
        open(f"{out}/{split}.txt", "w").write("\n".join(ls) + "\n")
    labels = [l.split("\t")[1] for l in lines["train"]]
    stats.update(train=len(lines["train"]), val=len(lines["val"]), distinct_labels=len(set(labels)),
                 none_share=round(labels.count(NONE) / max(1, len(labels)), 3))
    json.dump(stats, open(f"{out}/stats.json", "w"), indent=1)
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
