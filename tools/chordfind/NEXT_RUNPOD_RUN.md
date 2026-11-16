# Next RunPod run: chord reader round 5

**Round 4 is done** (Nov 16 2026, shipped in ScannerCore 0.1.12): the plan below was carried out (`gen.py --focus
--jazz`, drawn triangles and circles via `use-symbols`, handwriting batch), and the results are in the README
("Round 4"). It fixed nearly everything in the table below. What round 5 should fix, all new or left over:

| Printed | Read (round 4) | Seen in | Data to add |
| --- | --- | --- | --- |
| plain "M" triad (E♭M) | `EbM7` (11 of 60) | `gen_sevenths.py` major/minor sheets | many plain M and M6 next to M7 and Δ7, in every font, so the 7 is never assumed |
| Real Book handwritten G7 | `Gø7` (3 on Cheek to Cheek) | benchmark "real" set | handwriting-font dominant sevenths, with ø drawn only where printed; ø in typeset fonts too |
| handwritten D♯o7 | `D#maj7` (triangle) | Cheek to Cheek | small circles and triangles side by side in handwriting fonts |
| MuseJazz garbles: `BΔ#117`, `Gbmaj13#57` | Roadside Distraction, Travelers | more superscript (♯11), (♯5) after Δ13 in MuseJazz |
| min(omit3) | `min(mi73)` | Peaceful Warrior | still unread; tiny superscript text |

Accept round 5 with the same checks as round 4 (README table): nothing lower than round 4 per set, and the
major/minor sheets all right again.

Round 4's plan, kept for reference:

See `REMAINING_ISSUES.md` for everything else that still goes wrong and what each needs; this file is only the
chord reader's part.

