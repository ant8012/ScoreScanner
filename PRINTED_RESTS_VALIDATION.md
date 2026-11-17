# Printed scanner rests

The scanner now prints ordinary silent gaps as black rests. Pitched notes, their timing, lyrics,
chords and bar lengths are preserved. Tuplet filler rests remain hidden. Pickup and short measures
keep their existing length.

## Implementation

`ScoreGapRestsMusicXML` runs at the end of `ScoreValidityMusicXML.repaired`, the common endpoint
used by image scans, the Copista engine, merged PDFs and the final ScoreReader cleanup. Running
before the guard was insufficient: the guard itself can create hidden padding and finish spelling
tuplet fillers. The throwing `ScoreValidityMusicXML.apply` retains its original contract.

The pass tracks the MusicXML cursor and occupancy per staff and voice. It converts ordinary
forwards and hidden rests into exactly representable standard values, respecting meter beats and
aligned subdivisions. Empty full measures receive a measure rest. Anonymous adjacent hidden
padding can be combined before spelling; recognized visible rests are left alone. Longer aligned
plain values prevent an already malformed, extremely long source bar from acquiring hundreds of
quarter-rest glyphs. Cursor moves over existing music and nonstandard durations remain forwards.
Forwards following an outgoing tie also remain cursor moves: MuseScore can sustain a tied note
across that time, even into another voice. Inserting a rest would break the sustain, so those spans
are not treated as ordinary silent gaps.

`Copista.Tidy.hide` handles impossible pitches outside the supported piano range by retaining
their silent duration as hidden rests. Its filtering behavior is unchanged; those ordinary silent
durations now print. Hidden rests with time-modification are excluded from the new pass.

## Validation

- 20 new unit tests cover missing beats, short tails, pickup lengths, empty measures, second voices,
  main-voice inference on the lower staff, tuplet fillers, Tidy filtering, PDF padding, beat splitting,
  unspellable durations, structural cursor movement, compound meter, idempotence and final guard
  padding and sustained ties. All 20 passed on the final source.
- The full 156-test suite had one failure in the previously known flaky
  `ModelRequestTests.higherPriorityWaiterGetsTheNextSlot`. The subsequent run of all 11
  ModelRequestTests passed. The rest changes did not require a repeated full unit suite.
- First full recognition regression: 749 inputs, 720 outputs, the same 29 missing outputs as the
  baseline at `30832b1`. This found the need to move rest printing after validity repair.
- Second full recognition regression: **749 inputs, 720 outputs, the same 29 unsuccessful inputs**,
  ten concurrent jobs, 2,069 seconds. Zero note, timing, bar-length, chord, text or lyric differences.
  Completed inputs were not restarted after the conversation interruption.
- Final engraving refinements were applied with the actual production Swift formatter to all 720
  saved baseline scores. This avoids a third recognition run. The validity guard subsequently
  returned every formatted score unchanged. Final rest spelling was also compared with the second
  recognition run: note timing, lengths and metadata remained identical. These last engraving and
  tie-preservation refinements were validated by replaying saved XML, not by another model scan.

Final formatter comparison against all 720 baseline outputs:

| Check | Baseline | Final |
| --- | ---: | ---: |
| Pitched notes | 74,273 | 74,273 |
| Part measures | 18,999 | 18,999 |
| Visible rests | 5,175 | 6,775 |
| Ordinary hidden rests | 385 | 0 |
| Hidden tuplet filler rests | 62 | 62 |
| Forwards | 881 | 68 |
| Measures containing forwards or ordinary hidden rests | 818 | 34 |

320 files changed. There were zero missing or extra files and zero differences in per-staff,
measure and pitch counts; pitched-note onset/duration/voice/chord status; bar reach and pickup
flags; harmony/direction content and position; or lyric content, attachment and position.
`textcmp.py` found zero changed files. Real Book accuracy stayed at 678/768 exact, 711/768 root,
13 false chords. Lyrics40 stayed at 3,341 correct of 3,370 read against 3,406 expected.

The 68 remaining forwards comprise 51 cursor moves over existing music, 11 durations that
cannot be represented by the allowed standard rest values, and six forwards following outgoing
ties. They intentionally retain their timing and playback.

### MuseScore and playback

All **720 scores imported and exported normally, zero refused**. The supplied per-file
`opencheck.py` stalled in MuseScore's macOS shutdown/event loop after export. Instead, the same
normal importer was exercised through MuseScore's `-j` batch converter, without `-f`; all outputs
were produced and the process exited 0. The final tie guard changed only five of these files, so
only those five imports/exports were repeated; that batch also exited 0. An optional MuseSampler
background query also hung, so the check commands used a nonexistent `MUSESAMPLER_PATH` to
disable that optional audio engine for those commands only. App settings were not changed.

Playback was checked from exported MIDI for all 320 changed scores, reusing 319 saved baseline
exports. Notes, note-off timing, channels, velocities, tempo, controllers, programs and score end
time were compared. The tie guard fixes the genuine sustain regression found in Cowen's
*The Better Land* p4. All five scores affected by that guard now match baseline MIDI exactly.

318 of 320 changed scores match raw playback events exactly. The other two are explained:

- Viardot *Lamento* p7: MuseScore itself produces either velocity 96 or 112 for one note in the
  unchanged baseline. Five baseline and five candidate exports produced the same two complete
  playback outcomes, including controller curves. This is baseline exporter nondeterminism,
  rather than evidence of a rest-induced dynamics change.
- `Chopin_Test`: all note/tempo events and lengths match. The candidate adds 119 controller
  messages at 79 distinct times, all repeating the controller's existing value (CC2 = 3). They do
  not change controller state or sounding playback. The first description of these as occurring
  entirely during silence was too broad; some notes still sound during the repeated values.

Four final rendered pages were visually inspected: *Aggravatin' Papa* (missing beat, bar 9),
*Ah! Sweet Mystery of Life* (short tail, bar 11), *Alexander's Ragtime Band* (final half rest),
and Brahms *Eine gute, gute Nacht* p1 (whole-measure rests on an empty staff). Rests print black,
and the sample note and lyric layouts remain intact.

The final `ScannerCheck` release build passed using
`swift build -c release --product ScannerCheck --scratch-path tools/chordfind/data/tools/swiftbuild`.
The final focused rest test run passed all 20 tests. `git diff --check` passed.

## Limits and delivery

The phone/Aria visual check could not be performed: iPhone Mirroring access was unavailable.
No app was built or installed on the physical phone, and no scan was transferred to it.
No commit, push, version tag or Aria package update was performed.

Temporary evidence is under `$TMPDIR/printed-rests-final-regression/` (second recognition run),
`$TMPDIR/printed-rests-standalone/` (final formatter, comparisons and images; final XML is in
`complete/`, with `complete-gap-report.json` and `complete-text-report.json`), and
`$TMPDIR/printed-rests-*.log` (build and unit logs). These are local scratch artifacts, not committed
score material.
