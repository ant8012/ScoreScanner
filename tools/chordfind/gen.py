"""Generate random lead sheets with an exact answer key for chord-symbol positions.

Each sheet is written twice by MuseScore from the same MusicXML: once in black (the scanner's input) and once with
every chord symbol in its own colour (the answer key). The colours never change layout, so the coloured pixels of
chord i are exactly where chord i is printed in the black page.

usage: python3.12 gen.py OUT_DIR COUNT [SEED] [--variety] [--fonts "Font A,Font B"] [--focus] [--jazz]

--focus draws half the chords from FOCUS, the spellings the round-3 reader misread (madd9, aug, 6/9, Δ13...).
--jazz puts every --variety sheet in MuseScore's Jazz chord style.

--variety gives every sheet its own look, for training a chord reader: a random chord font (MuseScore's text fonts
and the Mac's handwriting-like fonts), size, bold or italic, extension size and height, stacked alterations,
fraction-style bass notes, left or centred chords, music font and resolution.
"""

import json
import random
import re
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
    # spellings real fakebooks use
    ("mi7", "minor-seventh"), ("MI7", "minor-seventh"), ("MA7", "major-seventh"), ("min7", "minor-seventh"),
    ("mi", "minor"), ("-7b5", "half-diminished"), ("°7", "diminished-seventh"), ("dim7", "diminished-seventh"),
    ("7b9", "dominant"), ("7#9", "dominant"), ("7#5", "augmented-seventh"), ("7(#9#5)", "dominant"),
    ("7(b9#5)", "dominant"), ("maj7(#11)", "major-seventh"), ("9sus4", "suspended-fourth"), ("7sus", "suspended-fourth"),
    ("13(b9)", "dominant-13th"), ("9(#11)", "dominant-ninth"), ("m(maj7)", "major-minor"), ("11", "dominant-11th"),
    ("m11", "minor-11th"), ("-9", "minor-ninth"), ("maj9(#11)", "major-ninth"), ("7b5", "dominant"), ("sus", "suspended-fourth"),
    ("Δ", "major-seventh"), ("ø", "half-diminished"), ("6/9", "major-sixth"), ("m6/9", "minor-sixth"), ("7(#11)", "dominant"),
]
COMMON = ["", "m", "7", "maj7", "m7", "m7b5", "6", "9", "-7", "Δ7", "7(b9)", "sus4", "13", "mi7", "MI7", "MA7", "mi",
          "7(#9#5)", "7(b9#5)", "6/9", "ma7", "mi9", "mi(b5)"]
# --focus (round 4): the spellings the round-3 reader misreads, drawn for half the chords. (text, kind, added degrees,
# altered degrees): MuseScore prints a chord's numbers only when the MusicXML carries them as degrees.
FOCUS = [
    ("madd9", "minor", [9], []), ("mi(add9)", "minor", [9], []), ("-add9", "minor", [9], []), ("add9", "major", [9], []),
    ("add2", "major", [2], []), ("2", "major", [2], []), ("aug", "augmented", [], []), ("+", "augmented", [], []),
    ("13", "dominant-13th", [], []), ("13#11", "dominant-13th", [], [(11, 1)]), ("9sus4", "suspended-fourth", [7, 9], []),
    ("sus2", "suspended-second", [], []), ("7sus2", "suspended-second", [7], []), ("sus2(add9)", "suspended-second", [9], []),
    ("6/9", "major-sixth", [9], []), ("m6/9", "minor-sixth", [9], []), ("Δ", "major-seventh", [], []),
    ("Δ7", "major-seventh", [], []), ("Δ9", "major-ninth", [], []), ("Δ13", "major-13th", [], []),
    ("Δ7(#5)", "major-seventh", [], [(5, 1)]), ("Δ13(#5)", "major-13th", [], [(5, 1)]),
    ("Δ(#11)", "major-seventh", [], [(11, 1)]), ("Δ7(#11)", "major-seventh", [], [(11, 1)]),
    ("maj7(#5)", "major-seventh", [], [(5, 1)]), ("o7", "diminished-seventh", [], []), ("o", "diminished", [], []),
    ("ø7", "half-diminished", [], []), ("m7b5", "half-diminished", [], []), ("min7(b6)", "minor-seventh", [], [(13, -1)]),
    ("min(omit3)", "minor", [], []), ("7sus(add3)", "suspended-fourth", [7, 3], []), ("sus4", "suspended-fourth", [], []),
    ("7sus4", "suspended-fourth", [7], []), ("m(maj7)", "major-minor", [], []), ("dim", "diminished", [], []),
]
# Drawn with MuseScore's symbols (<kind use-symbols="yes">): the small triangle, circle, ø and + of the Jazz style.
# A kind text of Δ7 is not enough: MuseScore reprints it as maj7.
SYMBOLS = [
    ("major-seventh", [], []), ("major-seventh", [], [(5, 1)]), ("major-seventh", [], [(11, 1)]),
    ("major-ninth", [], []), ("major-ninth", [], [(11, 1)]), ("major-13th", [], []), ("major-13th", [], [(5, 1)]),
    ("major-13th", [], [(11, 1)]), ("diminished-seventh", [], []), ("diminished", [], []),
    ("half-diminished", [], []), ("augmented", [], []), ("minor-seventh", [], []), ("minor-ninth", [], []),
    ("major-seventh", [], []), ("diminished-seventh", [], []), ("half-diminished", [], []),
]
FOCUS_SHARE = 0.0

