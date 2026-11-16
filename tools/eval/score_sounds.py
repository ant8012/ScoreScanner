"""Which instrument MuseScore gives each scanned part, against gen_parts.py's ensembles.

usage: python3.12 tools/eval/score_sounds.py TRUTH.json SCAN_DIR
Each SCAN_DIR/NAME.musicxml is opened in desktop MuseScore 4 (one at a time) and saved as .mscz; a part counts
when its instrument ID is the one its printed name stands for. Transposing parts with a printed key must also
carry that transposition.
"""

import glob
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

MSCORE = "/Applications/MuseScore 4.app/Contents/MacOS/mscore"

# printed long name in gen_parts.py -> (MuseScore instrument ID, semitones written to sounding)
EXPECTED = {
    "Violin": ("strings.violin", 0), "Violin I": ("strings.violin", 0), "Violin II": ("strings.violin", 0),
    "Violin 1": ("strings.violin", 0), "Violin 2": ("strings.violin", 0), "Viola": ("strings.viola", 0),
    "Violoncello": ("strings.cello", 0), "Cello": ("strings.cello", 0), "Contrabass": ("strings.contrabass", 0),
    "Double Bass": ("strings.contrabass", 0), "Piano": ("keyboard.piano", 0), "Pianoforte": ("keyboard.piano", 0),
    "Organ": ("keyboard.organ", 0), "Voice": ("voice.vocals", 0), "Soprano": ("voice.soprano", 0),
    "Alto": ("voice.alto", 0), "Tenor": ("voice.tenor", 0), "Bass": ("voice.bass", 0),
    "Flute": ("wind.flutes.flute", 0), "Oboe": ("wind.reed.oboe", 0),
    "Clarinet in B♭": ("wind.reed.clarinet.bflat", -2), "Clarinet": ("wind.reed.clarinet", 0),
    "Horn in F": ("brass.french-horn", -7), "Horn": ("brass.french-horn", 0), "Bassoon": ("wind.reed.bassoon", 0),
    "Trumpet": ("brass.trumpet", 0), "Trumpet 1": ("brass.trumpet", 0), "Trumpet 2": ("brass.trumpet", 0),
    "Trombone": ("brass.trombone", 0), "Tuba": ("brass.tuba", 0), "Guitar": ("pluck.guitar.acoustic", 0),
    "Alto Saxophone": ("wind.reed.saxophone.alto", 0),
}


def instruments(musicxml):
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "s.mscz"
        subprocess.run([MSCORE, "-o", str(out), musicxml], capture_output=True)
        if not out.exists():
            return None
        with zipfile.ZipFile(out) as z:
            x = z.read(next(n for n in z.namelist() if n.endswith(".mscx"))).decode()
    got = []
    for p in re.findall(r"<Part\b.*?</Part>", x, re.S):
        iid = re.search(r"<instrumentId>(.*?)<", p)
        tr = re.search(r"<transposeChromatic>(-?\d+)<", p)
        got.append((iid.group(1) if iid else "?", int(tr.group(1)) if tr else 0))
    return got


def main():
    truth = json.loads(Path(sys.argv[1]).read_text())
    right = wrong = 0
    for name, key in sorted(truth.items()):
        path = Path(sys.argv[2]) / f"{name}.musicxml"
        got = instruments(str(path)) if path.exists() else None
        if got is None or len(got) != len(key["long"]):
            print(f"{name}: parts differ ({got})")
            wrong += len(key["long"])
            continue
        for long, g in zip(key["long"], got):
            want = EXPECTED.get(long)
            if want and g == want:
                right += 1
            else:
                wrong += 1
                print(f"{name}: {long!r} -> {g}, want {want}")
    print(f"right {right}, wrong {wrong}")


if __name__ == "__main__":
    main()
