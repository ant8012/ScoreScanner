"""Score chord readings against hand-made answer keys, in page order.

usage:
  python3.12 score_reads.py TRUTH.json crops MANIFEST.json RESULTS.json      # a --crop-bench route
  python3.12 score_reads.py TRUTH.json xml CHART=SCORE.musicxml [...]       # a normal scan's MusicXML output

TRUTH.json maps a chart name to its chords in reading order ("|" between lines is ignored). Spellings that mean the
same chord are made equal (-7 = m7, Δ7 = maj7, 7(b9) = 7b9, ø7 = m7b5, o7 = dim7, + = aug). Each chart's sequence
is aligned to the key by longest common subsequence: exact = whole chord right, root = root (and accidental) right.
False chords are readings that align to nothing even at root level.
"""

import json
import re
import sys
import xml.etree.ElementTree as ET


def norm(s):
    s = (s or "").strip().replace(" ", "").replace("♭", "b").replace("♯", "#")
    s = s.replace("△", "Δ").replace("°", "o").translate(str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉⁺⁻", "01234567890123456789+-"))
    if re.fullmatch(r"N\.?C\.?", s, re.I):
        return "NC"
    m = re.match(r"^([A-G])([b#]?)(.*)$", s)
    if not m:
        return s
    root, acc, rest = m.groups()
    bass = ""
    sm = re.search(r"/([A-G][b#]?)$", rest)
    if sm:
        bass, rest = sm.group(1), rest[: sm.start()]
    rest = rest.replace("(", "").replace(")", "").replace(",", "")
    if rest == "M":
        rest = "m"                     # small-caps fonts print minor as a capital M (What a Wonderful World)
    rest = re.sub(r"^(maj|MAJ|Maj|ma|M|Δ)(?=7|9|11|13|$)", "maj", rest)
    rest = rest.replace("Δ", "maj")
    rest = re.sub(r"^(min|mi|-)", "m", rest)
    rest = re.sub(r"^ø7?", "m7b5", rest)
    rest = re.sub(r"^o7", "dim7", rest)
    rest = re.sub(r"^o$", "dim", rest)
    rest = re.sub(r"^\+", "aug", rest)
    if rest == "maj":
        rest = ""
    return root + acc + rest + ("/" + bass if bass else "")


def root(s):
    s = norm(s)
    m = re.match(r"^([A-G][b#]?)", s)
    return m.group(1) if m else s


def lcs(a, b):
    n, m = len(a), len(b)
    t = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n):
        for j in range(m):
            t[i + 1][j + 1] = t[i][j] + 1 if a[i] == b[j] else max(t[i][j + 1], t[i + 1][j])
    return t[n][m]


def score(truth, predicted):
    out = {}
    for chart, key in truth.items():
        want = key.replace("|", " ").split()
        got = predicted.get(chart, [])
        exact = lcs([norm(x) for x in want], [norm(x) for x in got])
        roots = lcs([root(x) for x in want], [root(x) for x in got])
        out[chart] = dict(chords=len(want), read=len(got), exact=exact, root=roots, false=len(got) - roots)
    total = {k: sum(v[k] for v in out.values()) for k in ("chords", "read", "exact", "root", "false")}
    out["total"] = total
    return out


QUALITY = ["maj", "MAJ", "Maj", "ma", "min", "mi", "dim", "aug", "alt", "sus", "add", "m", "M", "-", "+", "o", "ø",
           "Δ", "°"]


def is_chord(text):
    """A strict chord grammar: a root, then only chord vocabulary, then an optional slash bass. Words like Bossa,
    Fine or Coda fail; a lyric that happens to be a chord (Am) still passes."""
    s = (text or "").strip().replace(" ", "").replace("♭", "b").replace("♯", "#")
    s = s.translate(str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉⁺⁻", "01234567890123456789+-"))
    if re.fullmatch(r"N\.?C\.?", s, re.I):
        return True
    m = re.match(r"^[A-G][b#]?", s)
    if not m:
        return False
    rest = s[m.end():]
    bass = re.search(r"/[A-G][b#]?$", rest)
    if bass:
        rest = rest[: bass.start()]
    while rest:
        for q in QUALITY:
            if rest.startswith(q):
                rest = rest[len(q):]
                break
        else:
            if rest[0] in "0123456789b#(),/":
                rest = rest[1:]
            else:
                return False
    return True


def from_crops(manifest, results, grammar=False):
    items = {m["id"]: m for m in json.load(open(manifest))}
    res = json.load(open(results))
    got = {}
    for r in sorted(res["results"], key=lambda r: (items[r["id"]]["chart"], items[r["id"]]["line"], items[r["id"]]["x0"])):
        if r.get("isChord") and (r.get("chord") or "").strip() and (not grammar or is_chord(r["chord"])):
            got.setdefault(items[r["id"]]["chart"], []).append(r["chord"])
    return got, res


def harmony_text(h):
    step = h.findtext("root/root-step") or ""
    alter = {"-1": "b", "1": "#"}.get(h.findtext("root/root-alter") or "", "")
    kind = h.find("kind")
    text = kind.get("text") if kind is not None and kind.get("text") is not None else None
    if text is None:
        text = {"major": "", "minor": "m", "dominant": "7", "major-seventh": "maj7", "minor-seventh": "m7",
                "half-diminished": "m7b5", "diminished-seventh": "dim7", "diminished": "dim", "augmented": "aug",
                "suspended-fourth": "sus4", "major-sixth": "6", "minor-sixth": "m6", "dominant-ninth": "9",
                "none": "NC"}.get(kind.text if kind is not None else "", kind.text if kind is not None else "")
    if text == "NC" or (kind is not None and kind.text == "none"):
        return "N.C."
    degrees = "".join({"-1": "b", "1": "#"}.get(d.findtext("degree-alter") or "", "") + (d.findtext("degree-value") or "")
                      for d in h.findall("degree") if d.findtext("degree-type") != "subtract")
    bstep = h.findtext("bass/bass-step")
    bass = ("/" + bstep + {"-1": "b", "1": "#"}.get(h.findtext("bass/bass-alter") or "", "")) if bstep else ""
    return step + alter + text + degrees + bass


def from_xml(pairs):
    got = {}
    for pair in pairs:
        chart, path = pair.split("=", 1)
        root_el = ET.parse(path).getroot()
        part = root_el.find("part")
        for measure in part.findall("measure"):
            for h in measure.findall("harmony"):
                got.setdefault(chart, []).append(harmony_text(h))
    return got


if __name__ == "__main__":
    truth = json.load(open(sys.argv[1]))
    if sys.argv[2] == "crops":
        got, res = from_crops(sys.argv[3], sys.argv[4], grammar="--grammar" in sys.argv)
        print(f"route {res['route']}: {res['seconds']:.1f} s, {res['requests']} requests, {res['failed']} failed")
    else:
        got = from_xml(sys.argv[3:])
    for chart, v in score(truth, got).items():
        print(f"  {chart:10s} exact {v['exact']}/{v['chords']}  root {v['root']}/{v['chords']}  false chords {v['false']}")
