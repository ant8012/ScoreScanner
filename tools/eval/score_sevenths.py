"""Score the chords a scan writes against gen_sevenths.py's kinds.json, bar by bar: root and MusicXML kind.

usage: python3.12 tools/eval/score_sevenths.py KINDS.json SCAN_DIR
Prints how each printed spelling was read (right, wrong quality, wrong root, missed) and every major/minor swap.
Bars whose chord count differs are counted as missed.
"""

import collections
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

MAJOR = {"major", "major-seventh", "major-sixth", "major-ninth", "major-11th", "major-13th"}
MINOR = {"minor", "minor-seventh", "minor-sixth", "minor-ninth", "minor-11th", "minor-13th"}
ALTER = {"-1": "b", "1": "#", "-2": "bb", "2": "##"}


def read(path):
    bars = []
    for m in ET.parse(path).getroot().find("part").findall("measure"):
        cells = []
        for h in m.findall("harmony"):
            r = h.findtext("root/root-step", "") + ALTER.get(h.findtext("root/root-alter", "0"), "")
            cells.append((r, h.findtext("kind", "")))
        bars.append(cells)
    return bars


def main():
    truth = json.loads(Path(sys.argv[1]).read_text())
    by = collections.defaultdict(collections.Counter)
    swaps = []
    for name, bars in sorted(truth.items()):
        f = Path(sys.argv[2]) / f"{name}.musicxml"
        if not f.exists():
            continue
        got = read(f)
        for i, want in enumerate(bars):
            have = got[i] if i < len(got) else []
            for k, (root, kind, text) in enumerate(want):
                if len(have) != len(want):
                    by[text]["missed"] += 1
                    continue
                r, g = have[k]
                if r != root:
                    by[text]["wrong root"] += 1
                elif g == kind:
                    by[text]["right"] += 1
                else:
                    by[text]["wrong kind"] += 1
                    if (kind in MAJOR and g in MINOR) or (kind in MINOR and g in MAJOR):
                        swaps.append(f"{name} bar {i + 1}: printed {root}{text} ({kind}), written {g}")
    print(f"{'printed':8} right  wrong-kind  wrong-root  missed")
    for text in sorted(by, key=lambda t: (t.lower().lstrip('-'), t)):
        c = by[text]
        print(f"{text:8} {c['right']:5}  {c['wrong kind']:10}  {c['wrong root']:10}  {c['missed']:6}")
    print(f"major/minor swaps: {len(swaps)}")
    for s in swaps[:40]:
        print(" ", s)


if __name__ == "__main__":
    main()
