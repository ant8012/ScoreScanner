# Chord finder (prototype)

Finds each chord symbol above a staff as its own box, with its bar and beat, using copisteria's symbol boxes to
erase the music first. Python prototype; nothing here runs in the app yet.

| Script | What it does |
| --- | --- |
| `gen.py OUT N SEED` | Random lead sheets rendered by MuseScore 4, each twice: black (scanner input) and with every chord in its own colour (answer key). Standard and jazz-handwriting styles, with rehearsal marks, staff text, tempo, lyrics, voltas, slurs, high notes and dynamics. |
| `key.py` | Decodes the coloured render into one exact box per chord. |
| `find.py` | The finder: erase copisteria's music symbols (above the staff only notes it timed, and the accidentals and dots beside them), drop stems, ledger lines, slurs and beams by shape, group the rest into words, drop words before the music starts and words stacked above the chord row, then place each word on the note under it (centre or left alignment, decided per page) or, with no note under it, on the nearest strong beat. |
| `evaluate.py DATA [--draw DIR]` | Scores the finder on generated sheets: isolated, merged, split, missed, bar and beat, junk words. |
| `analyze.py DATA` | Measures the answer key: letter gaps inside and between chords, which anchor lines up with the note. |
| `export_crops.py OUT NAME=IMAGE:COPISTA ...` | Cuts the finder's word boxes from real pages for `--crop-bench`. |
| `score_reads.py` | Scores chord readings (a `--crop-bench` route, or a scan's MusicXML) against hand-made answer keys; `--grammar` keeps only readings that parse as chords. |
| `pdf_truth.py` | Exact chord boxes from PDFs whose chord symbols are real text (Sibelius writes one text object per chord, in a chord font), and scores the finder against them. Used with The Public Domain Song Anthology (CC0, two chord rows per staff). |
| `vlm_bench.py` | Reads exported crops with a local vision-language model through MLX-VLM (tested: LiquidAI LFM3-VL-2B). |

Copisteria's inputs come from `ScannerCheck --copista PAGE MODELS OUT` (`layout.json`, `tok.json`, `dets.json`).
Python 3.12 with numpy, scipy and Pillow.

The app's debug build has `--crop-bench DIR [--routes pcc,device]`: it reads the exported crops in
`Documents/DIR` with Private Cloud Compute and/or the on-device model and writes `results-<route>.json`. It is
compiled only in Debug and is not part of ScannerCore.

## Results (November 2026)

Generated sheets (30, 714 chords): 701 isolated, 0 merged, 700 on the right bar and beat.

Three real charts (two hand-copied, one engraved; 130 chords), read on an iPhone:

| Method | Exact | Root | False chords | Chord time |
| --- | --- | --- | --- | --- |
| Today's pipeline (PCC on bar strips) | 119 | 125 | 2 | ~37 s |
| PCC on finder crops | 120 | 128 | 11 | 53 s |
| On-device model on finder crops | 80 | 97 | 11 | 256 s |

Reading whole bars already works; the finder's value is the beat of each chord, which today's pipeline takes from
fixed metre defaults.

### Finder after the second round (lyrics, second chord rows, trailing pieces)

- Lyrics: text much closer to the staff above belongs to it. Junk words on the anthology 877 -> 302, no chord lost.
- A second chord row (alternate changes) is kept when one line of the page has 3+ stacked words across 2+ bars;
  otherwise words stacked above the chord row (tempo, style) are dropped.
- Trailing pieces join the chord before them: a raised extension (b9, b5), a small piece, or a lone accidental
  (one tall narrow glyph). Letter height is measured in the band chords stand in, so lyrics don't shrink it.
- Above a staff and in the gap below one, only notes copisteria timed (and their accidentals and dots) are erased;
  it reads handwritten chord letters as dynamics, accents and flats.

| Set | Chords | Isolated | Merged | Missed |
| --- | --- | --- | --- | --- |
| Generated (MuseScore, 2 styles) | 714 | 708 | 0 | 1 |
| Anthology, development (30 songs) | 1,545 | 1,534 (99.3%) | 0 | 11 |
| Anthology, held out (30 other songs, rules frozen) | 1,681 | 1,675 (99.6%) | 6 | 0 |

The six merges are one passage repeated: a lone F set close before Gm7, joined by the lone-capital rule.

Three real charts read end to end by LFM3-VL-2B (same reader and prompt, finder before -> after): crops 307 -> 191,
exact 110 -> 116 of 130, false chords 56 -> 21 (38 -> 11 with `--grammar`). These charts were looked at while
fixing, so they are development data.

LFM3-VL-2B (MLX 8-bit, Mac) on the first crops: 110 exact / 127 root of 130, close to PCC on reading, but it
names chords on junk crops (often the prompt's own examples), so it needs few junk crops and a grammar.

### Naming every crop (`--crop-bench ... --routes pcc-cat`)

`export_crops.py --all` also cuts the words the finder sets aside (text before the music, stacked words, boxed
rehearsal marks), and the `pcc-cat` route asks Private Cloud Compute what each crop is: chord, rehearsal, section,
navigation, tempo, instruction, lyric, title, number, notation or other. First run, on the three real charts and one
generated sheet (the phone reached its daily Private Cloud Compute quota before the other four sheets):

- Staff text: 13 of 14 marks found and named correctly (boxed rehearsal letters, Bridge, Verse, Intro, D.S., al
  Coda, To Coda, Fine, Slowly, Up Tempo, a tempo, Tacet 1st x, Gtr. fill). No chord was named a rehearsal mark; the
  chord-or-not prompt read the boxed A as an A chord and the page number 76 as F6. Missed: (Guitar), under the staff.
- Chords about the same as the chord-or-not prompt (163 vs 168 exact of 178, 6 vs 4 false), within run-to-run noise.
- Before it could replace the staff text pass: words of one direction arrive as separate crops (D.S. / al Coda), a
  segno or volta number glued to a chord loses or spoils the chord, and the "a" of "a tempo" was named rehearsal A.