ARTICULATIONS = ['<accent placement="above"/>', '<strong-accent placement="above" type="up"/>',
                 '<staccato placement="above"/>', '<tenuto placement="above"/>', '<staccatissimo placement="above"/>',
                 '<strong-accent placement="above" type="up"/>']

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


# Text fonts MuseScore can draw chord symbols in: its own, and the Mac's (several look handwritten).
CHORD_FONTS = ["Edwin", "FreeSerif", "FreeSans", "MuseJazz Text", "Petaluma Text", "Petaluma Script", "Campania",
               "Finale Broadway Text", "Finale Maestro Text", "Gootville Text", "MScore Text", "Leland Text",
               "Arial", "Arial Narrow", "Helvetica", "Times New Roman", "Georgia", "Futura", "Avenir Next", "Gill Sans",
               "Courier New", "Didot", "Noteworthy", "Marker Felt", "Bradley Hand", "Chalkboard SE", "Comic Sans MS",
               # LilyJAZZ (OpenLilyPondFonts, OFL), Real Book style; install it in ~/Library/Fonts, or MuseScore
               # silently falls back to a default font
               "lilyjazz-chord", "lilyjazz-text",
               # small capitals: lowercase quality letters print as small capitals after a full-size root (Cmi7 ->
               # C + small MI + 7), the New Real Book look
               "Copperplate", "Bodoni 72 Smallcaps"]
MUSIC_FONTS = [("Leland", "Leland Text"), ("Bravura", "Bravura Text"), ("Petaluma", "Petaluma Text"),
               ("Finale Maestro", "Finale Maestro Text"), ("Gootville", "Gootville Text"),
               ("Finale Broadway", "Finale Broadway Text")]


JAZZ_SHARE = 0.4   # --jazz: every sheet in MuseScore's Jazz chord style (superscripts, small triangle and circle)


def variety_style(rng):
    """A random look for one sheet: the .mss body and a short description."""
    font = rng.choice(CHORD_FONTS)
    music, music_text = rng.choice(MUSIC_FONTS)
    jazz = rng.random() < JAZZ_SHARE
    look = dict(font=font, music=music, jazz=jazz, size=rng.choice([9, 10, 10, 11, 12, 13, 14]),
                style=rng.choice([0, 0, 0, 1, 2]),              # normal, bold, italic
                ext_mag=round(rng.uniform(0.7, 1.0), 2), ext_adj=round(rng.uniform(-0.8, 0.0), 1),
                mod_mag=round(rng.uniform(0.7, 1.0), 2), mod_adj=round(rng.uniform(-0.6, 0.0), 1),
                stack=rng.random() < 0.4, stagger=rng.random() < 0.35, left=rng.random() < 0.35,
                spatium=round(rng.uniform(1.5, 2.0), 3))
    body = (f"<musicalSymbolFont>{music}</musicalSymbolFont><musicalTextFont>{music_text}</musicalTextFont>"
            + ("<chordStyle>jazz</chordStyle><chordsXmlFile>chords_jazz.xml</chordsXmlFile>" if jazz else "")
            + f"<chordSymbolAFontFace>{font}</chordSymbolAFontFace><chordSymbolBFontFace>{font}</chordSymbolBFontFace>"
            + f"<chordSymbolAFontSize>{look['size']}</chordSymbolAFontSize>"
            + f"<chordSymbolAFontStyle>{look['style']}</chordSymbolAFontStyle>"
            + f"<chordExtensionMag>{look['ext_mag']}</chordExtensionMag><chordExtensionAdjust>{look['ext_adj']}</chordExtensionAdjust>"
            + f"<chordModifierMag>{look['mod_mag']}</chordModifierMag><chordModifierAdjust>{look['mod_adj']}</chordModifierAdjust>"
            + f"<verticallyStackModifiers>{int(look['stack'])}</verticallyStackModifiers>"
            + f"<chordBassNoteStagger>{int(look['stagger'])}</chordBassNoteStagger>"
            + (f"<chordSymPosition>left</chordSymPosition>" if look["left"] else "")
            + f"<spatium>{look['spatium']}</spatium>")
    return body, look


