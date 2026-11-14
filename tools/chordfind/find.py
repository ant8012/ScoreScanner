"""Find the text above each staff and cut it into word boxes, using copisteria's symbol boxes to remove the music.

Prototype of a chord finder. Inputs: a grayscale page and copisteria's layout.json / tok.json (ScannerCheck
--copista). Output: one proposal per word of text above each staff, with its bar and an estimated beat.
"""

import json
import numpy as np
from scipy import ndimage as ndi

# Compact symbols: erase their whole box. Long ones (slurs, beams, brackets) can arch over text, so they are
# removed by shape instead.
ERASE = ("note", "rest", "accid", "dots", "artic", "flag", "fermata", "clef", "keySig", "meterSig", "dynam",
         "repeatMark", "breath", "caesura", "mordent", "trill", "tupletNum", "tuplet_", "arpeg", "grpSym",
         "mRest", "barLine")

P = dict(
    reach=11.0,        # how far above the staff to look, in staff spaces
    clear=0.25,        # gap kept above the top staff line
    pad=0.15,          # padding around erased symbols
    speck=0.03,        # smallest component, in square staff spaces
    stem_h=2.0, stem_w=0.4,
    ledger_h=0.35, ledger_w=1.1,
    long_w=3.0,
    gap=0.2,           # word break: horizontal gap, as a fraction of the line's letter height
    letter_pct=75,     # letter height = this percentile of piece heights over 0.6 sp
    root_gap=0.8,      # a lone capital joins the next word within this many letter heights
    trail_gap=0.8,     # a small or accidental piece joins the word before it within this many letter heights
    overlap=0.25,      # same line: vertical overlap as a fraction of the smaller height
)


def load(cop_dir):
    layout = json.load(open(f"{cop_dir}/layout.json"))
    tok = json.load(open(f"{cop_dir}/tok.json"))
    return layout, tok


def frame(comp, sp):
    """A rehearsal-mark box: a closed rectangle of thin lines, mostly empty inside."""
    h, w = comp.shape
    if not (1.6 * sp <= h <= 5 * sp and 1.6 * sp <= w <= 25 * sp):
        return False
    t = max(2, int(0.3 * sp))
    cover = [comp[:t].any(0).mean(), comp[-t:].any(0).mean(), comp[:, :t].any(1).mean(), comp[:, -t:].any(1).mean()]
    return min(cover) > 0.85 and comp[t:-t, t:-t].mean() < 0.35


def components(mask, sp, p):
    lab, n = ndi.label(mask, structure=np.ones((3, 3)))
    out, frames = [], []
    for i, sl in enumerate(ndi.find_objects(lab), 1):
        comp = lab[sl] == i
        y0, y1, x0, x1 = sl[0].start, sl[0].stop, sl[1].start, sl[1].stop
        h, w, area = y1 - y0, x1 - x0, int(comp.sum())
        c = dict(x0=x0, y0=y0, x1=x1, y1=y1, area=area, id=i)
        # Enclosed white regions: a sharp or flat has one, as do b, 6, 9, A, B, D; C, E, F, G and 7 have none.
        if h <= 4 * sp and w <= 4 * sp:
            bg, nb = ndi.label(np.pad(~comp, 1, constant_values=True))
            c["holes"] = sum(1 for j in range(1, nb + 1) if not (bg[0] == j).any() and (bg == j).sum() >= 3)
        if area < p["speck"] * sp * sp:
            continue
        if h >= p["stem_h"] * sp and w <= p["stem_w"] * sp:
            c["thin"] = True                 # a stem if it hangs off a notehead (decided by the caller)
        elif h <= p["ledger_h"] * sp and p["ledger_w"] * sp <= w <= 3.5 * sp:
            c["why"] = "ledger"
        elif frame(comp, sp):
            frames.append(c)
            continue
        elif w >= p["long_w"] * sp and (h < 0.35 * w) and (area / (h * w) < 0.3 or h <= 1.0 * sp):
            c["why"] = "line"          # slur, tie, beam, bracket, hairpin
        elif h > 4.5 * sp:
            c["why"] = "tall"
        out.append(c)
    return out, frames


