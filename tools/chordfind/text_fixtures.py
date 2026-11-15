"""Focused fixtures for the on-device text pass (LocalTextReader), rendered by MuseScore at 150 dpi.

usage: python3.12 text_fixtures.py OUT_DIR

Six one-page lead sheets with a title, a composer (one as "Music by ..."), rehearsal letters A and B, a segno and a
coda sign, navigation words (To Coda, D.S. al Coda, Coda, Fine, D.C. al Fine, D.S. al Fine) and a tempo mark:
"= 92" in 6/8, "Bright = 120" in 2/2 and "Medium Swing = 100" in 4/4 (no note: the meter decides the beat), and a
printed dotted quarter = 60, half = 80 (4/4) and quarter = 120 in 6/8 (the printed note decides). OUT_DIR/truth.json
lists what each should read. Check with `ScannerCheck --read-image OUT_DIR/NAME-1.png MODELS OUT.musicxml`.
"""
import json
import os
import subprocess
import sys
MSCORE = "/Applications/MuseScore 4.app/Contents/MacOS/mscore"
FIX = {
  "f68":   dict(title="Morning Walk", composer="Jane Doe", beats=6, type=8, tempo=("words", "= 92"), expect="dotted-quarter", bpm=92),
  "fcut":  dict(title="Fast Lane", composer="Music by Sam Rivers", beats=2, type=2, tempo=("words", "Bright = 120"), expect="half", bpm=120),
  "f44":   dict(title="Quiet Hour", composer="Ann Lee", beats=4, type=4, tempo=("words", "Medium Swing = 100"), expect="quarter", bpm=100),
  "fdot":  dict(title="Slow Dance", composer="Tom Hart", beats=4, type=4, tempo=("metronome", "quarter", True, 60), expect="dotted-quarter", bpm=60),
  "fhalf": dict(title="Long Road", composer="Kim Park", beats=4, type=4, tempo=("metronome", "half", False, 80), expect="half", bpm=80),
  "fq68":  dict(title="Sea Song", composer="Lou Grant", beats=6, type=8, tempo=("metronome", "quarter", False, 120), expect="quarter", bpm=120),
}
NAV = {  # measure (1-based) -> words written at it
  "f68": {4: "To Coda", 8: "D.S. al Coda", 10: "Coda"},
  "fcut": {6: "Fine", 8: "D.C. al Fine"},
  "f44": {8: "D.S. al Fine", 6: "Fine"},
  "fdot": {}, "fhalf": {}, "fq68": {},
}
ROOTS = ["C", "F", "G", "A", "D", "E", "Bb", "Eb"]
def measure(i, f):
    beats, typ = f["beats"], f["type"]
    div = 2
    length = beats * 4 * div // typ
    parts = []
    if i == 1:
        parts.append(f'<attributes><divisions>{div}</divisions><key><fifths>0</fifths></key><time><beats>{beats}</beats><beat-type>{typ}</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>')
        t = f["tempo"]
        if t[0] == "words":
            parts.append(f'<direction placement="above"><direction-type><words>{t[1]}</words></direction-type></direction>')
        else:
            dot = "<beat-unit-dot/>" if t[2] else ""
            parts.append(f'<direction placement="above"><direction-type><metronome><beat-unit>{t[1]}</beat-unit>{dot}<per-minute>{t[3]}</per-minute></metronome></direction-type></direction>')
        parts.append('<direction placement="above"><direction-type><rehearsal>A</rehearsal></direction-type></direction>')
        parts.append('<direction placement="above"><direction-type><segno/></direction-type></direction>')
    if i in (5,):
        parts.append('<direction placement="above"><direction-type><rehearsal>B</rehearsal></direction-type></direction>')
    if i == 9:
        parts.append('<direction placement="above"><direction-type><coda/></direction-type></direction>')
    r = ROOTS[(i - 1) % len(ROOTS)]
    step, alter = r[0], ("<root-alter>-1</root-alter>" if len(r) > 1 else "")
    parts.append(f'<harmony><root><root-step>{step}</root-step>{alter}</root><kind text="7">dominant</kind></harmony>')
    nav = NAV[f["key"]].get(i)
    if nav:
        parts.append(f'<direction placement="above"><direction-type><words>{nav}</words></direction-type></direction>')
    note = length // 2 if beats % 3 or typ != 8 else 3
    n = length // note
    names = {1: "eighth", 2: "quarter", 3: "quarter", 4: "half", 6: "half", 8: "whole"}
    for k in range(n):
        dot = "<dot/>" if note in (3, 6) else ""
        parts.append(f'<note><pitch><step>{"CDEFGAB"[(i + k) % 7]}</step><octave>5</octave></pitch><duration>{note}</duration><type>{names[note]}</type>{dot}</note>')
    brk = '<print new-system="yes"/>' if i in (5, 9) else ""
    return f'<measure number="{i}">{brk}{"".join(parts)}</measure>'
os.makedirs(sys.argv[1], exist_ok=True)
os.chdir(sys.argv[1])
for key, f in FIX.items():
    f["key"] = key
    xml = ('<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">'
           f'<work><work-title>{f["title"]}</work-title></work><identification><creator type="composer">{f["composer"]}</creator></identification>'
           '<part-list><score-part id="P1"><part-name print-object="no">Lead</part-name></score-part></part-list><part id="P1">'
           + "".join(measure(i, f) for i in range(1, 13)) + "</part></score-partwise>")
    open(f"{key}.musicxml", "w").write(xml)
    subprocess.run([MSCORE, "-r", "150", "-o", f"{key}.png", f"{key}.musicxml"], capture_output=True)
json.dump({k: dict(title=v["title"], composer=v["composer"], expect=v["expect"], bpm=v["bpm"], nav=NAV[k]) for k, v in FIX.items()},
          open("truth.json", "w"), indent=1)
print("ok")
