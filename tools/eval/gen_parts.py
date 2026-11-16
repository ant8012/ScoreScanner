"""Generate ensemble scores with printed part names and an exact answer key, rendered by MuseScore 4.

Each score is random music for a known ensemble (string quartet, piano trio, voice and piano, choir, wind and
brass quintets, duos...), long enough to run over several systems so the short names ("Vln. I") print too. MuseScore
renders page 1 as a PNG at 300 dpi, like PDFScanner's pages. The key lists each part's printed long and short
name, in score order (MuseScore prints them for a lone instrument too).

Most ensembles get a bracket joining their single-staff parts, as printed scores do. Each page is also written
rough, like a phone photo of a printed page: tilted a little, smaller, blurred, uneven light and noise.

usage: python3.12 tools/eval/gen_parts.py OUT_DIR COUNT [SEED]
writes OUT_DIR/NAME.musicxml, OUT_DIR/NAME-1.png, OUT_DIR/rough/NAME-1.png and OUT_DIR/truth.json
"""

import json
import random
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageFilter

MSCORE = "/Applications/MuseScore 4.app/Contents/MacOS/mscore"

# clef: (sign, line, octave change); range as MIDI numbers
TREBLE, ALTO, BASS, TENOR_VOICE = ("G", 2, 0), ("C", 3, 0), ("F", 4, 0), ("G", 2, -1)
INSTR = {
    "violin": (TREBLE, 55, 88), "viola": (ALTO, 48, 76), "cello": (BASS, 36, 64), "bass": (BASS, 28, 52),
    "flute": (TREBLE, 60, 93), "oboe": (TREBLE, 58, 88), "clarinet": (TREBLE, 52, 86), "horn": (TREBLE, 55, 77),
    "bassoon": (BASS, 34, 65), "trumpet": (TREBLE, 55, 82), "trombone": (BASS, 40, 67), "tuba": (BASS, 28, 53),
    "soprano": (TREBLE, 60, 79), "alto": (TREBLE, 55, 74), "tenor": (TENOR_VOICE, 48, 67), "baritone": (BASS, 43, 64),
    "bass_voice": (BASS, 40, 60), "guitar": (TENOR_VOICE, 40, 76), "piano": (None, 36, 84), "sax": (TREBLE, 58, 86),
}

# ensembles: (kind, long names, short names); several spellings each
ENSEMBLES = [
    [("violin", "Violin I", "Vln. I"), ("violin", "Violin II", "Vln. II"), ("viola", "Viola", "Vla."),
     ("cello", "Violoncello", "Vc.")],
    [("violin", "Violin 1", "Vln. 1"), ("violin", "Violin 2", "Vln. 2"), ("viola", "Viola", "Vla."),
     ("cello", "Cello", "Vc.")],
    [("violin", "Violin", "Vln."), ("cello", "Violoncello", "Vc."), ("piano", "Piano", "Pno.")],
    [("violin", "Violin", "Vln."), ("piano", "Piano", "Pno.")],
    [("cello", "Cello", "Vc."), ("piano", "Piano", "Pno.")],
    [("soprano", "Voice", "V."), ("piano", "Piano", "Pno.")],
    [("soprano", "Soprano", "S."), ("piano", "Piano", "Pno.")],
    [("tenor", "Tenor", "T."), ("piano", "Pianoforte", "Pf.")],
    [("soprano", "Soprano", "S."), ("alto", "Alto", "A."), ("tenor", "Tenor", "T."), ("bass_voice", "Bass", "B.")],
    [("soprano", "Soprano", "S."), ("alto", "Alto", "A."), ("tenor", "Tenor", "T."), ("bass_voice", "Bass", "B."),
     ("piano", "Organ", "Org.")],
    [("flute", "Flute", "Fl."), ("oboe", "Oboe", "Ob."), ("clarinet", "Clarinet in B♭", "Cl."),
     ("horn", "Horn in F", "Hn."), ("bassoon", "Bassoon", "Bsn.")],
    [("trumpet", "Trumpet 1", "Tpt. 1"), ("trumpet", "Trumpet 2", "Tpt. 2"), ("horn", "Horn", "Hn."),
     ("trombone", "Trombone", "Tbn."), ("tuba", "Tuba", "Tba.")],
    [("flute", "Flute", "Fl."), ("guitar", "Guitar", "Gtr.")],
    [("flute", "Flute", "Fl."), ("piano", "Piano", "Pno.")],
    [("clarinet", "Clarinet", "Cl."), ("viola", "Viola", "Vla."), ("piano", "Piano", "Pno.")],
    [("sax", "Alto Saxophone", "A. Sax."), ("piano", "Piano", "Pno."), ("bass", "Double Bass", "D.B.")],
    [("violin", "Violin I", "Vln. I"), ("violin", "Violin II", "Vln. II"), ("viola", "Viola", "Vla."),
     ("cello", "Violoncello", "Vc."), ("bass", "Contrabass", "Cb.")],
    [("violin", "Violin", "Vn."), ("viola", "Viola", "Va."), ("cello", "Cello", "Vc.")],
    [("trumpet", "Trumpet", "Tpt.")],
    [("piano", "Piano", "Pno.")],
]

KEYS = [-3, -2, -1, 0, 1, 2, 3]
TIMES = [(4, 4), (3, 4), (2, 4), (6, 8)]
STEP_OF = ["C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B"]
ALTER_OF = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0]


def pitch(midi):
    return f"<pitch><step>{STEP_OF[midi % 12]}</step>" + (
        f"<alter>{ALTER_OF[midi % 12]}</alter>" if ALTER_OF[midi % 12] else "") + f"<octave>{midi // 12 - 1}</octave></pitch>"


