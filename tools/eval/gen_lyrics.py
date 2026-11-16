"""Generate lead sheets with lyrics and an exact answer key, rendered by MuseScore 4.

Each one-page sheet is a melody with chord symbols and one or two verses: one-syllable words, words split over
several notes (MuseScore prints the hyphens), a word's last syllable held over more notes (an extender line),
rests with no syllable, and commas and full stops. Each page is also written rough (gen_parts.roughen).

usage: python3.12 tools/eval/gen_lyrics.py OUT_DIR COUNT [SEED]
writes OUT_DIR/NAME.musicxml, NAME-1.png, rough/NAME-1.png and truth.json: per page, per bar, per note in order,
null for a note with no syllable or a list per verse of [text, syllabic, extend] (or null for that verse)
"""

import json
import random
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from gen_parts import MSCORE, pitch, roughen  # noqa: E402

ONE = ["love", "heart", "dream", "moon", "night", "sing", "home", "stars", "light", "day", "you", "me", "the", "and",
       "a", "in", "of", "to", "my", "your", "shine", "rain", "blue", "sky", "go", "now", "all", "so", "with", "here"]
MANY = [["hap", "py"], ["for", "ev", "er"], ["mor", "ning"], ["sun", "shine"], ["to", "geth", "er"],
        ["hea", "ven"], ["dan", "cing"], ["beau", "ti", "ful"], ["lit", "tle"], ["mem", "o", "ries"],
        ["whis", "per"], ["gold", "en"], ["sum", "mer"], ["ev", "'ry"], ["slow", "ly"], ["mu", "sic"],
        ["star", "light"], ["yes", "ter", "day"], ["sweet", "heart"], ["sha", "dows"]]
ROOTS = ["C", "D", "E", "F", "G", "A", "Bb", "Eb"]
KINDS = [("major", ""), ("minor", "m"), ("dominant", "7"), ("minor-seventh", "m7"), ("major-seventh", "maj7")]


def words(rng, n):
    """n syllables: [(text, syllabic)], with a comma or full stop after some words."""
    out = []
    while len(out) < n:
        w = rng.choice(MANY) if rng.random() < 0.4 else [rng.choice(ONE)]
        w = w[: n - len(out)]
        if rng.random() < 0.12:
            w = w[:-1] + [w[-1] + rng.choice([",", ","])]
        if len(w) == 1:
            out.append((w[0], "single"))
        else:
            out += [(s, "begin" if i == 0 else "end" if i == len(w) - 1 else "middle") for i, s in enumerate(w)]
    if out and out[-1][1] in ("begin", "middle"):   # a word cut short by the count: close it
        out[-1] = (out[-1][0], "end" if out[-1][1] == "middle" else "single")
    return out


def harmony(rng):
    root = rng.choice(ROOTS)
    kind, text = rng.choice(KINDS)
    alt = "<root-alter>-1</root-alter>" if root.endswith("b") else ""
    return f'<harmony><root><root-step>{root[0]}</root-step>{alt}</root><kind text="{text}">{kind}</kind></harmony>'


def sheet(rng, title):
    beats = rng.choice([4, 4, 3])
    verses = rng.choice([1, 1, 2])
    bars = rng.randint(16, 24)
    # the melody: per bar a list of (duration in eighths, is_rest)
    rhythm = []
    for _ in range(bars):
        left, cells = beats * 2, []
        while left > 0:
            d = rng.choice([c for c in (1, 2, 2, 2, 4) if c <= left])
            cells.append((d, rng.random() < 0.1))
            left -= d
        rhythm.append(cells)
    # which notes start a syllable: every note, except notes that continue a held syllable
    slots, held = [], []
    for b, cells in enumerate(rhythm):
        for n, (d, rest) in enumerate(cells):
            if rest:
                continue
            if slots and not held_after(held, slots) and rng.random() < 0.12:
                held.append((b, n))   # this note continues the previous syllable
            else:
                slots.append((b, n))
    texts = [words(rng, len(slots)) for _ in range(verses)]
    # extender on a word-final syllable held over the next note(s)
    key = {}
    for i, (b, n) in enumerate(slots):
        key[(b, n)] = [[t[i][0], t[i][1], False] for t in texts]
    order = [(b, n) for b, cells in enumerate(rhythm) for n, (d, r) in enumerate(cells) if not r]
    for b, n in held:
        prev = max(s for s in order if s < (b, n) and s in key)
        for v in key[prev]:
            if v[1] in ("single", "end"):
                v[2] = True
    meas, truth = [], []
    cur = rng.randint(64, 72)
    for b, cells in enumerate(rhythm):
        attrs = (f"<attributes><divisions>2</divisions><key><fifths>0</fifths></key>"
                 f"<time><beats>{beats}</beats><beat-type>4</beat-type></time>"
                 "<clef><sign>G</sign><line>2</line></clef></attributes>") if b == 0 else ""
        body, row = harmony(rng) + (harmony(rng) if rng.random() < 0.3 else ""), []
        for n, (d, rest) in enumerate(cells):
            typ = {1: "eighth", 2: "quarter", 4: "half"}[d]
            if rest:
                body += f"<note><rest/><duration>{d}</duration><voice>1</voice><type>{typ}</type></note>"
                continue
            cur = min(76, max(60, cur + rng.choice([-3, -2, -1, 1, 2, 3])))
            lyr = ""
            if (b, n) in key:
                for vi, (text, syl, ext) in enumerate(key[(b, n)]):
                    lyr += (f'<lyric number="{vi + 1}"><syllabic>{syl}</syllabic><text>{text}</text>'
                            f'{"<extend/>" if ext else ""}</lyric>')
                row.append(key[(b, n)])
            else:
                row.append(None)
            body += (f"<note>{pitch(cur)}<duration>{d}</duration><voice>1</voice><type>{typ}</type>"
                     f"{lyr}</note>")
        truth.append(row)
        meas.append(f'<measure number="{b + 1}">{attrs}{body}</measure>')
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<score-partwise version="4.0">'
           f"<work><work-title>{title}</work-title></work>"
           '<part-list><score-part id="P1"><part-name print-object="no">Voice</part-name></score-part></part-list>'
           f'<part id="P1">{"".join(meas)}</part></score-partwise>')
    return xml, truth


def held_after(held, slots):
    """No two held notes in a row: the note before must start a syllable."""
    return bool(held) and held[-1] > slots[-1]


def main():
    out, count = Path(sys.argv[1]), int(sys.argv[2])
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    out.mkdir(parents=True, exist_ok=True)
    truth = {}
    for i in range(count):
        nm = f"lyr{i:03d}"
        xml, key = sheet(rng, f"Song No. {i + 1}")
        (out / f"{nm}.musicxml").write_text(xml)
        subprocess.run([MSCORE, "-r", "300", "-o", str(out / f"{nm}.png"), str(out / f"{nm}.musicxml")],
                       capture_output=True)
        for extra in out.glob(f"{nm}-[2-9].png"):
            extra.unlink()
        roughen(out / f"{nm}-1.png", out / "rough" / f"{nm}-1.png", rng)
        truth[nm] = key
        print(nm, sum(1 for r in key for c in r if c), "syllables")
    (out / "truth.json").write_text(json.dumps(truth, indent=1))


if __name__ == "__main__":
    main()