def colour(i):
    """Chord i's colour: blue channel 0, red and green carry the index (decoded in key.py)."""
    i += 1
    return (i % 9) * 25, (i // 9) * 25, 0


def chord(rng):
    step = rng.choice(STEPS)
    alter = rng.choice([0, 0, 0, -1, -1, 1])
    degrees = None
    symbols = False
    if rng.random() < FOCUS_SHARE * 0.4:
        kind, add, alt = rng.choice(SYMBOLS)
        text, symbols = "", True
        degrees = [(d, 0, "add") for d in add] + [(d, a, "alter" if d == 5 else "add") for d, a in alt]
    elif rng.random() < FOCUS_SHARE:
        text, kind, add, alt = rng.choice(FOCUS)
        degrees = [(d, 0, "add") for d in add] + [(d, a, "alter" if d == 5 else "add") for d, a in alt]
    else:
        text = rng.choice(COMMON if rng.random() < 0.7 else [k for k, _ in KINDS])
        kind = dict(KINDS)[text] if text in dict(KINDS) else "major"
    bass = None
    if rng.random() < 0.25:
        bass = (rng.choice(STEPS), rng.choice([0, 0, -1, 1]))
    name = step + {0: "", -1: "b", 1: "#"}[alter] + text
    if bass:
        name += "/" + bass[0] + {0: "", -1: "b", 1: "#"}[bass[1]]
    return dict(step=step, alter=alter, text=text, kind=kind, bass=bass, name=name, degrees=degrees, symbols=symbols)


def harmony_xml(c, rgb):
    hexc = "#%02X%02X%02X" % rgb if rgb else None
    attrs = f' color="{hexc}"' if hexc else ""
    root = f"<root><root-step>{c['step']}</root-step>" + (
        f"<root-alter>{c['alter']}</root-alter>" if c["alter"] else "") + "</root>"
    kind = f'<kind text="{c["text"]}">{c["kind"]}</kind>' if c["text"] else f'<kind text="">{c["kind"]}</kind>'
    if c.get("symbols"):
        kind = f'<kind use-symbols="yes">{c["kind"]}</kind>'
    # Alterations and added tones as MusicXML degrees: MuseScore drops them when they are only in the kind's text.
    degrees = ""
    if c.get("degrees") is not None:
        degrees = "".join(f"<degree><degree-value>{d}</degree-value><degree-alter>{a}</degree-alter>"
                          f"<degree-type>{t}</degree-type></degree>" for d, a, t in c["degrees"])
    elif c["kind"] not in ("half-diminished",):
        for acc, num in re.findall(r"([b#])(5|9|11|13)", c["text"]):
            alter = -1 if acc == "b" else 1
            typ = "alter" if num == "5" else "add"
            if num == "5" and c["kind"] == "augmented-seventh":
                continue
            degrees += (f"<degree><degree-value>{num}</degree-value><degree-alter>{alter}</degree-alter>"
                        f"<degree-type>{typ}</degree-type></degree>")
    bass = ""
    if c["bass"]:
        bass = f"<bass><bass-step>{c['bass'][0]}</bass-step>" + (
            f"<bass-alter>{c['bass'][1]}</bass-alter>" if c["bass"][1] else "") + "</bass>"
    return f"<harmony{attrs}>{root}{kind}{bass}{degrees}</harmony>"


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
    with_artic = rng.random() < 0.5
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
            inner = ""
            if slur_open and j == 0:
                inner += '<slur type="start" placement="above" number="1"/>'
            elif slur_open and j == len(pattern) - 1:
                inner += '<slur type="stop" number="1"/>'
            # accents and other articulations: above the staff they look like letters (a row of ^ was read as "A")
            if with_artic and rng.random() < 0.3:
                inner += "<articulations>" + rng.choice(ARTICULATIONS) + "</articulations>"
            notations = f"<notations>{inner}</notations>" if inner else ""
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


FIFTHS = "FCGDAEB"


def tpc_name(tpc):
    """MuseScore's tonal pitch class (14 = C, one step per fifth) as a note name."""
    t = int(tpc) - 13
    return FIFTHS[t % 7] + {-2: "bb", -1: "b", 0: "", 1: "#", 2: "##"}[t // 7]


def printed_chords(mscx):
    """The chords as MuseScore stored them after reading the MusicXML (root, quality text, bass), in score order:
    what it prints, whatever the MusicXML asked for."""
    out = []
    for h in re.findall(r"<harmonyInfo>(.*?)</harmonyInfo>", Path(mscx).read_text(), re.S):
        name = re.search(r"<name>(.*?)</name>", h, re.S)
        root = re.search(r"<root>(-?\d+)</root>", h)
        bass = re.search(r"<bass>(-?\d+)</bass>", h)
        if not root:
            out.append(None)
            continue
        quality = name.group(1) if name else ""
        # symbol spellings as drawn: ^ and t are MuseScore's triangle, a leading 0 its half-diminished ø
        quality = re.sub(r"^(\^|t)", "Δ", quality)
        quality = re.sub(r"^0", "ø", quality)
        text = tpc_name(root.group(1)) + quality
        if bass:
            text += "/" + tpc_name(bass.group(1))
        out.append(text.replace("&amp;", "&"))
    return out


def main():
    skip = {i + 1 for i, a in enumerate(sys.argv) if a == "--fonts"}
    args = [a for i, a in enumerate(sys.argv) if i > 0 and i not in skip and not a.startswith("--")]
    variety = "--variety" in sys.argv
    global FOCUS_SHARE, JAZZ_SHARE
    if "--focus" in sys.argv:
        FOCUS_SHARE = 0.5
    if "--jazz" in sys.argv:
        JAZZ_SHARE = 1.0
    if "--fonts" in sys.argv:
        # --fonts replaces the chord fonts --variety picks from (e.g. only handwriting-style fonts)
        CHORD_FONTS[:] = [f.strip() for f in sys.argv[sys.argv.index("--fonts") + 1].split(",") if f.strip()]
    out = Path(args[0])
    count = int(args[1])
    seed = int(args[2]) if len(args) > 2 else 1
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
        if variety:
            body, look = variety_style(rng)
            (out / f"{name}.mss").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<museScore version="4.70"><Style>'
                                             + body + "</Style></museScore>\n")
            style = ["-S", str(out / f"{name}.mss")]
            meta["style"], meta["look"] = "variety", look
            dpi = meta["dpi"] = rng.choice([120, 150, 150, 200, 300])
        for src, dst in ((f"{name}.musicxml", f"{name}.png"), (f"{name}-key.musicxml", f"{name}-key.png")):
            subprocess.run([MSCORE, *style, "-r", str(dpi), "-o", str(out / dst), str(out / src)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        # What MuseScore actually prints for each chord, read back from its own file of the sheet.
        subprocess.run([MSCORE, "-o", str(out / f"{name}.mscx"), str(out / f"{name}.musicxml")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        try:
            printed = printed_chords(out / f"{name}.mscx")
            meta["printed"] = printed if len(printed) == len(meta["chords"]) else None
            (out / f"{name}.mscx").unlink()
        except FileNotFoundError:
            meta["printed"] = None
        (out / f"{name}.json").write_text(json.dumps(meta, indent=1))
        print(name, meta["style"], meta["bars"], "bars", len(meta["chords"]), "chords", flush=True)


if __name__ == "__main__":
    main()
