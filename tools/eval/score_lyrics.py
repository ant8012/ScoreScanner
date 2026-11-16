"""Score lyrics in scans against gen_lyrics.py's answer key, or list them on pages without one.

usage: python3.12 tools/eval/score_lyrics.py TRUTH.json SCAN_DIR [--show]
       python3.12 tools/eval/score_lyrics.py --list SCAN_DIR
Bars are compared note by note (first voice, chord members and rests left out) where the scan has as many notes as
the page; other bars count their syllables as on unmatched bars. A syllable is right when its text matches exactly
on the right note and verse; its hyphenation (single/begin/middle/end) and extender are scored separately. False:
a syllable written on a note that has none in that verse.
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def bars(path):
    out = []
    for m in ET.parse(path).getroot().find("part").findall("measure"):
        notes = []
        for n in m.findall("note"):
            if n.find("rest") is not None or n.find("chord") is not None or n.find("grace") is not None:
                continue
            if n.findtext("voice", "1") not in ("1",):
                continue
            ly = {}
            for l in n.findall("lyric"):
                ly[int(l.get("number", "1"))] = (l.findtext("text", ""), l.findtext("syllabic", "single"),
                                                 l.find("extend") is not None)
            notes.append(ly)
        out.append(notes)
    return out


def main():
    if sys.argv[1] == "--list":
        for f in sorted(Path(sys.argv[2]).glob("*.musicxml")):
            words = []
            for b in bars(f):
                for ly in b:
                    if 1 in ly:
                        words.append(ly[1][0] + ("-" if ly[1][1] in ("begin", "middle") else "") +
                                     ("_" if ly[1][2] else ""))
            if words:
                print(f"{f.stem}: {' '.join(words)}")
        return
    truth = json.loads(Path(sys.argv[1]).read_text())
    show = "--show" in sys.argv
    t = dict(right=0, wrong_text=0, missed=0, unmatched_bar=0, false=0, syl_ok=0, syl_bad=0, ext_ok=0, ext_bad=0)
    for name, key in sorted(truth.items()):
        f = Path(sys.argv[2]) / f"{name}.musicxml"
        if not f.exists():
            continue
        got = bars(f)
        for i, want in enumerate(key):
            have = got[i] if i < len(got) else []
            if len(have) != len(want):
                t["unmatched_bar"] += sum(len(c) for c in want if c)
                continue
            for n, (w, h) in enumerate(zip(want, have)):
                for v in range(1, 4):
                    wv = w[v - 1] if w and v - 1 < len(w) else None
                    hv = h.get(v)
                    if wv and not hv:
                        t["missed"] += 1
                        if show:
                            print(f"{name} bar {i + 1} note {n + 1} v{v}: missed {wv[0]!r}")
                    elif hv and not wv:
                        t["false"] += 1
                        if show:
                            print(f"{name} bar {i + 1} note {n + 1} v{v}: FALSE {hv[0]!r}")
                    elif wv and hv:
                        if hv[0] == wv[0]:
                            t["right"] += 1
                        else:
                            t["wrong_text"] += 1
                            if show:
                                print(f"{name} bar {i + 1} note {n + 1} v{v}: {wv[0]!r} read {hv[0]!r}")
                        t["syl_ok" if hv[1] == wv[1] else "syl_bad"] += 1
                        t["ext_ok" if hv[2] == wv[2] else "ext_bad"] += 1
    total = t["right"] + t["wrong_text"] + t["missed"] + t["unmatched_bar"]
    print(f"syllables {total}: right {t['right']}, wrong text {t['wrong_text']}, missed {t['missed']}, "
          f"on unmatched bars {t['unmatched_bar']}; false {t['false']}")
    print(f"hyphenation right {t['syl_ok']} / {t['syl_ok'] + t['syl_bad']}, "
          f"extenders right {t['ext_ok']} / {t['ext_ok'] + t['ext_bad']}")


if __name__ == "__main__":
    main()