What the next fine-tune of the on-device chord reader (`chord_rec.onnx`, PP-OCRv6 small, round 3) should fix, how
to build its data, and how to accept it. Collected Nov 15-16 2026 from real charts (Aaron Parks lead sheets in
MuseScore's MuseJazz font, Nacirema People, Love Song, What a Wonderful World, the Real Books) and the synthetic
spelling sheets in `tools/eval/gen_sevenths.py`. Training itself works as in round 3 (README, "Fine-tuned
PP-OCRv6 small"): `build_train.py` data, `train_chords.sh` on one rented RTX 4090, `export_onnx.py`.

Only the reader is retrained. The chord finder, grammar and writer stay as they are; their own bugs (sus2, madd9,
triangle read as "a", boxed letters...) were fixed in code in 0.1.10 and 0.1.11.

## What the reader gets wrong

Measured with `gen_sevenths.py --sus` / `--other` (20 pages each, MuseScore's default chord font) and on real
charts. "Read" is what the model returned.

| Printed | Read | Effect | Where seen |
| --- | --- | --- | --- |
| Δ as a small superscript (MuseJazz: Gb△7, B△7) | `Gbo7`, `Bo7` | **wrong chord** (diminished) | Travelers |
| Δ13, Δ7(#5), Δ13(#5), Δ(#11) (MuseJazz superscript) | `A13`, `E7(#5)`, `B(#11)` | wrong chord (major read as dominant / no seventh) | Travelers, Roadside Distraction |
| E△7, D♭△7, G♭△13(#5), F7sus(add3), C#min7(b6) | nothing | chord missing | Travelers |
| madd9 | `ma9` | **wrong chord** (minor read as major ninth) | 16 of 40 on synthetic sheets |
| aug | `aug7` | wrong chord (a 7 added) | 31 of 41 |
| 6/9 and m6/9 stacked (⁶₉) | `6`, `m6` | 9 lost | 33 of 39, 39 of 40 |
| 13, add9, 2 (add2), 13#11 | number lost (`C`, `Cadd`) | 13 and add9 lost in a third to two thirds of bars | synthetic |
| min(omit3) (tiny superscript) | `min(mi73)` | garbled | Peaceful Warrior |
| cursive sus2 (Real Book font) | `amj7`, `ama7` | chord missing | Love Song |
| tuplet "3" over a beam | `B` | false chord | fixed in code (0.1.10); keep 3s as junk in training |

Things the reader already does well and must keep: plain triads and sevenths in every spelling (M7, maj7, MA7, Δ7,
m7, mi7, MI7, -7, ø, o7, dim7, +, aug7, 7♯5, 7♭9, 7♯9, sus, sus4, sus2, 7sus4, 9sus4), slash basses, small-caps
minor ("AM" in What a Wonderful World read as Am), and junk ("■") on non-chord crops.

## Training data to add

1. **MuseJazz superscripts, weighted up.** MuseJazz Text is already one of the 27 fonts, chosen at random. Add a
   batch of sheets (~150) in MuseJazz only, with the Jazz chord style (superscript extensions, small triangle and
   circle), heavy on Δ, Δ7, Δ9, Δ13, Δ7(♯5), Δ13(♯5), Δ7(♯11), m7♭5/ø, o7, sus(add3), min(omit3), min7(♭6). The
   triangle and the diminished circle must both appear often so the model learns to tell them apart.
2. **The spellings it drops or invents.** In every batch: madd9 (and mi(add9), -add9), add9, add2 and plain 2,
   aug alone (never with a 7), 13, 13♯11, 9sus4, sus2(add9). `gen_sevenths.py --sus` / `--other` already print
   these; `build_train.py` should read their sheets too (labels from the MusicXML text, as for `gen.py`).
3. **Stacked 6/9.** MuseScore prints 6/9 stacked (⁶₉) in its default chord style. Include them, labelled "69", in
   several fonts; check the finder's word box holds both digits (if it cuts the 9 off, that is a finder fix first).
4. **Handwritten sus.** Real Book-style fonts (lilyjazz, Marker Felt, Bradley Hand) with sus2, sus4, 7sus4 and
   sus2 after a flat root (B♭sus2), where round 3 read `amj7`.
5. **Junk to stay junk:** tuplet numbers (3, 5, 4:3) over beams, boxed rehearsal letters, "(open)", "(as
   written)", bar numbers, all labelled "■".

Keep everything round 3 had (941 sheets + anthology, small-caps batch, uneven-light augmentation) so nothing is
unlearned. A rough size: round 3's 55k crops plus ~15k new.

## Before training: hold-out sets

Make the acceptance sets first, with seeds the training data never uses:

- `gen_sevenths.py` major/minor, `--sus`, `--other`: 30 / 20 / 20 pages, clean and rough.
- 10 MuseJazz sheets with the Jazz chord style (the font of the Aaron Parks charts), from `gen_sevenths.py` once it
  takes a font option.

## Accepting the model

Scan with the new `chord_rec.onnx` (ScannerCheck `--read-image`), a few scans at a time.

| Check | Round 3 (now) | Round 4 must |
| --- | --- | --- |
| Chord benchmark, 20 pages (`score_reads.py`) | 667 exact / 711 root / 14 false | not lower exact or root; false ≤ 14 |
| Major/minor sheets, clean (1,203 chords) | all right, 0 major/minor swaps | same |
| `--sus` sheets: sus2, 7sus2, add9, 2 | sus2 86%, add9 36%, 2 35% | add9 and 2 ≥ 80%, the rest not lower |
| `--other` sheets: madd9, aug, 6/9, m6/9, 13 | 8%, 15%, 10%, 0%, 60% | each ≥ 80%; no madd9 read as major |
| MuseJazz hold-out | not measured | Δ never read as o; Δ chords ≥ 80% right |
| Lyrics, slash, part-name sets | 3,201 / 420 / 240 | unchanged (the chord model does not touch them, but check) |
| Real charts (Jack's, local only): Travelers, Peaceful Warrior, Nacirema, Love Song | see table above | fewer missing and wrong chords; no new false chords |

Round 3's lesson: overall exact stayed flat while one Real Book set dropped a little. Look at the per-set numbers,
not just the total, and keep round 3's ONNX until round 4 passes.

## After it passes

`export_onnx.py` → replace `Sources/ScannerCore/Resources/Models/chord_rec.onnx` (and `chord_rec_dict.txt` if the
character set changed), rerun every check above with the Swift scanner, note the numbers in this folder's README,
then a tagged ScannerCore release for Aria.
