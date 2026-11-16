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
