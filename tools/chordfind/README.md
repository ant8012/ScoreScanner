# Chord finder (prototype)

Finds each chord symbol above a staff as its own box, with its bar and beat, using copisteria's symbol boxes to
erase the music first. The finder now also runs in ScannerCore (`ChordFinder.swift`, on every scan as
`ScanResult.chordWords`), ported rule for rule from `find.py`; `finder_parity.py` checks the two agree.

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
| `ocr_bench.py MODEL CROPS ROUTE` | Reads crops with a PaddleOCR text recogniser (PP-OCRv6 tiny/small/medium), no language model; a reading is a chord when it parses as one. |
| `finder_parity.py SCANNERCHECK --dir PAGES COP` | Runs `ScannerCheck --chordfind` (the Swift finder) and `find.py` on the same pages and compares every box, kind, bar, beat and anchor. |
| `vlm_bench.py` | Reads exported crops with a local vision-language model through MLX-VLM (tested: LiquidAI LFM3-VL-2B). |

Copisteria's inputs come from `ScannerCheck --copista PAGE MODELS OUT` (`layout.json`, `tok.json`, `dets.json`).
Python 3.12 with numpy, scipy and Pillow.

The ScoreScanner app's debug build (private app repository) has `--crop-bench DIR [--routes pcc,device]`: it reads the exported crops in
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

### PP-OCRv6 on the finder's crops (no training)

PaddleOCR 3.7's PP-OCRv6 recognisers, out of the box, on the same crops LFM3 read (3 real charts + both Real Book
sets, 768 chords, 1,221 crops); a reading counts as a chord when it parses as one. Mac CPU times.

| Reader | Exact | Root | False chords | ms/crop | Size |
| --- | --- | --- | --- | --- | --- |
| LFM3-VL-2B (MLX 8-bit) | 601 (78%) | 717 | 287 | ~250 | ~2 GB |
| PP-OCRv6 small | 519 (68%) | 595 | 50 | 58 | ~20 MB |
| PP-OCRv6 medium | 495 (64%) | 626 | 78 | 140 | ~73 MB |
| PP-OCRv6 tiny | 451 (59%) | 589 | 66 | 17 | ~4 MB |

On the three real charts PP-OCRv6 small reads 112/130 exact with 2 false chords (LFM3 116 with 23, Private Cloud
Compute 125 with 4): junk comes back as words that fail the grammar, so it rejects junk like the cloud does. Its
losses are raised extensions and handwriting: 7 read as ? or 1 (AbMA?, D1), b9 as 69, 9sus as isus, dim7 as 07,
extensions dropped (Bm7b5 -> Bm). That is what fine-tuning on chord crops addresses. The grammar now accepts MA/MI
spellings and a parenthesised chord.

### Fine-tuned PP-OCRv6 small (November 2026)

Training set (`build_train.py --literal --cap 150`): 539 generated sheets (27 chord fonts incl. LilyJAZZ and other
handwriting-style fonts, labels read back from MuseScore) + the full anthology, 32,712 crops, junk 11%. Fine-tuned
on one rented RTX 4090 (RunPod, ~$0.50): 8 passes, lr 1e-4 cosine, ~14 min; best held-out 99.7% (pass 5). Paddle
trains on one CPU core on the Mac (~0.9 crops/s), so training needs a GPU.

| Reader on the finder's crops (768 chords) | Exact | Root | False chords |
| --- | --- | --- | --- |
| PP-OCRv6 small, untrained | 519 (68%) | 595 | 50 |
| PP-OCRv6 small, fine-tuned (full1) | 628 (82%) | 685 (89%) | 52 |
| LFM3-VL-2B (earlier) | 601 (78%) | 717 | 287 |

On the three real charts: fine-tuned 118/130, Private Cloud Compute 125. Lessons from the quick checks: canonical
labels on one font made the model forget spellings (worse); labels must be literal and capped per chord. Left to fix:
the junk label "~" leaks into minus signs (D-7 -> D~7), small-caps "MI"/"MA" (New Real Book) read as mj/m1, and
false chords rose on Real Book set 2 (26 -> 39).

Round 2 (full2): junk label changed to "■" (the old "~" looked like a minus and leaked into chords); generated
sheets gained accents/marcato/tenuto/staccato above notes (a row of ^ had been read as "A"), more stacked
alterations, fraction-style bass notes, slash chords and mi7/MI7/MA7 spellings, LilyJAZZ in the regular font mix,
extension raise limited to a realistic 0.8 sp; crops get per-character nudging (each glyph moved and tilted a
little). 740 sheets + anthology, 44,397 crops, cap 200 per chord. ~20 min on an RTX 4090.

