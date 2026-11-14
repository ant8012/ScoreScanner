"""Turn a pcc-cat crop reading into chords and staff text: join the pieces of a direction, check rehearsal marks.

usage: python3.12 read_text.py CROPS_DIR [--truth TEXT_TRUTH.json]

Reads CROPS_DIR/manifest.json, results-pcc-cat.json and signs.json (export_crops.py --all) and writes
results-pcc-cat-post.json (chords, for score_reads.py) and staff-text.json (directions per chart).

- A rehearsal mark needs a box: a crop named rehearsal without one becomes part of the direction beside it (the "a"
  of "a tempo"), or a chord when it is chord-shaped and alone, or a section name when it is a word.
- Neighbouring staff-text crops on one line, about a word space apart, are one direction ("D.S." + "al Coda").
  Segno and coda signs copisteria found join the direction beside them. Chords never join anything.
- A chord crop that also holds a segno or coda sign keeps the chord and adds the sign as a direction.

--truth scores the directions against a hand list per chart ("[R] " marks a rehearsal mark).
"""

import json
import re
import sys

from score_reads import is_chord

STAFF = {"rehearsal", "section", "navigation", "tempo", "instruction"}
# What may join what: pieces of one direction share a kind; a number ("1, 2") follows a navigation or instruction,
# and a loose letter (an unboxed "a") starts a tempo or instruction. Rehearsal marks and section names stand alone.
JOINS = {"navigation": {"navigation", "number"}, "tempo": {"tempo", "loose-letter"},
         "instruction": {"instruction", "number", "loose-letter"}}
SIGN_TEXT = {"repeatMark_segno": "𝄋", "repeatMark_coda": "𝄌"}


def words(s):
    s = s.lower().replace("d.s.", "ds ").replace("d.c.", "dc ").replace("𝄌", " coda ").replace("𝄋", " segno ")
    return re.findall(r"[a-z0-9]+", s)


def main():
    d = sys.argv[1]
    man = {m["id"]: m for m in json.load(open(f"{d}/manifest.json"))}
    raw = json.load(open(f"{d}/results-pcc-cat.json"))
    try:
        signs = json.load(open(f"{d}/signs.json"))
    except FileNotFoundError:
        signs = []

    items = []      # every piece of staff text, with its word box
    post = []
    for r in raw["results"]:
        m = man[r["id"]]
        cat, text = r.get("category"), (r.get("visibleText") or "").strip()
        r = dict(r)
        if cat == "rehearsal" and not m.get("boxed"):
            if len(text) <= 2:
                cat = "loose-letter"       # decided once its neighbours are known
            else:
                cat = "section"
        # a one- or two-letter "lyric" above the staff is usually the start of a direction ("a" tempo); it joins
        # the direction beside it or is dropped
        if cat == "lyric" and len(text) <= 2:
            cat = "loose-letter"
        if cat in STAFF or cat in ("number", "loose-letter"):
            items.append(dict(id=r["id"], chart=m["chart"], line=m["line"], box=m["word"], sp=m["sp"], text=text,
                              cat=cat))
        also = (r.get("also") or "").strip()
        if cat == "chord" and also and re.search(r"segno|coda|𝄋|𝄌|%", also, re.I):
            items.append(dict(id=r["id"], chart=m["chart"], line=m["line"], box=m["word"], sp=m["sp"],
                              text="𝄌" if re.search(r"coda|𝄌", also, re.I) else "𝄋", cat="navigation"))
        post.append(r)
    def overlaps(a, b):
        return min(a[2], b[2]) > max(a[0], b[0]) and min(a[3], b[3]) > max(a[1], b[1])

    for s in signs:
        # a sign the reader already saw inside a crop is not added again
        if s["sign"] in SIGN_TEXT and not any(it["chart"] == s["chart"] and overlaps(it["box"], s["word"])
                                               for it in items):
            items.append(dict(id=None, chart=s["chart"], line=s["line"], box=s["word"], sp=s["sp"],
                              text=SIGN_TEXT[s["sign"]], cat="navigation"))

    # join neighbours on one line into directions
    directions = []
    by_line = {}
    for it in items:
        by_line.setdefault((it["chart"], it["line"]), []).append(it)
    for (chart, line), its in by_line.items():
        its.sort(key=lambda it: it["box"][0])
        groups = []
        for it in its:
            g = groups[-1] if groups else None
            if g is not None:
                last = g[-1]
                gap = it["box"][0] - last["box"][2]
                lo, hi = max(it["box"][1], last["box"][1]), min(it["box"][3], last["box"][3])
                level = hi - lo >= 0.3 * min(it["box"][3] - it["box"][1], last["box"][3] - last["box"][1])
                kinds = {x["cat"] for x in g} | {it["cat"]}
                main = [k for k in kinds if k in JOINS]
                fits = len(main) >= 1 and all(k in JOINS[main[0]] for k in kinds) if len(set(main)) == 1 else False
                if gap <= 2.0 * it["sp"] and level and fits:
                    g.append(it)
                    continue
            groups.append([it])
        for g in groups:
            kinds = [it["cat"] for it in g if it["cat"] not in ("number", "loose-letter")]
            text = " ".join(it["text"] for it in g if it["text"])
            if not kinds:
                # a lone number is a bar or volta number; a lone unboxed letter is the chord it looks like
                for it in g:
                    if it["cat"] == "loose-letter" and is_chord(it["text"]) and it["id"] is not None:
                        rr = next(r for r in post if r["id"] == it["id"])
                        rr.update(isChord=True, chord=it["text"], category="chord")
                continue
            kind = max(set(kinds), key=kinds.count)
            directions.append(dict(chart=chart, line=line, x=g[0]["box"][0], kind=kind, text=text))

    json.dump(dict(raw, results=post), open(f"{d}/results-pcc-cat-post.json", "w"), indent=1)
    json.dump(directions, open(f"{d}/staff-text.json", "w"), indent=1, ensure_ascii=False)

    if "--truth" in sys.argv:
        truth = json.load(open(sys.argv[sys.argv.index("--truth") + 1]))
        found = right_kind = total = 0
        used = set()
        for chart, want in truth.items():
            mine = [(i, x) for i, x in enumerate(directions) if x["chart"] == chart]
            for t in want:
                reh = t.startswith("[R] ")
                t = t[4:] if reh else t
                tw = set(words(t))
                total += 1
                free = [ix for ix in mine if ix[0] not in used]
                best = max(free, key=lambda ix: len(tw & set(words(ix[1]["text"]))) / len(tw), default=None)
                share = len(tw & set(words(best[1]["text"]))) / len(tw) if best else 0
                ok = share >= 0.99
                if ok:
                    used.add(best[0])
                    found += 1
                    # a boxed word (Bridge, Verse) may come back as a section name; either is a heading
                    kind_ok = best[1]["kind"] in ("rehearsal", "section") if reh else best[1]["kind"] != "rehearsal"
                    right_kind += kind_ok
                print(f"{chart:9} {'R ' if reh else '  '}{t:16} -> "
                      + (f"{best[1]['text']!r} [{best[1]['kind']}]" if best else "-") + ("" if ok else "   MISSED"))
        # segno and coda signs alone are written by copisteria already; they are not staff text to score
        extra = [x for i, x in enumerate(directions) if i not in used and x["chart"] in truth
                 and set(words(x["text"])) - {"segno", "coda"}]
        print(f"\ndirections found whole {found}/{total}, rehearsal-or-not right {right_kind}/{found}")
        print("directions with no match:", [(x["chart"], x["text"], x["kind"]) for x in extra])


if __name__ == "__main__":
    main()
