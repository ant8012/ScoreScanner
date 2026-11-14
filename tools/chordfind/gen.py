"""Generate random lead sheets with an exact answer key for chord-symbol positions.

Each sheet is written twice by MuseScore from the same MusicXML: once in black (the scanner's input) and once with
every chord symbol in its own colour (the answer key). The colours never change layout, so the coloured pixels of
chord i are exactly where chord i is printed in the black page.

usage: python3.12 gen.py OUT_DIR COUNT [SEED]
"""

import json
import random
import subprocess
import sys
from pathlib import Path

MSCORE = "/Applications/MuseScore 4.app/Contents/MacOS/mscore"
STEPS = "CDEFGAB"

# (display text, MusicXML kind)
KINDS = [
    ("", "major"), ("m", "minor"), ("-", "minor"), ("7", "dominant"), ("maj7", "major-seventh"),
    ("Δ7", "major-seventh"), ("ma7", "major-seventh"), ("m7", "minor-seventh"), ("-7", "minor-seventh"),
    ("m7b5", "half-diminished"), ("ø7", "half-diminished"), ("o7", "diminished-seventh"),
    ("dim", "diminished"), ("sus4", "suspended-fourth"), ("7sus4", "suspended-fourth"), ("6", "major-sixth"),
    ("m6", "minor-sixth"), ("9", "dominant-ninth"), ("13", "dominant-13th"), ("m9", "minor-ninth"),
    ("maj9", "major-ninth"), ("7(b9)", "dominant"), ("7(#11)", "dominant"), ("7(#9)", "dominant"),
    ("7alt", "dominant"), ("6/9", "major-sixth"), ("add9", "major"), ("+", "augmented"), ("7(b13)", "dominant"),
]
COMMON = ["", "m", "7", "maj7", "m7", "m7b5", "6", "9", "-7", "Δ7", "7(b9)", "sus4", "13"]

STAFF_TEXT = ["Swing", "Fine", "D.C. al Fine", "To Coda", "rit.", "Bossa", "Solo", "a tempo", "Ballad", "Latin",
              "Gtr. fill", "Tacet 1st x", "Straight 8ths", "Vamp"]
REHEARSAL = ["A", "B", "C", "D", "Intro", "Verse", "Chorus", "Bridge", "Coda", "Interlude"]
LYRICS = "love you know the way we said it all be fore the night is gone and dream a gain to morrow come".split()

STYLES = {
    "standard": "",
    "jazz": """<musicalSymbolFont>Petaluma</musicalSymbolFont><musicalTextFont>Petaluma Text</musicalTextFont>
<chordStyle>jazz</chordStyle><chordsXmlFile>chords_jazz.xml</chordsXmlFile>
<harmonyFontFace>MuseJazz Text</harmonyFontFace><chordSymbolAFontFace>MuseJazz Text</chordSymbolAFontFace><chordSymbolBFontFace>MuseJazz Text</chordSymbolBFontFace><defaultFontFace>MuseJazz Text</defaultFontFace>
<titleFontFace>MuseJazz Text</titleFontFace><rehearsalMarkFontFace>MuseJazz Text</rehearsalMarkFontFace>
<staffTextFontFace>MuseJazz Text</staffTextFontFace><tempoFontFace>MuseJazz Text</tempoFontFace>""",
}