def words(comps, sp, p):
    """Group letters into lines (vertical overlap), then lines into words (horizontal gaps)."""
    comps = sorted(comps, key=lambda c: c["x0"])
    heights = [c["y1"] - c["y0"] for c in comps]
    # Letter height from the larger letters: lyrics and other small text above a staff would otherwise drag a
    # median down to lowercase height and shrink every gap measured in letters (Beast of Burden: 23 px -> 10 px).
    tall = [h for h in heights if h > 0.6 * sp] or [1.5 * sp]
    letter = p.get("_letter") or float(np.percentile(tall, p.get("letter_pct", 50)))
    gap = p["gap"] * letter
    # Each piece joins the word it overlaps most, judged against the whole word so far (capital root included):
    # a raised "4" in sus4 barely overlaps the lowercase "s" beside it but sits inside the height of "Gsus".
    groups = []
    for c in comps:
        best, best_ov = None, 0.0
        for g in groups:
            if c["x0"] - g["x1"] > gap or c["x1"] < g["x0"]:
                continue
            ov = min(g["y1"], c["y1"]) - max(g["y0"], c["y0"])
            need = p["overlap"] * min(g["y1"] - g["y0"], c["y1"] - c["y0"])
            if ov >= need and ov / max(1, c["y1"] - c["y0"]) > best_ov:
                best, best_ov = g, ov / max(1, c["y1"] - c["y0"])
        if best is None:
            groups.append(dict(x0=c["x0"], y0=c["y0"], x1=c["x1"], y1=c["y1"], parts=[c]))
        else:
            best["parts"].append(c)
            best.update(x0=min(best["x0"], c["x0"]), y0=min(best["y0"], c["y0"]),
                        x1=max(best["x1"], c["x1"]), y1=max(best["y1"], c["y1"]))
    # A lone capital is never a whole word unless nothing follows it closely: handwritten copyists leave a wider
    # gap after the root ("D  -7") than engraving software does.
    root_gap = p.get("root_gap", 0) * letter
    if root_gap:
        groups.sort(key=lambda g: g["x0"])
        merged = True
        while merged:
            merged = False
            for g in groups:
                h, w = g["y1"] - g["y0"], g["x1"] - g["x0"]
                if len(g["parts"]) != 1 or h < 0.8 * letter or w > 1.3 * h:
                    continue
                nxt = [o for o in groups if o is not g and 0 <= o["x0"] - g["x1"] <= root_gap
                       and min(o["y1"], g["y1"]) - max(o["y0"], g["y0"]) >= 0.5 * min(h, o["y1"] - o["y0"])]
                if nxt:
                    o = min(nxt, key=lambda o: o["x0"])
                    o["parts"] += g["parts"]
                    o.update(x0=g["x0"], y0=min(o["y0"], g["y0"]), y1=max(o["y1"], g["y1"]))
                    groups.remove(g)
                    merged = True
                    break
    # A trailing piece belongs to the chord before it: a raised or small extension (b9, 7-5, #11) or a lone
    # accidental after a slash bass (B/D #). Copyists set these a little apart. Only pieces smaller than a letter,
    # or a single narrow glyph with a loop (# or b), join; a lone capital such as C, E, F or G never does.
    trail_gap = p.get("trail_gap", 0) * letter
    if trail_gap:
        groups.sort(key=lambda g: g["x0"])
        merged = True
        while merged:
            merged = False
            for g in groups:
                h, w = g["y1"] - g["y0"], g["x1"] - g["x0"]
                small = h <= 0.8 * letter and w <= 2.0 * letter
                # a sharp or flat: one glyph with a loop, about twice as tall as wide (capitals with loops, A B D,
                # are nearer square)
                accidental = (len(g["parts"]) <= 2 and h >= 1.6 * w and w <= 0.8 * letter
                              and (len(g["parts"]) == 2 or g["parts"][0].get("holes", 0) >= 1))
                short = w <= 2.0 * letter
                if not (small or accidental or short):
                    continue

                def fits(o):
                    if o is g or not (0 <= g["x0"] - o["x1"] <= trail_gap):
                        return False
                    oh = o["y1"] - o["y0"]
                    if oh < 0.7 * letter or o["x1"] - o["x0"] < 0.5 * letter:
                        return False                 # the chord before is at least a letter
                    # an extension written raised: its foot clearly above the chord's
                    raised = short and g["y1"] <= o["y1"] - 0.25 * oh and g["y0"] >= o["y0"] - 0.8 * letter
                    level = (small or accidental) and g["y0"] >= o["y0"] - 0.6 * letter and \
                        g["y1"] <= o["y1"] + 0.3 * letter and g["y1"] >= o["y0"] + 0.2 * oh
                    return raised or level

                prev = [o for o in groups if fits(o)]
                if prev:
                    o = max(prev, key=lambda o: o["x1"])
                    o["parts"] += g["parts"]
                    o.update(x1=max(o["x1"], g["x1"]), y0=min(o["y0"], g["y0"]), y1=max(o["y1"], g["y1"]))
                    groups.remove(g)
                    merged = True
                    break
    out = []
    for g in (g["parts"] for g in groups):
        out.append(dict(x0=min(c["x0"] for c in g), y0=min(c["y0"] for c in g), x1=max(c["x1"] for c in g),
                        y1=max(c["y1"] for c in g), parts=len(g), ink=sum(c["area"] for c in g)))
    return out


