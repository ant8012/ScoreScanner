"""Generate lead sheets with slash bars and an exact answer key, rendered by MuseScore 4.

Each one-page sheet mixes runs of slash bars (MusicXML's slash measure style, the way MuseScore's "fill with
slashes" prints them: a stemless slash per beat on the middle line) with melody bars, many of them traps for a
slash finder: bars of B quarters or eighths on the middle line, B halves and wholes, ties, beams, accents and
rests. Chord symbols sit above every bar, as in a lead sheet. Each page is also written rough (tilted, smaller,
blurred, uneven light, grain).

usage: python3.12 tools/eval/gen_slashes.py OUT_DIR COUNT [SEED]
writes OUT_DIR/NAME.musicxml, OUT_DIR/NAME-1.png, OUT_DIR/rough/NAME-1.png and OUT_DIR/truth.json
(truth: the 1-based numbers of the slash bars)
"""

import json
import random
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from gen_parts import MSCORE, pitch, roughen  # noqa: E402

ROOTS = [("C", 0), ("D", 0), ("E", -1), ("F", 0), ("G", 0), ("A", 0), ("B", -1), ("F", 1)]
KINDS = [("major", ""), ("minor", "m"), ("dominant", "7"), ("minor-seventh", "m7"), ("major-seventh", "maj7")]
B4 = 71


def harmony(rng):
    step, alter = rng.choice(ROOTS)
    kind, text = rng.choice(KINDS)
    alt = f"<root-alter>{alter}</root-alter>" if alter else ""
    return f'<harmony><root><root-step>{step}</root-step>{alt}</root><kind text="{text}">{kind}</kind></harmony>'


def note(midi, dur, typ, extra="", dot=False, tie=None):
    t = f'<tie type="{tie}"/>' if tie else ""
    tn = f'<notations><tied type="{tie}"/></notations>' if tie else ""
    return (f"<note>{pitch(midi)}<duration>{dur}</duration>{t}<voice>1</voice><type>{typ}</type>"
            f"{'<dot/>' if dot else ''}{extra}{tn}</note>")


def rest(dur, typ):
    return f"<note><rest/><duration>{dur}</duration><voice>1</voice><type>{typ}</type></note>"


def melody_bar(rng, beats, kind):
    """A bar of melody (div = 2 per quarter). Kinds that look most like slashes are on B4."""
    q, e = 2, 1
    if kind == "b_quarters":
        return "".join(note(B4, q, "quarter") for _ in range(beats))
    if kind == "b_eighths":
        out = []
        for i in range(beats):
            out.append(note(B4, e, "eighth", "<beam number=\"1\">begin</beam>"))
            out.append(note(B4, e, "eighth", "<beam number=\"1\">end</beam>"))
        return "".join(out)
    if kind == "b_long":
        if beats == 4:
            return rng.choice([note(B4, 8, "whole"), note(B4, 4, "half") + note(B4, 4, "half")])
        return note(B4, 6, "half", dot=True)
    if kind == "b_accents":
        return "".join(note(B4, q, "quarter", "<notations><articulations><accent/></articulations></notations>")
                       for _ in range(beats))
    if kind == "b_mixed":
        out, left = [], beats * q
        while left > 0:
            if rng.random() < 0.3:
                out.append(rest(q, "quarter")); left -= q
            else:
                out.append(note(B4, q, "quarter")); left -= q
        return "".join(out)
    # a free melody
    out, left, cur = [], beats * q, rng.randint(64, 79)
    while left > 0:
        d = rng.choice([c for c in (e, q, q, 2 * q) if c <= left])
        typ = {e: "eighth", q: "quarter", 2 * q: "half"}[d]
        cur = min(84, max(60, cur + rng.choice([-3, -2, -1, 1, 2, 4])))
        out.append(rest(d, typ) if rng.random() < 0.12 else note(cur, d, typ))
        left -= d
    return "".join(out)


def sheet(rng, title):
    beats = rng.choice([4, 4, 4, 3])
    key = rng.choice([0, 1, 2, 3, 4])   # B is plain in these keys: the B traps print no natural
    bars = rng.randint(20, 28)
    slash, m, kinds = set(), 0, []
    while m < bars:
        if rng.random() < 0.35:
            run = min(bars - m, rng.randint(1, 8))
            for _ in range(run):
                kinds.append("slash"); slash.add(m + 1); m += 1
        else:
            run = min(bars - m, rng.randint(1, 4))
            for _ in range(run):
                kinds.append(rng.choice(["melody", "melody", "b_quarters", "b_eighths", "b_long", "b_accents",
                                         "b_mixed"]))
                m += 1
    meas, in_slash = [], False
    for i, kind in enumerate(kinds):
        attrs = []
        if i == 0:
            attrs.append(f"<divisions>2</divisions><key><fifths>{key}</fifths></key>"
                         f"<time><beats>{beats}</beats><beat-type>4</beat-type></time>"
                         "<clef><sign>G</sign><line>2</line></clef>")
        if kind == "slash" and not in_slash:
            attrs.append('<measure-style><slash type="start" use-stems="no"/></measure-style>')
            in_slash = True
        elif kind != "slash" and in_slash:
            attrs.append('<measure-style><slash type="stop"/></measure-style>')
            in_slash = False
        a = f"<attributes>{''.join(attrs)}</attributes>" if attrs else ""
        body = "".join(note(B4, 2, "quarter") for _ in range(beats)) if kind == "slash" else melody_bar(rng, beats, kind)
        chords = harmony(rng) + (harmony(rng) if rng.random() < 0.4 else "")
        meas.append(f'<measure number="{i + 1}">{a}{chords}{body}</measure>')
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<score-partwise version="4.0">'
           f"<work><work-title>{title}</work-title></work>"
           '<part-list><score-part id="P1"><part-name print-object="no">Lead</part-name></score-part></part-list>'
           f'<part id="P1">{"".join(meas)}</part></score-partwise>')
    return xml, sorted(slash), kinds


def main():
    out, count = Path(sys.argv[1]), int(sys.argv[2])
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    out.mkdir(parents=True, exist_ok=True)
    truth = {}
    for i in range(count):
        name = f"slash{i:03d}"
        xml, slash, kinds = sheet(rng, f"Tune No. {i + 1}")
        (out / f"{name}.musicxml").write_text(xml)
        subprocess.run([MSCORE, "-r", "300", "-o", str(out / f"{name}.png"), str(out / f"{name}.musicxml")],
                       capture_output=True)
        for extra in out.glob(f"{name}-[2-9].png"):
            extra.unlink()
        roughen(out / f"{name}-1.png", out / "rough" / f"{name}-1.png", rng)
        truth[name] = {"slash": slash, "bars": len(kinds), "kinds": kinds}
        print(name, len(kinds), "bars,", len(slash), "slash")
    (out / "truth.json").write_text(json.dumps(truth, indent=1))


if __name__ == "__main__":
    main()
