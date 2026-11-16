"""Score part names read from scans against gen_parts.py's answer key.

usage: python3.12 tools/eval/score_parts.py TRUTH.json SCAN_DIR
SCAN_DIR holds NAME.musicxml from `ScannerCheck --read-image`. A name counts when it matches ignoring case, spaces
and dots; "wrong" is a name written that differs, "missed" a printed name not written, "extra" a name written
where none is printed (a lone part).
"""

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def norm(s):
    return re.sub(r"[\s.]", "", s or "").lower()


def written(path):
    root = ET.parse(path).getroot()
    out = []
    for sp in root.iter("score-part"):
        pn = sp.find("part-name")
        shown = pn is not None and pn.get("print-object") != "no"
        out.append((pn.text if shown else "", sp.findtext("part-abbreviation") or ""))
    return out


def main():
    truth = json.loads(Path(sys.argv[1]).read_text())
    scans = Path(sys.argv[2])
    tally = {k: {"right": 0, "wrong": 0, "missed": 0, "extra": 0, "parts_off": 0} for k in ("long", "short")}
    for name, key in sorted(truth.items()):
        path = scans / f"{name}.musicxml"
        if not path.exists():
            print(f"{name}: no scan")
            continue
        got = written(path)
        notes = []
        for kind, idx in (("long", 0), ("short", 1)):
            want = key[kind]
            t = tally[kind]
            if not want:
                t["extra"] += sum(1 for g in got if g[idx])
                if any(g[idx] for g in got):
                    notes.append(f"{kind} extra {[g[idx] for g in got]}")
                continue
            if len(got) != len(want):
                t["parts_off"] += 1
                notes.append(f"{kind}: {len(got)} parts read, {len(want)} printed")
                continue
            for w, g in zip(want, got):
                if not g[idx]:
                    t["missed"] += 1
                    notes.append(f"{kind} missed {w!r}")
                elif norm(g[idx]) == norm(w):
                    t["right"] += 1
                else:
                    t["wrong"] += 1
                    notes.append(f"{kind} {w!r} read {g[idx]!r}")
        if notes:
            print(f"{name}: " + "; ".join(notes))
    for kind, t in tally.items():
        print(kind, t)


if __name__ == "__main__":
    main()
