# Remaining scan issues, by the fix they need

Everything known to still go wrong in scans, sorted by what it takes to fix: code that looks at the page (no
model change), retraining the chord reader on RunPod (`NEXT_RUNPOD_RUN.md`), retraining another model, or a call
Jack has to make first. Each entry says where it was seen and what goes wrong for the user. Updated Nov 16 2026
(ScannerCore 0.1.12).

Rules for adding fixes (Jack): fix general causes, judged on the whole test set, never one chart; ask before a fix
that looks specific to one chart; show regression numbers, and say which checks were not run.

## 1. Code: computer vision and rules (no model change)

| Issue | Seen in | Effect | Fix needed |
| --- | --- | --- | --- |
| Chords between the two staves of one system (melody over bass) dropped as "lyrics of the line above" | Roadside Distraction p. 2 (F, B♭, D♭, E♭ lost in 5 bars) | chords missing | Chord finder: its "text hangs below the line above" rule is meant for lyrics under the previous system; within one system, pass the words to the reader (lyrics do not parse as chords). Measure on piano-vocal pages, where lyrics do sit between staves. |
| A melody note high above the staff (with its accidental) looks like a second chord stacked under the real one, which is then dropped as "stacked" | Nacirema (E♭Δ9(♯11)/G♯, twice) | chord missing | Chord finder: clear accidentals and notes the detector placed on the staff before stacking words. Kept in step with `find.py`. |
| A chord printed across a bar line, centre just left of it, goes to the end of the earlier bar | Peaceful Warrior (B/F♯ bar 34 for 35) | chord a beat early | Needs a decision: ~130 such chords on real pages, no answer key for their bars. Jack to decide before any rule. |
| Short bars filled with an invisible gap, which MuseScore shows as hidden rests | Jack's list | hidden rests | Writer: fill with real rests of plain values (a quarter + a sixteenth); keep the gap only where no plain rest fits. Playback unchanged. Agreed in principle, not built. |
| A missed bar line merges two bars into one | slash pages, synthetic sets (6 of 38 clean pages) | bar count off, endings and slashes wrong | Layout: find bar lines the detector missed (there is a pass for this; why these slip through is not yet looked at). |
| A multi-bar rest ("8" over a long rest) becomes one bar | Peaceful Warrior "Piano Interlude 8" | every later bar numbered wrong | Writer: read the number over a multi-rest and write that many bars. |
| Stemmed and half-note rhythm slashes stay notes | Secrets of the Stars bars 14, 42; Real Book bars with 6 slashes | wrong notes | Extend the slash finder to stems and hollow slashes; same aggregate checks as stemless slashes. |
| Small rhythm cues above the staff written as notes | Secrets of the Stars bars 43, 47 | extra notes | Writer or finder: notes far above the staff, smaller than the staff's noteheads, as cues. Not looked at. |
| Instruction sentences under notes read as lyrics | 4 of 37 Real Book pages | false lyrics | Lyric filter; text alone cannot tell them from lyrics. Possibly a "lyric line spans the system" test. |
| Lyrics on piano-vocal pages and on rough photos weaker | Jack's "Country Roads"; rough synthetic 73% vs clean 94% | missing and garbled syllables | Lyric finder band on piano-vocal pages; photo robustness. |
| Bass-only slash chords ("/A") read as A | Peaceful Warrior, Travelers | wrong root | Deferred by Jack. A slash-stroke check on the page was prototyped and removed. |

## 2. Chord reader retraining (RunPod)

The reader model itself misreads these; no text rule can repair them without guessing (e.g. "o7" is a real
diminished seventh). Data, hold-out sets and pass bars are in `NEXT_RUNPOD_RUN.md`.

| Issue | Seen in | Effect |
| --- | --- | --- |
| Plain "M" triad given a 7 (E♭M → EbM7) — new in round 4 | major/minor synthetic sheets (11 of 60) | wrong chord (major seventh) |
| Real Book handwritten G7 read as Gø7; ♯o7 read as a triangle — new in round 4 | Cheek to Cheek | wrong chord |
| min(omit3) garbled | Peaceful Warrior | wrong chord |

Fixed by round 4 (0.1.12): the MuseJazz triangle read as "o" or dropped, MuseJazz chords missed, madd9 as ma9, aug
as aug7, stacked 6/9 and m6/9, add9/add2/2 losing their number, sus2(add9). Numbers in the README ("Round 4").

13 and 13♯11 still come out as plain major chords in a third of bars (`--other` sheets, e.g. E♭13 bar 1 of sev019,
printed full size): the same with round 3 and 4, so it is not the reader. To look at in the finder or the writer,
with the crops drawn over the page.

## 3. Other models

| Issue | Seen in | Effect | Model |
| --- | --- | --- | --- |
| Handwritten "9/4" read as 4/4 (detector) and 6/4 (reader) | Peaceful Warrior bars 102-105 | wrong meter | copisteria detector and evidence reader |
| Time signature plus the first note's flat read as a key signature (a repeat bracket between clef and meter) | Travelers bass, bars 1-26 | wrong key, every A and E flat | copisteria detector |
| No slash or rhythm-slash class (handled in code for stemless slashes only) | all slash charts | see section 1 | copisteria detector (long term) |
| Boxed rehearsal letters in a handwriting font misread ("D" → "0") | Roadside Distraction | wrong rehearsal mark | text model (`text_rec.onnx`), a fine-tune of its own |
| Rehearsal letters H-L not found | Peaceful Warrior | rehearsal marks missing | partly the finder's box test, partly the text model |

copisteria retraining is a larger job than the chord reader (detector and evidence models, its own training data);
collect cases here until it is worth it.

## 4. Jack's call before any change

| Question | Context |
| --- | --- |
| Does a bare "CΔ" mean Cmaj7 or C? | Now C, as the benchmark key reads it; many jazz books mean Cmaj7. One line to change. |
| Should part labels other than instrument names ("MELODY", "Lead") name the part? | Widening the rule risks tempo words at the top left ("Medium Swing"). A short list of label words (melody, lead, vocal, voice) is the safe middle. |
| What sound for a lone "Bass" part? | Today no instrument is written and MuseScore names it a bass voice. Bass clef suggests double bass or bass guitar. |
| Drop chords the grammar accepts only loosely ("F♯min(mi73)") instead of writing them garbled? | Small general rule; would also drop some real unusual chords. |
| Chords across bar lines (section 1) | see above |

## Fixed recently (for reference)

0.1.6-0.1.11: octave-clef misreads, italic chords as "pp", part names and instruments, slash bars (stemless),
1st/2nd endings, lyrics, DM as D major, sus2, madd9, 7+, +maj7, maj7sus, add♯11, triplet "3" as a chord, keys
changing only where printed, jazz-font triangle read as "a", boxed rehearsal letters, unreadable chords kept out of
staff text, top-left instrument label as part name.
