# Layout check on OpenScore

A page-level check of the reader on 79 pages from 18 OpenScore pieces (14 Lieder for voice and piano, the
first 3 pages of 4 string quartets; all CC0). MuseScore 4 renders each piece to a PDF to read and a
MusicXML to score against. Pages are rendered like `PDFScanner` (2480 px wide) and read with
`ScannerCheck --copista` on the Mac: notes only, no Private Cloud Compute.

```sh
W=<scratch folder>
python3 tools/eval/fetch.py $W                      # downloads the 18 pieces, renders PDF + truth
tools/eval/run.sh $W base                           # reads every page into $W/base/<piece>_pNN/
python3 tools/eval/score.py $W/corpus $W/base       # per-page status, note error (NED), bars off
python3 tools/eval/overlay.py PAGE.png $W/base/<page> out.png   # staffs coloured by system
```

`score.py` prints how many pages have the right staffs and systems, the mean note error over comparable
pages, and how many bars are off, and writes `pages.json`. Compare two runs page by page before keeping a
change. Baseline (Nov 13 2026, 0.1.0): 56 layout-ok, 23 missed-staffs; 75 comparable, NED 0.042, 36 bars off.
After the grouping fixes (edge rules, split staves, system placement): NED 0.036, 36 bars off; only
Faisst p3/p5 and Cowen *Past and Future* p4 change, all for the better.

The corpus is downloaded, never committed. The rendered pages are clean: they don't show photo problems such
as page curl or a binding shadow, so check those on real photos as well.

# Part names

`gen_parts.py` has MuseScore 4 print ensembles with known part names (string quartets, piano trio, voice and
piano, choir, wind and brass quintets, duos, lone instruments), most with a bracket, plus a rough photo-like
copy of each page. `score_parts.py` scores the names `ScannerCheck --read-image` writes.

```sh
python3.12 tools/eval/gen_parts.py tools/chordfind/data/partnames2 40 11
# scan each NAME-1.png (and rough/NAME-1.png) with ScannerCheck --read-image into scan/ (scan-rough/)
python3.12 tools/eval/score_parts.py tools/chordfind/data/partnames2/truth.json tools/chordfind/data/partnames2/scan
```

Nov 15 2026: 100 pages (60 clean, 40 bracketed in clean and rough copies), every long and short name right
(600). No names written on 59 lead-sheet and Real Book pages; the chord benchmark unchanged (666 / 710 / 14).

`score_sounds.py` opens each scan in desktop MuseScore 4 and checks the instrument each part gets from the
`instrument-sound` the scanner writes (and the transposition when the key is printed, "Clarinet in B♭").
Nov 15 2026: every part right (120) on the 40 bracketed pages, clean and rough.

# Slash bars

`gen_slashes.py` has MuseScore 4 print lead sheets mixing slash bars (MusicXML's slash measure style, as "fill
with slashes" prints them) with trap bars on the middle line (B quarters, eighths, halves, wholes, accents), plus a
rough copy of each. `score_slashes.py` scores the bars a scan writes with slashes, or lists them (`--list`) on
pages without a key.

Nov 15 2026 (scanner build): 38 synthetic pages, clean 420/420 and rough 189/190 slash bars, none false (pages
whose bar count the detector got wrong are skipped). 37 Real Book and benchmark pages: 14 slash bars written, all
real; bars holding more slashes than beats (two bars merged by a missed bar line) are left as read.

# Major and minor sevenths

`gen_sevenths.py` prints lead sheets mixing every common spelling of major and minor chords (M7, maj7, MA7, Δ7 /
m7, mi7, MI7, -7, and M, M6, m, m6, 9ths) on every root; `score_sevenths.py` scores root and kind per spelling.
Nov 15 2026: 1,203 chords on 30 clean pages all right after "M" and "M6" were fixed (they had been written as
major sevenths); the reader itself never swapped M and m on clean pages.

# Lyrics

`gen_lyrics.py` prints lead sheets with one or two verses (hyphenated words, held syllables with extender lines,
rests, punctuation) and a note-by-note key; `score_lyrics.py` scores what a scan writes, or lists it (`--list`) on
pages without a key.

Nov 15 2026: 40 held-out pages, clean 3,201 / 3,406 syllables exactly right (most misses punctuation), 1 false,
hyphenation 99.8%; rough copies 2,485 right, 29 false. On 37 Real Book and benchmark pages the real lyrics read
nearly word for word; 4 pages still get one line of instruction text ("Guitar sounds one octave lower...") as
lyrics.

`gen_sevenths.py --sus` and `--other` print sus and added-note chords, and diminished, augmented, power, 6/9,
half-diminished and altered dominants; the key lists each chord's added and altered degrees, which
`score_sevenths.py` checks. Nov 16 2026: what is read is written right; the reader misreads madd9 as ma9, drops the
9 of a stacked 6/9, reads aug as aug7, and loses a 13 or add9's number in a third to two thirds of bars.