def find(gray, layout, tok, p=P):
    ink = gray < 160
    clean = ink.copy()
    H, W = ink.shape
    # Above the staff, copisteria reads handwritten chord letters as music (a D as ff, an A as a marcato, a C as a
    # fermata, each with high confidence), so only notes it placed in a voice, and the accidentals and dots beside
    # them, are erased there. Everything else above the staff stays as possible text for the reader to reject.
    def above(s):
        """Outside its staff: above it, or below it in the gap before the next staff. Copisteria attributes text in
        the gap to either staff (a handwritten b9 came back as a flat and an mp under the line above)."""
        st = layout["staves"][s["staff"]] if s.get("staff") is not None and s["staff"] >= 0 else None
        if st is None:
            return False
        return s["box"][3] < st["y0"] - 0.3 * st["sp"] or (p.get("gap_below", True) and s["box"][1] > st["y1"] + 0.3 * st["sp"])

    def real(i):
        return tok.get(str(i), {}).get("real", 1.0) or 0.0

    # Notes and rests in a voice; above the staff they must also be likely real (copisteria gives a hallucinated
    # eighth rest on a handwritten "b7" a beat, but rates it 0.13 real).
    timed = [s for i, s in enumerate(layout["syms"])
             if s["cls"].startswith(("note", "rest")) and tok.get(str(i), {}).get("onset") is not None
             and (not above(s) or real(i) >= 0.5)]
    heads = [s["box"] for s in timed if s["cls"].startswith("note")]

    def beside_note(s):
        """An accidental just left of a notehead at its height, or a dot just right of one."""
        x0, y0, x1, y1 = s["box"]
        sp = layout["staves"][s["staff"]]["sp"]
        for h in heads:
            if min(y1, h[3]) - max(y0, h[1]) <= 0:
                continue
            if s["cls"].startswith("accid") and h[0] - 1.5 * sp <= x1 <= h[0] + 0.3 * sp:
                return True
            if s["cls"].startswith("dots") and h[2] - 0.2 * sp <= x0 <= h[2] + 1.5 * sp:
                return True
        return False

    timed_ids = {id(s) for s in timed}
    for s in layout["syms"]:
        if not s["cls"].startswith(ERASE):
            continue
        if p.get("trust_above", False) is False and above(s):
            if s["cls"].startswith(("note", "rest")):
                if id(s) not in timed_ids:
                    continue
            elif not (s["cls"].startswith(("accid", "dots")) and beside_note(s)):
                continue
        st = layout["staves"][s["staff"]] if s.get("staff") is not None and s["staff"] >= 0 else None
        sp = st["sp"] if st else layout["sp"]
        x0, y0, x1, y1 = s["box"]
        q = p["pad"] * sp
        clean[max(0, int(y0 - q)):int(y1 + q) + 1, max(0, int(x0 - q)):int(x1 + q) + 1] = False

    staves = sorted(range(len(layout["staves"])), key=lambda k: layout["staves"][k]["y0"])
    proposals = []
    two_rows = False
    prev_bottom = 0
    for order, k in enumerate(staves):
        st = layout["staves"][k]
        sp = st["sp"]
        top = int(max(prev_bottom + 0.5 * sp, st["y0"] - p["reach"] * sp, 0))
        bottom = int(st["y0"] - p["clear"] * sp)
        left, right = int(max(0, st["x0"] - sp)), int(min(W, st["x1"] + sp))
        prev_bottom = st["y1"]
        if bottom - top < 2 * sp:
            continue
        region = clean[top:bottom, left:right]
        comps, frames = components(region, sp, p)
        # Everything inside a rehearsal frame belongs to it.
        inside = lambda c, f: c["x0"] >= f["x0"] and c["x1"] <= f["x1"] and c["y0"] >= f["y0"] and c["y1"] <= f["y1"]
        # A thin sliver touching a notehead is what is left of its stem once the head is erased; chord symbols
        # never touch noteheads.
        for c in comps:
            if c.pop("thin", False):
                gx0, gx1, gy0, gy1 = c["x0"] + left, c["x1"] + left, c["y0"] + top, c["y1"] + top
                near_head = any(h[0] - 0.5 * sp <= gx1 and gx0 <= h[2] + 0.5 * sp and h[1] - 4 * sp <= gy1
                                and gy0 <= h[3] + 4 * sp for h in heads)
                if near_head or c["y1"] >= region.shape[0] - 1 or c["y0"] <= 0 or not p.get("free_strokes", True):
                    c["why"] = "stem"
                    continue
            if "why" in c or c["x1"] - c["x0"] > 0.45 * sp:
                continue
            # A sliver cut by the bottom of the region continues into this staff, and one cut by the top hangs from
            # the staff above: the tip of a stem either way.
            if c["y1"] >= region.shape[0] - 1 or c["y0"] <= 0:
                c["why"] = "stem"
                continue
            gx0, gx1, gy0, gy1 = c["x0"] + left, c["x1"] + left, c["y0"] + top, c["y1"] + top
            if any(h[0] - 0.4 * sp <= gx1 and gx0 <= h[2] + 0.4 * sp and h[1] - 0.6 * sp <= gy1 and gy0 <= h[3] + 0.6 * sp
                   for h in heads):
                c["why"] = "stem"
        kept = [c for c in comps if "why" not in c and not any(inside(c, f) for f in frames)]
        # Letter height from the band chords stand in, a few spaces above this staff, so the lyrics of the line
        # above (lowercase, and often more numerous) don't set it.
        band = [c["y1"] - c["y0"] for c in kept if (c["y1"] - c["y0"]) > 0.6 * sp
                and (st["y0"] - top) - (c["y0"] + c["y1"]) / 2 <= p.get("chord_band", 7) * sp]
        wp = dict(p, _letter=float(np.percentile(band, p.get("letter_pct", 50)))) if band else p
        found = []
        for wd in words(kept, sp, wp):
            found.append(dict(wd, x0=wd["x0"] + left, x1=wd["x1"] + left, y0=wd["y0"] + top, y1=wd["y1"] + top,
                              staff=k, order=order, kind="text"))
        # Nothing before the music starts is a chord: bar numbers, part names.
        starts = [(s["box"][0] + s["box"][2]) / 2 for s in layout["syms"]
                  if s.get("staff") == k and s["cls"].startswith(("note", "rest"))]
        first = min(starts) if starts else st["x0"]
        letter = float(np.median([w["y1"] - w["y0"] for w in found] or [1.5 * sp]))
        for w in found:
            if (w["x0"] + w["x1"]) / 2 < first - 1.5 * sp:
                w["kind"] = "dropped:before-music"
        # Text belongs to the staff it sits closest to: lyrics hang below the line above, chords stand on this one.
        if order > 0 and p.get("lyrics", True):
            above_bottom = layout["staves"][staves[order - 1]]["y1"]
            for w in found:
                if w["kind"] != "text":
                    continue
                c = (w["y0"] + w["y1"]) / 2
                if c - above_bottom < 0.6 * (st["y0"] - c):
                    w["kind"] = "dropped:line-above"
        # Chord symbols are the lowest row of text over the staff; tempo, style and rehearsal words sit above them.
        if p.get("stack", True):
            solid = [w for w in found if w["kind"] == "text" and w["y1"] - w["y0"] >= max(0.6 * letter, 1.0 * sp)
                     and w["x1"] - w["x0"] >= 0.6 * sp]
            for a in solid:
                for b in solid:
                    if b is a or b["y0"] < a["y1"] - 0.2 * letter:
                        continue
                    ov = min(a["x1"], b["x1"]) - max(a["x0"], b["x0"])
                    if ov >= 0.3 * min(a["x1"] - a["x0"], b["x1"] - b["x0"]):
                        a["kind"] = "dropped:stacked"
                        break
            # ...unless the upper words form a row of their own across the line: a second chord row (alternate
            # changes, as in The Public Domain Song Anthology), not a lone tempo or style phrase.
            edges = list(st["bars"]) + [st["x1"]]

            def bar_of(w):
                x = (w["x0"] + w["x1"]) / 2
                return max([b for b in range(len(edges) - 1) if x >= edges[b]] or [0])

            rows = []
            for w in sorted((w for w in found if w["kind"] in ("text", "dropped:stacked")), key=lambda w: w["y1"]):
                if rows and abs(w["y1"] - rows[-1][-1]["y1"]) <= 0.5 * letter:
                    rows[-1].append(w)
                else:
                    rows.append([w])
            for row in rows:
                if any(w["kind"] == "dropped:stacked" for w in row) and len(row) >= 3 and len({bar_of(w) for w in row}) >= 2:
                    two_rows = True
                    for w in row:
                        if w["kind"] == "dropped:stacked":
                            w["kind"] = "text"
                        w["row"] = "upper"
        proposals.extend(found)
        for f in frames:
            proposals.append(dict(x0=f["x0"] + left, x1=f["x1"] + left, y0=f["y0"] + top, y1=f["y1"] + top,
                                  staff=k, order=order, kind="rehearsal"))
    # A page that prints a second chord row on one line prints it wherever it has alternate changes, even a single
    # chord, so its stacked words are kept everywhere.
    if two_rows:
        for pr in proposals:
            if pr["kind"] == "dropped:stacked":
                pr["kind"], pr["row"] = "text", "upper"
    anchor = p.get("anchor", "auto")
    if anchor == "auto":
        anchor = page_anchor([q for q in proposals if q["kind"] == "text"], layout, tok)
    for pr in proposals:
        place(pr, layout, tok, anchor)
        pr["anchor"] = anchor
    return proposals, clean


