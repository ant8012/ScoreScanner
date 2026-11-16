"""Score slash bars in scans against gen_slashes.py's answer key, or list them on pages without one.

usage: python3.12 tools/eval/score_slashes.py TRUTH.json SCAN_DIR      # synthetic pages
       python3.12 tools/eval/score_slashes.py --list SCAN_DIR          # any scans: every slash bar written
A bar counts as written with slashes when MusicXML's slash measure style is on for it. Pages whose bar count
differs from the key (a bar line the detector missed or added) are skipped and counted.
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def slash_bars(path):
    """1-based numbers of the first part's bars written with slashes (any staff), and the bar count."""
    part = ET.parse(path).getroot().find("part")
    on, out, measures = set(), [], part.findall("measure")
    for i, m in enumerate(measures):
        for ms in m.iter("measure-style"):
            for s in ms.findall("slash"):
                staff = ms.get("number", "1")
                (on.add if s.get("type") == "start" else on.discard)(staff)
        if on:
            out.append(i + 1)
    return out, len(measures)


def main():
    if sys.argv[1] == "--list":
        total = 0
        for f in sorted(Path(sys.argv[2]).glob("*.musicxml")):
            bars, _ = slash_bars(f)
            if bars:
                total += len(bars)
                print(f"{f.stem}: {bars}")
        print(f"{total} slash bars written")
        return
    truth = json.loads(Path(sys.argv[1]).read_text())
    right = false = missed = skipped = 0
    for name, key in sorted(truth.items()):
        f = Path(sys.argv[2]) / f"{name}.musicxml"
        if not f.exists():
            print(f"{name}: no scan")
            continue
        got, n = slash_bars(f)
        if n != key["bars"]:
            skipped += 1
            continue
        g, w = set(got), set(key["slash"])
        right += len(g & w)
        false += len(g - w)
        missed += len(w - g)
        if g - w:
            print(f"{name}: FALSE {sorted(g - w)} ({[key['kinds'][b - 1] for b in sorted(g - w)]})")
        if w - g:
            print(f"{name}: missed {sorted(w - g)}")
    print(f"slash bars: right {right}, false {false}, missed {missed}; pages skipped (bar count differs) {skipped}")


if __name__ == "__main__":
    main()