def colour(i):
    """Chord i's colour: blue channel 0, red and green carry the index (decoded in key.py)."""
    i += 1
    return (i % 9) * 25, (i // 9) * 25, 0


def chord(rng):
    step = rng.choice(STEPS)
    alter = rng.choice([0, 0, 0, -1, -1, 1])
    text = rng.choice(COMMON if rng.random() < 0.7 else [k for k, _ in KINDS])
    kind = dict(KINDS)[text] if text in dict(KINDS) else "major"
    bass = None
    if rng.random() < 0.15:
        bass = (rng.choice(STEPS), rng.choice([0, 0, -1, 1]))
    name = step + {0: "", -1: "b", 1: "#"}[alter] + text
    if bass:
        name += "/" + bass[0] + {0: "", -1: "b", 1: "#"}[bass[1]]
    return dict(step=step, alter=alter, text=text, kind=kind, bass=bass, name=name)


def harmony_xml(c, rgb):
    hexc = "#%02X%02X%02X" % rgb if rgb else None
    attrs = f' color="{hexc}"' if hexc else ""
    root = f"<root><root-step>{c['step']}</root-step>" + (
        f"<root-alter>{c['alter']}</root-alter>" if c["alter"] else "") + "</root>"
    kind = f'<kind text="{c["text"]}">{c["kind"]}</kind>' if c["text"] else f'<kind text="">{c["kind"]}</kind>'
    bass = ""
    if c["bass"]:
        bass = f"<bass><bass-step>{c['bass'][0]}</bass-step>" + (
            f"<bass-alter>{c['bass'][1]}</bass-alter>" if c["bass"][1] else "") + "</bass>"
    return f"<harmony{attrs}>{root}{kind}{bass}</harmony>"


# Rhythm patterns in eighths for 4/4 and 3/4 (negative = rest).
PATTERNS = {
    4: [[2, 2, 2, 2], [4, 4], [8], [2, 2, 4], [1, 1, 1, 1, 2, 2], [3, 1, 2, 2], [2, 1, 1, 2, 2], [6, 2],
        [1, 1, 2, 1, 1, 2], [-2, 2, 2, 2], [2, 2, 2, 1, 1], [4, 2, 1, 1], [1, 2, 1, 2, 2], [-4, 2, 2]],
    3: [[2, 2, 2], [4, 2], [6], [2, 4], [1, 1, 2, 2], [3, 1, 2], [-2, 2, 2], [2, 1, 1, 2]],
}
TYPES = {1: ("eighth", 0), 2: ("quarter", 0), 3: ("quarter", 1), 4: ("half", 0), 6: ("half", 1), 8: ("whole", 0)}
# Diatonic positions: 0 = C4. Melodies live around E4..E5, with excursions above the staff.
def pitch(pos):
    return STEPS[pos % 7], 4 + pos // 7


def sheet(rng, index):
    beats = rng.choice([4, 4, 4, 3])
    bars = rng.choice([8, 12, 16, 16, 24, 32])
    style = rng.choice(["standard", "jazz"])
    fifths = rng.randint(-4, 3)
    high = rng.random() < 0.4          # melody climbs onto ledger lines above the staff
    with_lyrics = rng.random() < 0.35
    with_rehearsal = rng.random() < 0.6
    with_text = rng.random() < 0.6
    with_slurs = rng.random() < 0.4
    with_dynamics = rng.random() < 0.3
    with_volta = rng.random() < 0.3 and bars >= 8
    per_system = rng.choice([None, None, 4, 4, 3, 5])
    title = rng.choice(["Blue Harbour", "Night Song", "Test Tune", "Evening Lights", "Practice Chart", "Lead Sheet"])

    chords, measures = [], []
    pos = rng.randint(2, 6)
    lyric_i = 0
    for b in range(1, bars + 1):
        parts = []
        if per_system and b > 1 and (b - 1) % per_system == 0:
            parts.append('<print new-system="yes"/>')
        if b == 1:
            parts.append(f'<attributes><divisions>2</divisions><key><fifths>{fifths}</fifths></key>'
                         f'<time><beats>{beats}</beats><beat-type>4</beat-type></time>'
                         f'<clef><sign>G</sign><line>2</line></clef></attributes>')
            parts.append('<direction placement="above"><direction-type><words font-weight="bold">'
                         f'{rng.choice(["Medium Swing", "Bossa Nova", "Ballad", "Up Tempo", "Moderato"])}'
                         f'</words></direction-type><sound tempo="{rng.randint(60, 200)}"/></direction>')
        if with_volta and b == bars - 1:
            parts.append('<barline location="left"><ending number="1" type="start">1.</ending></barline>')
        if with_rehearsal and (b == 1 or (b - 1) % 8 == 0) and rng.random() < 0.8:
            parts.append('<direction placement="above"><direction-type><rehearsal enclosure="square">'
                         f'{rng.choice(REHEARSAL)}</rehearsal></direction-type></direction>')
        if with_text and rng.random() < 0.12 and b > 1:
            parts.append('<direction placement="above"><direction-type><words font-style="italic">'
                         f'{rng.choice(STAFF_TEXT)}</words></direction-type></direction>')
        if with_dynamics and rng.random() < 0.15:
            parts.append(f'<direction placement="{rng.choice(["below", "below", "above"])}"><direction-type>'
                         f'<dynamics><{rng.choice(["p", "mf", "f", "mp"])}/></dynamics></direction-type></direction>')

        pattern = rng.choice(PATTERNS[beats])
        onsets, t = [], 0
        for d in pattern:
            onsets.append(t)
            t += abs(d)
        # Which onsets get chords: 1 (most bars), 2, sometimes 3-4, sometimes none.
        k = rng.choices([0, 1, 2, 3, 4], weights=[8, 50, 32, 7, 3])[0]
        k = min(k, len(onsets))
        if b == 1:
            k = max(k, 1)
        chosen = sorted(rng.sample(range(len(onsets)), k))
        if chosen and rng.random() < 0.8 and 0 not in chosen:
            chosen[0] = 0
            chosen = sorted(set(chosen))

        slur_open = with_slurs and rng.random() < 0.3 and len(pattern) >= 3
        for j, d in enumerate(pattern):
            if j in chosen and len(chords) < 79:
                c = chord(rng)
                c.update(bar=b, onset_eighths=onsets[j], beat=1 + onsets[j] / 2, index=len(chords), page=None)
                chords.append(c)
                parts.append(("H", c))
            typ, dot = TYPES[abs(d)]
            if d < 0:
                parts.append(f'<note><rest/><duration>{abs(d)}</duration><type>{typ}</type>'
                             + ("<dot/>" if dot else "") + "</note>")
                continue
            lo, hi = (2, 13) if high else (2, 9)
            pos = min(hi, max(lo, pos + rng.choice([-2, -1, -1, 0, 1, 1, 2, 3 if high else 1])))
            step, octave = pitch(pos)
            notations = ""
            if slur_open and j == 0:
                notations = '<notations><slur type="start" placement="above" number="1"/></notations>'
            elif slur_open and j == len(pattern) - 1:
                notations = '<notations><slur type="stop" number="1"/></notations>'
            lyric = ""
            if with_lyrics:
                lyric = f'<lyric number="1"><syllabic>single</syllabic><text>{LYRICS[lyric_i % len(LYRICS)]}</text></lyric>'
                lyric_i += 1
            parts.append(f'<note><pitch><step>{step}</step><octave>{octave}</octave></pitch>'
                         f'<duration>{abs(d)}</duration><type>{typ}</type>' + ("<dot/>" if dot else "")
                         + notations + lyric + "</note>")
        if slur_open and len(pattern) and pattern[-1] < 0:
            pass
        if b == bars:
            parts.append('<barline location="right"><bar-style>light-heavy</bar-style>'
                         + ('<ending number="1" type="stop"/>' if with_volta else "") + "</barline>")
        measures.append(parts)

    def xml(coloured):
        out = ['<?xml version="1.0" encoding="UTF-8"?>',
               f'<score-partwise version="4.0"><work><work-title>{title}</work-title></work>'
               '<identification><creator type="composer">Test Composer</creator></identification>'
               '<part-list><score-part id="P1"><part-name>Melody</part-name></score-part></part-list><part id="P1">']
        for b, parts in enumerate(measures, 1):
            out.append(f'<measure number="{b}">')
            for p in parts:
                if isinstance(p, tuple):
                    out.append(harmony_xml(p[1], colour(p[1]["index"]) if coloured else None))
                else:
                    out.append(p)
            out.append("</measure>")
        out.append("</part></score-partwise>")
        return "\n".join(out)

    meta = dict(index=index, beats=beats, bars=bars, style=style, high=high, lyrics=with_lyrics,
                rehearsal=with_rehearsal, text=with_text, slurs=with_slurs, dynamics=with_dynamics,
                volta=with_volta, chords=chords)
    return meta, xml(False), xml(True)


def main():
    out = Path(sys.argv[1])
    count = int(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    for style, body in STYLES.items():
        (out / f"{style}.mss").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n<museScore version="4.70"><Style>'
            + body + "</Style></museScore>\n")
    for i in range(count):
        meta, plain, coloured = sheet(rng, i)
        name = f"sheet{i:03d}"
        (out / f"{name}.musicxml").write_text(plain)
        (out / f"{name}-key.musicxml").write_text(coloured)
        dpi = rng.choice([150, 200, 300])
        meta["dpi"] = dpi
        style = ["-S", str(out / f"{meta['style']}.mss")] if STYLES[meta["style"]] else []
        for src, dst in ((f"{name}.musicxml", f"{name}.png"), (f"{name}-key.musicxml", f"{name}-key.png")):
            subprocess.run([MSCORE, *style, "-r", str(dpi), "-o", str(out / dst), str(out / src)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        (out / f"{name}.json").write_text(json.dumps(meta, indent=1))
        print(name, meta["style"], meta["bars"], "bars", len(meta["chords"]), "chords", flush=True)


if __name__ == "__main__":
    main()