| 768 test chords | Exact | Root | False chords |
| --- | --- | --- | --- |
| Untrained | 519 (68%) | 595 | 50 |
| Round 1 (full1) | 628 (82%) | 685 | 52 |
| Round 2 (full2) | 652 (85%) | 686 | 25 |

Private Cloud Compute on the same crops (two New Real Book pages it finished before its daily quota, 127 chords):
cloud 114, round 2 105, round 1 102, untrained 81. On the three real charts round 2 reads 118/130 with no false
chords (cloud 125, 4 false). The gap left is mostly the New Real Book's small-capital MI/MA, which MuseScore
cannot render.

### Swift finder (ScannerCore)

`ChordFinder.swift` is a rule-for-rule port of `find.py`, including Python's tie-breaking (stable sorts, first
minimum/maximum), scipy's raster-order component labels, numpy's linear percentile and round-half-to-even.
`Scanner.scan` runs it on copisteria's reading in memory and returns the words as `ScanResult.chordWords`
(~10 ms a page on a Mac). Parity with `find.py` (`finder_parity.py`): 344 pages, 26,021 proposals, all identical
(the 20 real test pages, 174 generated sheets in every style, 150 anthology pages); the in-scan run matches the
run from dumped files.

Round 3 (full3): small capitals without drawing (Copperplate and Bodoni 72 Smallcaps print lowercase quality letters
as small capitals after a full-size root, the New Real Book look; one batch of 67 sheets in only these two), more
book spellings (ma7, mi9, mi(b5)), uneven-light augmentation; 941 sheets + anthology, 55,193 crops.

| 768 test chords | Exact | Root | False chords |
| --- | --- | --- | --- |
| Round 2 (full2) | 652 | 686 | 25 |
| Round 3 (full3) | 651 | 704 | 30 |

On the two New Real Book pages Private Cloud Compute read (127 chords): cloud 114 exact / 120 root / 6 false;
round 3 114 / 118 / 5 (round 2: 105 / 109 / 5). A Sleepin' Bee 61 -> 68 of 77, equal to the cloud. Overall exact is
flat: Real Book set 2 dropped 190 -> 187 and its false chords rose 14 -> 18.

Round 4 (full4, Nov 16 2026), aimed at round 3's misreads (`NEXT_RUNPOD_RUN.md`): `gen.py --focus` (half the chords
from the misread spellings: madd9, aug, 6/9, 13, add9, 2, sus2(add9), min(omit3)...) and `--jazz` (the Jazz chord
style), and drawn triangles and circles: MuseScore reprints a typed "Δ7" as "maj7", so round 3 had never seen a
triangle; `<kind use-symbols="yes">` draws them. Four batches (MuseJazz + Jazz style, all fonts + Jazz style, focus,
handwriting fonts) on top of round 3's data: 1,995 pages, 73,501 crops (2,574 Δ, 518 ø). Trained on one rented H200,
round 3's settings. Scanned with `ScannerCheck --read-image` (the whole pipeline), round 3 vs round 4:

| Check | Round 3 | Round 4 |
| --- | --- | --- |
| Chord benchmark, 20 pages (exact / root / false) | 667 / 711 / 14 | 678 / 711 / 14 |
| - real (3 charts) | 118 / 124 / 1 | 115 / 121 / 3 |
| - Real Books (8 pages) | 354 / 378 / 1 | 362 / 377 / 2 |
| - Real Books 2 (9 pages) | 195 / 209 / 12 | 201 / 213 / 9 |
| MuseJazz hold-out, 30 sheets, 833 chords | 598 / 739 / 29 | 718 / 769 / 24 |
| `--sus` sheets: 2, add9, sus2(add9) right | 26, 32, 0 | 75, 85, 74 (every sus kind right, none missed) |
| `--other` sheets: madd9, aug, 6/9, m6/9 right | 3, 6, 4, 0 | 39, 41, 39, 39 |
| major/minor swaps (`--other`) | 16 (madd9 as major) | 0 |
| Major/minor sheets, 30 clean (1,202 chords) | all right | 1,191: a plain "M" read as "M7" 11 times of 60 |
| Lyrics 40 / slash 60 / part-name 40 pages | | 3,201 syllables, 1 false / 598 slash bars, 0 false / 120 + 120 names right |