def page_anchor(words, layout, tok):
    """Which part of a chord sits over its note on this page: its centre (MuseScore) or its left edge (most
    copyists and many engravers). Whichever lines up with a note or rest more often wins."""
    notes = {}
    for i, s in enumerate(layout["syms"]):
        if s["cls"].startswith(("note", "rest")) and tok.get(str(i), {}).get("onset") is not None:
            notes.setdefault(s.get("staff"), []).append(s["box"])
    votes = {"centre": 0, "left": 0}
    for w in words:
        boxes = notes.get(w["staff"], [])
        sp = layout["staves"][w["staff"]]["sp"]
        if not boxes or w["x1"] - w["x0"] < 1.0 * sp:
            continue
        dc = min(abs((b[0] + b[2]) / 2 - (w["x0"] + w["x1"]) / 2) for b in boxes)
        dl = min(abs(b[0] - w["x0"]) for b in boxes)
        votes["centre"] += dc < 0.5 * sp
        votes["left"] += dl < 0.5 * sp
    return "left" if votes["left"] > votes["centre"] else "centre"


def place(pr, layout, tok, anchor="centre"):
    """Bar from the word's left edge; beat from the note or rest it sits over."""
    st = layout["staves"][pr["staff"]]
    sp = st["sp"]
    edges = list(st["bars"]) + [st["x1"]]
    # MuseScore centres a chord symbol over its note (measured: centre within 0.45 sp of the notehead's centre on
    # every chord of the development set; the left edge is up to 4 sp off).
    x = (pr["x0"] + pr["x1"]) / 2 if anchor == "centre" else pr["x0"] + 0.3 * sp
    bar = 0
    for b in range(len(edges) - 1):
        if x >= edges[b]:
            bar = b
    pr["bar"] = bar
    points = []
    for i, s in enumerate(layout["syms"]):
        if s.get("staff") != pr["staff"] or s.get("bar") != bar:
            continue
        on = tok.get(str(i), {}).get("onset")
        if on is None or not s["cls"].startswith(("note", "rest")):
            continue
        points.append(((s["box"][0] + s["box"][2]) / 2 if anchor == "centre" else s["box"][0] + 0.3 * sp, on))
    pr["beat"], pr["beat_dist"], pr["beat_src"] = None, None, None
    if not points:
        return
    xc, on = min(points, key=lambda q: abs(q[0] - x))
    pr["beat_dist"] = abs(xc - x) / sp
    if abs(xc - x) < 1.0 * sp:
        pr["beat"], pr["beat_src"] = on + 1, "note"
        return
    # No note under the chord (it sits over a held note or a rest): place it by where it falls between the notes
    # on either side, then snap to the nearest strong beat (1 and 3 in 4/4), which is where charts put a chord
    # that has no note of its own. Handwritten spacing is not proportional to time, so the raw position is
    # only good enough to choose between strong beats.
    length, strong = bar_length(layout, tok, pr["staff"])
    pts = sorted(set(points)) + [(edges[bar + 1], length)]
    if x <= pts[0][0]:
        t = pts[0][1]
    else:
        t = length
        for (xa, ta), (xb, tb) in zip(pts, pts[1:]):
            if xa <= x <= xb and xb > xa:
                t = ta + (tb - ta) * (x - xa) / (xb - xa)
                break
    t = round(t / strong) * strong
    pr["beat"], pr["beat_src"] = min(length - strong, t) + 1, "between"


def bar_length(layout, tok, staff):
    """Quarter notes per bar, and the spacing of its strong beats, from the time signature copisteria read for
    this staff (4/4 when it read none)."""
    for i, s in enumerate(layout["syms"]):
        t = tok.get(str(i), {}).get("time")
        if s.get("staff") == staff and t and t != "None" and "/" in str(t):
            n, d = str(t).split("/")[:2]
            try:
                n, d = int(n), int(d)
            except ValueError:
                continue
            length = n * 4 / d
            if d == 8 and n % 3 == 0:
                return length, 1.5                     # compound: dotted-quarter beats
            return length, 2.0 if n % 2 == 0 and length >= 2 else 4 / d
    return 4.0, 2.0
