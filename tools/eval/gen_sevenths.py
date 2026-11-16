"""Lead sheets that print major-7 and minor-7 chords in every common spelling, with an answer key.

Capital M (major: DM7) against small m (minor: Dm7) is the case a chord reader most easily confuses, so each sheet
mixes them with the other spellings of the same two chords (maj7, Maj7, MA7, Ma7, Δ7 / mi7, MI7, min7, -7) and the
same sizes as 6 and 9 chords, on every root. MuseScore prints each chord exactly as its text says. Each page is also
written rough (gen_parts.roughen), and optionally in another chord font.

usage: python3.12 tools/eval/gen_sevenths.py OUT_DIR COUNT [SEED] [--sus | --other]
  --sus: sus2, sus4, 7sus, add9...; --other: dim, aug, power, 6/9, half-diminished, altered dominants
writes OUT_DIR/NAME.musicxml, NAME-1.png, rough/NAME-1.png, truth.json ({name: [chord, ...] in reading order},
the format score_reads.py takes) and kinds.json (per bar: root, MusicXML kind and printed suffix of each chord)
"""

import json
import random
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from gen_parts import MSCORE, roughen  # noqa: E402

ROOTS = [("C", 0), ("D", 0), ("E", 0), ("F", 0), ("G", 0), ("A", 0), ("B", 0),
         ("B", -1), ("E", -1), ("A", -1), ("F", 1), ("C", 1)]
# (printed suffix, MusicXML kind)
MAJOR = [("M7", "major-seventh"), ("maj7", "major-seventh"), ("Maj7", "major-seventh"), ("MA7", "major-seventh"),
         ("Ma7", "major-seventh"), ("Δ7", "major-seventh"), ("M9", "major-ninth"), ("M", "major"),
         ("M6", "major-sixth"), ("maj9", "major-ninth")]
# --sus: suspended and added-note chords instead
SUS = [("sus2", "suspended-second"), ("sus4", "suspended-fourth"), ("sus", "suspended-fourth"),
       ("7sus2", "suspended-second"), ("7sus4", "suspended-fourth"), ("7sus", "suspended-fourth"),
       ("9sus4", "suspended-fourth"), ("add9", "major"), ("2", "major"), ("sus2(add9)", "suspended-second")]
# --other: diminished, augmented, power, 6/9, half-diminished, altered dominants; with the degrees they carry
OTHER = [("dim", "diminished"), ("dim7", "diminished-seventh"), ("o7", "diminished-seventh"), ("aug", "augmented"),
         ("+", "augmented"), ("aug7", "augmented-seventh"), ("7#5", "dominant"), ("5", "power"), ("6/9", "major-sixth"),
         ("m6/9", "minor-sixth"), ("m7b5", "half-diminished"), ("ø7", "half-diminished"), ("7b9", "dominant"),
         ("7#9", "dominant"), ("13#11", "dominant-13th"), ("madd9", "minor"), ("maj7#5", "major-seventh"),
         ("7b5", "dominant"), ("9", "dominant-ninth"), ("13", "dominant-13th")]
MINOR = [("m7", "minor-seventh"), ("mi7", "minor-seventh"), ("MI7", "minor-seventh"), ("min7", "minor-seventh"),
         ("-7", "minor-seventh"), ("m9", "minor-ninth"), ("m", "minor"), ("m6", "minor-sixth"), ("mi9", "minor-ninth")]


# the added notes MuseScore names these chords by (its chords.xml): without them it prints only the kind
DEGREES = {"7sus2": [7], "7sus4": [7], "7sus": [7], "9sus4": [7, 9], "add9": [9], "2": [2], "sus2(add9)": [9],
           "6/9": [9], "m6/9": [9], "madd9": [9]}
# altered degrees: (value, alter)
ALTERED = {"7#5": [(5, 1)], "7b9": [(9, -1)], "7#9": [(9, 1)], "13#11": [(11, 1)], "maj7#5": [(5, 1)], "7b5": [(5, -1)]}


def harmony(step, alter, text, kind):
    alt = f"<root-alter>{alter}</root-alter>" if alter else ""
    deg = "".join(f"<degree><degree-value>{d}</degree-value><degree-alter>0</degree-alter>"
                  f"<degree-type>add</degree-type></degree>" for d in DEGREES.get(text, []))
    deg += "".join(f"<degree><degree-value>{d}</degree-value><degree-alter>{a}</degree-alter>"
                   f"<degree-type>alter</degree-type></degree>" for d, a in ALTERED.get(text, []))
    return (f'<harmony><root><root-step>{step}</root-step>{alt}</root><kind text="{text}">{kind}</kind>{deg}'
            '</harmony>')


def name(step, alter, text):
    return step + {0: "", -1: "b", 1: "#"}[alter] + text


def sheet(rng, title, sus=False, other=False):
    chords, meas, kinds = [], [], []
    for m in range(24):
        cells = []
        for _ in range(rng.choice([1, 2, 2])):
            step, alter = rng.choice(ROOTS)
            text, kind = rng.choice(OTHER if other else SUS if sus else MAJOR if rng.random() < 0.5 else MINOR)
            cells.append((step, alter, text, kind))
            chords.append(name(step, alter, text))
        kinds.append([[step + {0: "", -1: "b", 1: "#"}[alter], kind, text,
                       sorted([f"add{d}" for d in DEGREES.get(text, [])]
                              + [f"alter{d}{a:+d}" for d, a in ALTERED.get(text, [])])]
                      for step, alter, text, kind in cells])
        attrs = ("<attributes><divisions>1</divisions><key><fifths>0</fifths></key>"
                 "<time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef>"
                 "</attributes>") if m == 0 else ""
        body = ""
        per = 4 // len(cells)
        for c in cells:
            body += harmony(*c) + "".join(
                f"<note><pitch><step>{rng.choice('CDEFGAB')}</step><octave>{rng.choice([4, 5])}</octave></pitch>"
                f"<duration>1</duration><voice>1</voice><type>quarter</type></note>" for _ in range(per))
        meas.append(f'<measure number="{m + 1}">{attrs}{body}</measure>')
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<score-partwise version="4.0">'
           f"<work><work-title>{title}</work-title></work>"
           '<part-list><score-part id="P1"><part-name print-object="no">Lead</part-name></score-part></part-list>'
           f'<part id="P1">{"".join(meas)}</part></score-partwise>')
    return xml, chords, kinds


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out, count = Path(args[0]), int(args[1])
    rng = random.Random(int(args[2]) if len(args) > 2 else 1)
    sus = "--sus" in sys.argv
    other = "--other" in sys.argv
    out.mkdir(parents=True, exist_ok=True)
    truth, by_bar = {}, {}
    for i in range(count):
        nm = f"sev{i:03d}"
        xml, chords, kinds = sheet(rng, f"Changes No. {i + 1}", sus, other)
        (out / f"{nm}.musicxml").write_text(xml)
        subprocess.run([MSCORE, "-r", "300", "-o", str(out / f"{nm}.png"), str(out / f"{nm}.musicxml")],
                       capture_output=True)
        for extra in out.glob(f"{nm}-[2-9].png"):
            extra.unlink()
        roughen(out / f"{nm}-1.png", out / "rough" / f"{nm}-1.png", rng)
        truth[nm] = chords
        by_bar[nm] = kinds
        print(nm, len(chords), "chords")
    (out / "truth.json").write_text(json.dumps(truth, indent=1, ensure_ascii=False))
    # per bar: [root, MusicXML kind, printed suffix] for each chord, for score_sevenths.py
    (out / "kinds.json").write_text(json.dumps(by_bar, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
