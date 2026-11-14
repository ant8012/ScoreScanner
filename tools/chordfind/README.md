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
| `read_text.py CROPS [--truth T]` | Turns a `pcc-cat` reading into chords and staff text: joins the pieces of one direction (D.S. + al Coda), keeps a rehearsal mark only with a box around it, adds segno and coda signs from copisteria. |
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

Second round (fixes scored on the first run's saved answers; the phone run of all eight pages is still to do, the
phone was at its Private Cloud Compute quota):

- `read_text.py` joins neighbouring pieces of the same kind into one direction; rehearsal marks and section names
  stand alone, chords never join. A crop named rehearsal without a box joins the word beside it or becomes the chord
  it looks like; a one- or two-letter "lyric" above the staff joins a tempo or instruction beside it (the "a" of
  "a tempo" came back as a lyric, not a rehearsal mark).
- The finder erases copisteria's volta numbers above the staff, with the bracket hook touching them, so "1." no longer
  glues onto a chord. Its other hooks and its segno/coda above the staff are not trusted for erasing: on a
  handwritten chart they were raised 6s and 7s (segno 0.13 against 0.22 to 0.37 for real ones). Generated and
  anthology scores unchanged.
- `pcc-cat` labels boxed crops "boxed" and has an alsoPrinted field, so a chord with a sign beside it keeps both.
- Staff text on the four pages read: 10 -> 13 of 15 directions found whole, all named right. Missed: the "1" of
  "D.S. al Coda 1" (not transcribed) and (Guitar), under the staff.

### Blind test on Real Book pages (November 2026)

Eight pages sampled from four scanned fakebooks the owner supplied (New Real Book 1 and 2, Real Book 3, Real Book
6th edition; engraved and handwritten), 396 chords keyed by hand. The books stay outside the repository.

- Finder with rules frozen: 369/396 isolated (93.2%); 6 merged, 17 split, 4 missed. Causes: (1) chord letters
  sitting on the top staff line were erased as copisteria symbols it barely believes in (a C as a fermata at 0.06, a
  B as a natural at 0.07) because "above the staff" was judged by the symbol's bottom; (2) copisteria reported two
  staves shorter than printed, hiding the chords past their ends; (3) Real Book 3 sets chords loosely (4-5 px
  between letters, "B m7 b5"), wider than the 0.2-letter word gap.
- Fixes, now default: judge "above the staff" by a symbol's middle; search above a staff across the page's usual
  staff width; widen the word gap per line to the spacing it uses (median of letter gaps x1.5, at most 0.35 letter).
  A fixed wider gap was rejected: it merged 28-75 generated chords. Anthology and generated scores unchanged.
- After the fixes: 381/396 isolated (96.2%). Left: Real Book 3 lines whose spacing can't be measured (title text
  sets it, or too few chords), two merges where the print touches (Dbma7Gb13sus), a coda sign between chords.
- LFM3-VL-2B reading the crops (clear prompt): 293 -> 302 exact, 369 -> 375 root of 396, 71 -> 75 false chords.
  Its errors: a handwritten 7 read as 1 (D1, Gm1), the 7 dropped in slash chords (G7/F -> G/F), endings lost to
  splits.
- LFM3 cannot name what a crop is: with the category list (pcc-cat's task) it copied the definitions ("lyric: words
  of the sung text" for Am7) and fell from 279 to 151 exact of 335; a short two-line version fell to 140. Private
  Cloud Compute does this well; a small model needs one question per call.

Second blind set, rules frozen after the fixes above: nine more pages from the same four books, six drawn at random
and three picked as hard (a keyboard part, rhythm-slash sections with chords written in the staff, polychords).
242 chords keyed by hand.

| Pages | Chords | Isolated |
| --- | --- | --- |
| Random pages, clean lead sheets (5) | 150 | 146 (97.3%) |
| Random page: bass part with solo cues and chords two per beat (New Real Book 2 p.94) | 35 | 18 |
| Picked as hard (Safari keyboard part, Jump Monk, Wind Sprint) | 57 | 43 (75.4%) |

What fails, by kind:
- "Before the music": a line that opens on rhythm slashes or a bar rest copisteria doesn't detect has its first
  chord dropped (3). The music start should come from the clef, key and time signature, not the first note found.
- Stacked chords: a polychord or fraction slash chord (Dbma7(#11#5) over C, Eb 6/9) comes out as two words, top and
  bottom (9). Words only group along a line.
- Crowded chords: two chords per beat with inline tempo equations (Bmi7(b5) E7 8th=8th Asus) are boxed together.
- A row of accents (^) above the staff becomes the "chord row", and the chords above it are dropped as stacked (2).
- Chords written inside the staff among rhythm slashes are never searched (4).

LFM3-VL-2B on these crops: 179/242 exact, 210 root, 174 false chords. Clean pages read almost perfectly (Got a
Match? 19/19, Pure Imagination 46/47, One Note Samba 38/42); the false chords come from the hard pages' junk
(keyboard beams, accents, cue text), which LFM names as chords.

Fixes from the second set, now default, with a regression run on everything before:
- `music_start="header"`: the music starts after the clef, key and time signature copisteria found at the line
  start, or at the staff's start when a line has none, not at the first note found (which is late when a line opens
  on rhythm slashes or a bar rest).
- `stack_join`: a bass note written under its chord like a fraction joins it: a piece 0.9-1.4 letters wide touching
  the chord above (overlap at most 0.2 letter) under its right part. Triplet 3s (narrower) and a crowded chord tucked
  below-right (overlapping a third of a letter) stay apart; so does Eb 6/9's stacked 9.

| Set | Before | After |
| --- | --- | --- |
| Anthology, development | 1,534/1,545 | 1,540 (6 line-start chords recovered) |
| Anthology, held out | 1,675/1,681 | 1,675 |
| Generated | 708/714, 705 beats | 708, 705 |
| Real Book set 1 (by eye) | 381/396 | 381 |
| Real Book set 2 (by eye) | 207/242 | 216 (p.68 27/27, Swedish Pastry 15/15, Wind Sprint 11/13) |

Junk words rise by about 13 per set: bar numbers at line starts now pass the music-start check. LFM3 end to end
(exact / root / false chords): three real charts 116/127/23 (was 116/127/21); Real Book set 1 302/375/88 (was
302/375/75); set 2 183/215/176 (was 179/210/174). LFM names many of the new line-start numbers as chords ("A"),
the cloud reader rejects them.