On Jack's charts: Travelers' triangles read as major (AΔ13, G♭Δ7, BΔ7, EΔ7(♯5); F7sus(add3) found),
Roadside Distraction's BΔ(♯11) five times of six. New misreads, for round 5: plain "M" given a 7; in Real Book
handwriting a G7 read as Gø7 (3 times on Cheek to Cheek) and a ♯o7 as a triangle once. 13 and 13♯11 still come out
as plain major chords in a third of bars, as in round 3: not the reader (`REMAINING_ISSUES.md`).

### Finder: marks on notes and loosely set fonts (November 2026)

Two finder changes, in `find.py` and `ChordFinder.swift` alike:

- `attached_marks`: an accent, staccato, tenuto or fermata above the staff is erased when copisteria is confident
  (p >= 0.6), it is sized like a mark (a fermata wider than tall) and it sits centred over a note copisteria timed.
  Real ones measure p 0.9-0.99 centred over their note; chord letters copisteria misreads as marks are unsure and
  taller than wide (a handwritten C as a fermata at 0.51) and stay for the reader.
- `page_gap`: the letter spacing of a loosely set font (Real Book 3, "B m7 b5") is measured over every chord row on
  the page, not one line (a line rarely has the 8 gaps needed). It widens the word gap for the pieces inside a chord
  but not for a capital-height letter, because the next chord's root sits as close as the letters within one
  ("F m7 F#o7": 5 px either way).
- A lone capital also joins the word after it when that word's first glyph is level with it: a raised extension
  ("C 9(#11)") is higher as a whole word than its first glyph, and with the wider gap it becomes one word.

Round 3 reader (full3) on the finder's crops, the committed finder (47a7c79) -> now. Read one crop at a time (`ocr_bench.py --batch-size 1`):
PaddleOCR pads each batch to its widest crop, so the same crop can read differently when the crops around it
change. At the default batch of 16, removing junk crops changed 8 identical crops' readings and added 3 false chords
that had nothing to do with the finder.

| 768 test chords | Exact | Root | False chords | Crops |
| --- | --- | --- | --- | --- |
| 47a7c79 | 654 | 704 | 33 | 1,221 |
| Marks only | 657 | 707 | 33 | |
| Page spacing only | 658 | 704 | 33 | |
| Both (with the root join) | 661 | 707 | 33 | 1,187 |

At the default batch of 16: 651 / 704 / 29 -> 659 / 707 / 32.