def bar_notes(rng, lo, hi, beats, unit, div, staff=None, voice=1):
    """Notes filling one bar: quarters, halves and eighth pairs (dotted quarters in 6/8)."""
    total = beats * div * 4 // unit
    out, left, cur = [], total, rng.randint(lo + 4, hi - 4)
    while left > 0:
        if unit == 8:
            d = 3 * div // 2 if left >= 3 * div // 2 and rng.random() < 0.5 else div // 2
        else:
            d = rng.choice([c for c in (div, div, 2 * div, div // 2) if c <= left])
        typ = {div // 2: "eighth", div: "quarter", 2 * div: "half", 3 * div // 2: "quarter"}[d]
        dot = "<dot/>" if d == 3 * div // 2 else ""
        cur = min(hi, max(lo, cur + rng.choice([-4, -2, -1, 0, 1, 2, 3, 5])))
        st = f"<staff>{staff}</staff>" if staff else ""
        if rng.random() < 0.1:
            out.append(f"<note><rest/><duration>{d}</duration><voice>{voice}</voice><type>{typ}</type>{dot}{st}</note>")
        else:
            out.append(f"<note>{pitch(cur)}<duration>{d}</duration><voice>{voice}</voice><type>{typ}</type>{dot}{st}</note>")
        left -= d
    return "".join(out)


def clef_xml(c, number=None):
    sign, line, octc = c
    n = f' number="{number}"' if number else ""
    return f"<clef{n}><sign>{sign}</sign><line>{line}</line>" + (
        f"<clef-octave-change>{octc}</clef-octave-change>" if octc else "") + "</clef>"


def score(rng, ens, bars, title):
    key, (beats, unit) = rng.choice(KEYS), rng.choice(TIMES)
    div = 2
    plist, parts = [], []
    # a bracket over the run of single-staff parts at the top (strings, winds, voices)
    run = next((k for k, e in enumerate(ens) if e[0] == "piano"), len(ens))
    bracket = run >= 2 and rng.random() < 0.75
    for k, (kind, long, short) in enumerate(ens):
        pid = f"P{k + 1}"
        if bracket and k == 0:
            plist.append('<part-group type="start" number="1"><group-symbol>bracket</group-symbol>'
                         '<group-barline>yes</group-barline></part-group>')
        plist.append(f'<score-part id="{pid}"><part-name>{long}</part-name>'
                     f'<part-abbreviation>{short}</part-abbreviation></score-part>')
        if bracket and k == run - 1:
            plist.append('<part-group type="stop" number="1"/>')
        clef, lo, hi = INSTR[kind]
        meas = []
        for m in range(bars):
            attrs = ""
            if m == 0:
                if kind == "piano":
                    clefs = clef_xml(TREBLE, 1) + clef_xml(BASS, 2)
                    staves = "<staves>2</staves>"
                else:
                    clefs, staves = clef_xml(clef), ""
                attrs = (f"<attributes><divisions>{div}</divisions><key><fifths>{key}</fifths></key>"
                         f"<time><beats>{beats}</beats><beat-type>{unit}</beat-type></time>{staves}{clefs}</attributes>")
            if kind == "piano":
                body = bar_notes(rng, 60, hi, beats, unit, div, staff=1, voice=1)
                body += f"<backup><duration>{beats * div * 4 // unit}</duration></backup>"
                body += bar_notes(rng, lo, 59, beats, unit, div, staff=2, voice=5)
            else:
                body = bar_notes(rng, lo, hi, beats, unit, div)
            meas.append(f'<measure number="{m + 1}">{attrs}{body}</measure>')
        parts.append(f'<part id="{pid}">{"".join(meas)}</part>')
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<score-partwise version="4.0">'
            f"<work><work-title>{title}</work-title></work><part-list>{''.join(plist)}</part-list>"
            f"{''.join(parts)}</score-partwise>")


def roughen(src, dst, rng):
    """A phone-photo look: tilted, smaller, blurred, uneven light and grain."""
    im = Image.open(src).convert("L")
    im = im.rotate(rng.uniform(-0.8, 0.8), resample=Image.BICUBIC, expand=False, fillcolor=255)
    w = rng.randint(1600, 2200)
    im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
    im = im.filter(ImageFilter.GaussianBlur(rng.uniform(0.6, 1.3)))
    shade = Image.linear_gradient("L").resize(im.size).point(lambda v: 255 - int(v * rng.uniform(0.15, 0.3)))
    im = Image.composite(im, Image.new("L", im.size, 0), shade)
    noise = Image.effect_noise(im.size, rng.uniform(8, 18))
    im = Image.blend(im, noise, 0.12)
    dst.parent.mkdir(exist_ok=True)
    im.save(dst)


def main():
    out, count = Path(sys.argv[1]), int(sys.argv[2])
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    out.mkdir(parents=True, exist_ok=True)
    truth = {}
    for i in range(count):
        ens = ENSEMBLES[i % len(ENSEMBLES)]
        name = f"parts{i:03d}"
        bars = rng.randint(10, 24) if len(ens) > 3 else rng.randint(16, 32)
        (out / f"{name}.musicxml").write_text(score(rng, ens, bars, f"Study No. {i + 1}"))
        subprocess.run([MSCORE, "-r", "300", "-o", str(out / f"{name}.png"), str(out / f"{name}.musicxml")],
                       capture_output=True)
        for extra in out.glob(f"{name}-[2-9].png"):
            extra.unlink()
        roughen(out / f"{name}-1.png", out / "rough" / f"{name}-1.png", rng)
        truth[name] = {"long": [e[1] for e in ens], "short": [e[2] for e in ens]}
        print(name, ", ".join(e[1] for e in ens))
    (out / "truth.json").write_text(json.dumps(truth, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