Gains: Cmi7 and C7(#9#5) no longer merged with accents (nrb2-p105), Cmaj9 no longer pushed up by a fermata
(rb6-p370), B m7b5, Bb m7, A 7b9 and C# m7b5 whole (rb3-p42). No chord crop read worse. Eb 6/9 (stacked) is now
one box but reads "Eb9#" (before "Eb6" + "9": wrong either way). Anthology box truth unchanged (18,302 of 18,344
isolated; 2 fewer junk words). Generated sheets (16 batches, 24,152 chords): isolated 14,816 -> 14,856, beat right
14,620 -> 14,657, junk words 7,137 -> 5,201. One batch (b13) loses 6: chords in a real second chord row that only
counted as one before because junk accent words filled out the row (the second-row rule wants 3+ words across 2+
bars), and a marcato copisteria rates 0.55, under the cutoff. Python-Swift parity: 344 pages, 26,021 proposals, all
identical.

17 unseen pages (5 per book, less two photos and a text page): 968 -> 948 crops, 501 chord readings either way.
Every changed crop improved: F7#9 four times and GΔ7 on Real Book 3 pages are whole (were F7 + #9, G + Δ + 7), 12
fermata and accent crops are gone. No chord lost, no new false chord.

### On-device reader in ScannerCore (November 2026)

`export_onnx.py` exports the reader (round 3, now round 4) to ONNX (`chord_rec.onnx`, 21 MB, with `chord_rec_dict.txt`); paddle2onnx 2.1
cannot convert Paddle 3.3's `linear_v2`, so the export swaps it for the same matmul + add. `onnx_bench.py` reads crops
with it: identical text to the Paddle model on all 1,187 benchmark crops (read one at a time). `LocalChordReader`
(Swift) cuts crops as `export_crops.py` does (Pillow's Lanczos, bit for bit) and prepares the model input as PaddleX
does (OpenCV's fixed-point bilinear resize): `ScannerCheck --chord-read` and `--chord-read-pages` give the same text
as Python on every crop and every word of the 20 test pages (confidence differs slightly on about 1 crop in 50, junk
crops near OpenCV's ARM rounding; it is not used to accept chords).

| 768 test chords | Exact | Root | False chords |
| --- | --- | --- | --- |
| Benchmark grammar (`ocr_bench`/`score_reads.is_chord`) | 661 | 707 | 33 |
| The app's check (`ChordText.modelSymbols`) on the same crops | 672 | 717 | 20 |
| In the written MusicXML (`ScannerCheck --read-image`, `score_reads.py xml`) | 662 | 707 | 23 |

The score loses 7 chords on purpose: alternates in a second row over the line that fall on the main chord's beat
(both would play). Pages read offline in 3-4.5 s on a Mac (about 1 s of it chords); a page with a single
chord-like word is taken to print none (a piano photo read one "E"). Aria's engine imports the MusicXML with every
chord (21/21, 32/32, 47/47 on three pages), saved as format 4.70. `score_reads.py xml` now reads every part in page
order and spells a chord from kind@text when present (ScannerCore also writes alterations as degrees).

### Extended sus chords and chords sharing a beat (November 2026)

- MuseScore names an imported chord from its MusicXML kind and degrees (matched in order against its chord list),
  not from kind@text. ScannerCore wrote 9sus/13sus as suspended-fourth with only the extension, so Aria showed
  Bb9sus4 as Bbsus4add9 and Bb13sus as Bbsus4. Sus chords with a seventh now carry add7, then the extension, then
  their alterations as added degrees, as MuseScore's chords.xml spells them.
- Two chords never share a beat: a bass written below and right of its chord joins it ("D-7" + "C" -> D-/C); a bare
  letter on another chord's beat that is the line's first word (an unboxed rehearsal letter), sits inside the chord's
  box, or is off its baseline is left out; other chords on one beat are spread in printed order to the nearest whole
  beat (rb3-p42: B7#11 Bb7 A7 Ab7 in order, beast: C#- on 4).
- `score_reads.py` treats sus and sus4 as the same chord.

20 test pages (768 chords), on the Mac (ScannerCheck --read-image) and in Aria on the iPhone simulator (saved .mscz):

| | Exact | Root | False | Same-beat collisions |
| --- | --- | --- | --- | --- |
| ScannerCore MusicXML, before | 662 | 707 | 23 | 17 |
| ScannerCore MusicXML, after | 666 | 710 | 14 | 0 |
| Aria saved score, before | 644 | 707 | 23 | 17 |
| Aria saved score, after | 668 | 710 | 14 | 0 |

### On-device score text (November 2026)

`LocalTextReader` reads the page's other text with the standard PP-OCRv6 small recogniser (`text_rec.onnx`, exported
by `export_onnx.py` from the released weights; identical readings to PaddleOCR's own model on 198 benchmark crops).
`text_fixtures.py` renders six focused one-page lead sheets; all six read correctly (title, composer, rehearsal A
and B, To Coda / D.S. al Coda / Coda / Fine / D.C. al Fine / D.S. al Fine in their measures, and the tempo:
6/8 "= 92" -> dotted quarter, 2/2 "Bright = 120" -> half with "Bright", 4/4 "Medium Swing = 100" -> quarter,
printed dotted quarter = 60, half = 80, and quarter = 120 in 6/8 kept as printed).

On the 20 test pages (no answer key; judged by eye): title right on 13 of the 18 pages that print one (Real Book 6
handwriting is the weak spot: "TUMP MONK", "2) SOMETIME"), no title invented on the 2 continuation pages,
composer right or nearly on 14, tempo/style wording on 8 (one cut short: "Med. S"; "Med. Up Swing", "Medium Waltz", "Ballad", "SLOWLY"), a
metronome mark on 2, 31 staff text items (rehearsal letters, "Fine", "D.S.", "Till cue", "(play lower notes on repeat
only)", a few misreads). Chord results unchanged (666 exact / 710 root / 14 false, 0 collisions).

### Playback jumps (November 2026)

Printed D.S./D.C. (al Coda, al Fine), To Coda, Fine and the segno and coda signs get the standard MusicXML `<sound>`
attributes when their targets are unambiguous (otherwise they stay words). Checked by `ScannerCheck --add-jumps`
on four eight-bar fixtures, imported and saved by Aria's engine (with the #33802 import fix) and played by desktop
MuseScore 4.7.6: D.S. al Coda plays 1 2 3 4 5 6 2 3 4 7 8, D.C. al Fine 1-8 then 1-4; two segnos, or no segno,
play straight through.
