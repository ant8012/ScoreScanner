# Working on ScoreScanner

> **Handoff, November 21, 2026 (night):** the latest public ScannerCore is **0.1.26** (`28b7315`, tagged and pushed Nov 21). Aria pins it on iOS and Android in Aria `3d4a8bbe00` (pushed Nov 21, on top of Aria's `af056d89bc` engine move to MuseScore 4.7.7). What 0.1.26 holds: `752bf4c` straightens curled phone photos strip by strip (pages past 1 degree whose tilt varies 3+ degrees; flat scans untouched), `bb5f4cd` reads chord names standing on guitar chord diagrams, and `d7c3764` (from the app session, Nov 21) records where each measure is printed (`ScoreBar`, see "How a page is read"; additive API, scores read byte-identical on six test scores, so no regression rerun was needed for it). Both passed the full regression (843 + 857 identical, every change a phone photo checked against the printed bars). **Committed Nov 21 (`28b7315`)** in `CopistaFront.swift` and `CopistaWriter.swift`, from the songbook photo "Morning Has Broken": (1) a staff traced from the page edge (show-through or shadow) looks for its opening line up to its first clef; (2) two staves with no opening line and at most 1 bar line in 4 crossing the gap are two systems (`inkSplitBars` 0.3); (3) a note's written value follows the length bar-fit gave it (a missed dot); (4) dropped Nov 21: giving a part that joins after the first system its own key, clef and meter in bar 1 broke the Matrix both ways tried (4 overfull bars with its own meter; MuseScore refused the file with the score's opening meter), and switching each fix off in turn showed it alone was the cause. Without it the Matrix is musically identical to 0.1.24 and Morning Has Broken still reads 33 of 33 bars; the late voice part again opens with no meter (MuseScore assumes 4/4). Also in that commit: (5) slurs ending on a grace note with no note after it in its bar (cue notes read as graces) are dropped (`dropDanglingGraceSlurs`): they crashed MuseScore and Aria on open (BandMusic flute part "Singin' in the Bathtub", now `multipart/bathtub`); 3 Real Book pages lose 1-2 slur marks. Full run of 1-3 (Nov 21): 857 scores + the same 37 with none; against the committed code only 4 bars differ, all rests in a second voice (Merry-Go-Round b24, Chopin b35, rb3-p25 b14, Just the Way You Are P16 b7/b9), and every changed score opens in MuseScore. Next: rebuild Aria for Jack's iPhone (its current build, from an older uncommitted tree, has the Matrix bug and the slur crash); Aria's 7.7.0 (17) and 1.4.0 (28) binaries predate 0.1.26: build again before shipping. Build note: `download.onnxruntime.ai` served a certificate for the wrong host on Nov 20-21; the phone build used a scratch copy of the package pointing at the checksum-verified framework in `.build/artifacts` (scratch only, never committed). The Mac's disk is nearly full (~5 GB free): clean scratch build folders after use. Songbook status and leftovers: `tools/chordfind/REMAINING_ISSUES.md`.

> Handoff, November 20, 2026: the latest public ScannerCore is **0.1.25**: a voice staff no longer splits off from its piano where lyric lines widen the gap on a tight-cropped or curled photo (piano-vocal-guitar songbook pages; their chord grids are the next gap, see `tools/chordfind/REMAINING_ISSUES.md`). 0.1.24 (commit `c474e96`): a hymn's verses stacked deeper than nine staff spaces are read, staff text repeating a lyric line is dropped, "D7/4" reads as D7sus4. Aria's `main` pins 0.1.24 on iOS and Android (Aria `bf94df5b90`, pushed); bump it to 0.1.25 the same way. Aria's validated iOS 7.7.0 (17) and Android 1.4.0 (28) builds still contain 0.1.23: build again before submitting (nothing is submitted). **Repository split, Nov 20:** the standalone ScoreScanner app moved to the private `hdi200/ScoreScannerApp` (checked out at `../ScoreScannerApp`, which builds against this folder), and this repository's history was rewritten without it. Every tag 0.1.0-0.1.24 holds the same ScannerCore source under a new commit ID (0.1.23 was `d14c2a2`, now `d22855b`); old IDs are dead. `~/Developer/ScoreScanner-old` is the pre-split checkout, kept as a backup: never commit or push from it. The app's GPL musicxml-player is replaced by its own Verovio + SpessaSynth player (ScoreScannerApp `27372d0`, pushed); see the app's `HANDOFF.md`. Still to check on a phone: the hymn on 0.1.24, the Matrix (memory and time), Lady (drums, transposed parts by ear), and Android runtime. 0.1.20-0.1.23 (Nov 18-19): large orchestral scores and photocopies; hyphenated syllables, page turns without courtesy clefs, a crash at the page's foot; transposition from key signatures; clefs change only where printed; pages joined to the latest page laid out alike; instrument names found as whole words. What is still open: `tools/chordfind/REMAINING_ISSUES.md` ("Nov 19 stuff" first). How changes were checked, with a 0.1.24 baseline, the affected subset before any full rerun, and a runner capped at 10 scans (its old cap never worked and crashed the Mac): `tools/writercheck/regression-kit/README.md` (local only). Test material to collect next, and the outside sources audited with links and limits (BandMusic PDF, CPDL, IMSLP, CPMS; Jack downloads by hand, none may be scraped, CPDL never for training): `tools/writercheck/TEST_DATA_SOURCES.md` (local only). Aria uses the bundled on-device copisteria/PaddleOCR readers, not Apple's model. The Private Cloud Compute rule below applies only when explicitly exercising the legacy `.appleModel` route; it must not replace Aria's local readers. Package minimum remains iOS 16, while Aria's app target is iOS 17. Older `HANDOFF_TUPLETS.md` and `ANDROID_4GB_SCANNER_HANDOFF.md` (local only) carry follow-up banners. For Aria binaries, device results, screenshots and store state, see the local Aria `HANDOFF-SCAN.md` and `promo/scan-import/RELEASE_STATUS.md`.

Start here if you are new to this repo, or an agent opening it for the first time. `README.md` covers using the
package. This file covers changing it.

## What ships where

| Product | Built from | Who uses it |
| --- | --- | --- |
| **ScannerCore** (Swift package library) | `Package.swift`, `Sources/ScannerCore/` | ScoreScanner, and Aria (`hdi200/aria`, `MuseReaderiOS`) by GitHub URL + version tag |
| **ScoreScanner** (iOS app) | The private `ScoreScannerApp` repository, checked out beside this one (uses the package from `../ScoreScanner`) | Not released; the test bench for scans on the phone |
| **ScannerCheck** (Mac command line) | `Sources/ScannerCheck/` | Checking reads on the Mac |

The reader is changed **only here**. Older copies exist in `~/Downloads/homr/iPhoneScanner` (a clone of
liebharc/homr, AGPL; homr itself is no longer used) and are not the source of truth.

## How a page is read

`ScoreReader.read(image:|pdf:, options:, progress:)` (`AppleModel/ScoreReader.swift`) is the one entry point both
apps call. In order:

1. **Notes, on the device.** `Scanner.scan` (`Scanner.swift`) runs copista-2m, a Swift port of KobiMusic's
   copisteria, through ONNX Runtime (`Copista/`):
   - `CopistaFront`, `CopistaImage`, `CopistaTensors`: page image to model inputs.
   - `CopistaDetector`, `CopistaEngine`: the three ONNX models in `Resources/Models/`.
   - `CopistaReader`: detections to staffs, systems, bars and voices.
   - `CopistaWriter`: MusicXML. `CopistaTidy`: drops impossible notes, caps voices (untouched bars stay identical).
   - `ScoreGapRestsMusicXML` gives ordinary silent forwards/hidden padding printed rests at the end of the
     validity guard (including padding the guard creates). It preserves cursor timing, skips forwards over existing music, and keeps tuplet fillers hidden.
   - PDFs: `PDFScanner` renders pages at 2480 px and `CopistaMerge` joins them.
   - Where each measure is printed (`ScoreBars.swift`): `ScoreBar`s on `ScanResult.bars` and
     `DocumentScanResult.bars` (so `reading.score.bars`), from the writer's `placedStaves`, numbered by the page
     score's system breaks and offset page by page when joined. `Copista.straightenedWithMap` maps the straightened
     page back to the original (straightening only moves pixels within their column), so the corners sit on the
     photo as printed. A page whose layout and score disagree on a line's bar count places none. Any pass that
     rebuilds a `ScanResult` or `DocumentScanResult` must carry `bars` along. ScannerCheck `--read-image` and
     `--read-pdf` write them to `OUT.bars.json`.
2. **Chord names, on the device** (`chordReader: .onDevice`, the default). `ChordFinder` (a port of
   `tools/chordfind/find.py`, kept identical by `finder_parity.py`) finds each word above the staves with its bar and
   beat. `LocalChordReader` cuts it as `export_crops.py` does and reads it with the round 4 PP-OCRv6 small model
   (`chord_rec.onnx`, from `export_onnx.py`). `ChordText` judges the reading, and `ChordMusicXML` writes it as
   `<harmony>` at the finder's measure and beat. A page with a single chord-like word is taken to print none.
   With `chordReader: .appleModel` the old route runs instead: `ChordBands`, `ChordPresence` and `ChordImageCrops`
   cut one strip per bar and `AppleChordReader` asks Apple's model.
3. **Page text, on the device** (`textReader: .onDevice`, the default), with `readStaffText`. `LocalTextReader`
   reads with the standard PP-OCRv6 small model (`text_rec.onnx`): the header lines over the first system (title,
   composer, tempo), the finder's words that are not chords (joined into phrases; boxed ones are rehearsal marks), the
   letters the chord pass set aside at a line's start (unboxed rehearsal letters), and navigation under the last
   staff. Navigation is spelled as MuseScore's import matches it (D.S. al Coda, To Coda, Fine). A metronome number
   takes its beat from the printed note (half, quarter, dotted) when there is one, else from the meter (6/8 dotted
   quarter, 2/2 half). `ScoreMetadataMusicXML` writes it all in. With `textReader: .appleModel`,
   `ScoreTextImageCrops` and `AppleScoreTextReader` read it on Private Cloud Compute instead.
4. **Checks.** `ScoreTimeSignatureMusicXML` gives an overfull bar a time signature of its own length with
   "check bar" above it, so MuseScore (and Aria) open the file.

`ModelRequests` / `AppleModelRequests` run the cloud requests side by side and handle throttling. `RuntimePolicy`
sets memory and thread limits.

## Rules

- **Private Cloud Compute only.** Never read with the on-device Apple model, not even as a fallback. A failed
  cloud request means "no reading", not a retry on the device. `allowOnDeviceFallback` stays `false`.
- **Test only with the designated test scores.** Never scan sheet music found elsewhere on Jack's Mac, and never
  commit a score Jack owns. Test files live on his iPhone in ScoreScanner's `Documents/TestScores/`:
  - `HarbourLights.jpg` (also `.pdf`): a 16-bar lead sheet. Expect 22/22 chords, title "Harbour Lights",
    composer "Test Composer", part "Melody", 59 notes.
  - `Li_Brahms_2_Die_Mainacht.pdf` (also `-p1`, `-p2`): OpenScore, 4 pages. Expect 1,086 notes, 102 bars,
    "Die Mainacht", Johannes Brahms, parts Voice and Piano.
  - The app's `App/SampleAssets/sample.jpg`, used by `--scan-sample`: local only, not in git.
- **Look at the images before diagnosing a vision bug.** Draw the crops or detections over the page and look at
  them before reasoning from recognised strings or numbers. Prefer the simplest change before adding a stage.
- **Keep the package's iOS 16 minimum** (Aria's). FoundationModels code stays inside
  `#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)` and is marked available from iOS 27.
- **Don't change the public API casually.** `ScoreReader`, `ScoreReadOptions` and `ScoreReading` are used by Aria.
  A breaking change needs a minor version bump and a matching Aria change. An addition (a new property with a
  default, like `bars` on Nov 21) needs neither.

## Build and test

```sh
swift build
swift test                                  # ScannerCore tests (55)
```

### Scanning on the phone

Scans on the phone run through the ScoreScanner app (a separate private repository, `../ScoreScannerApp` on Jack's Mac). Its `README.md` covers building it (arm64 only, through the
shell), the launch arguments for unattended scans (`--scan-file`, `--scan-pdf`, `--scan-sample`) and where each
scan's MusicXML and reports land. Run **one scan at a time**: overlapping launches get cut off and their reports
land under the wrong scan. On the Mac, `ScannerCheck` (see `README.md`) reads pages without the app.

### Checking a change

1. `swift test`.
2. For reading changes, run the OpenScore layout check (`tools/eval/README.md`) and compare it page by page
   with a run from before the change.
3. Scan both test scores on the phone and compare with the expected results above, or with a previous scan's
   folder: the same notes, rests and chords in order, and the same title, composer and part names.
4. For notation changes, open the MusicXML in MuseScore 4 (`mscore -o out.mscz score.musicxml`, without `-f`).
   It should import with no "incomplete measure" errors.
5. Before a release, compare a build with the last tag on the whole test set: the multi-part scores first, then
   the 672 regression inputs and 200 Real Book pages (`tools/writercheck/regression-kit/`, on this Mac only; it
   keeps 0.1.24's output as the baseline; 0.1.25 scans the same). Look at the page for every kind of change. Rules around the reader are
   where most gains came from, and each new one has broken some other score at least once.

## Releasing to Aria

1. Commit to `main` here, tag the next version (`git tag 0.1.1`) and push (`git push origin main 0.1.1`).
   Patch for fixes, minor for API changes.
2. In Aria: File → Packages → Update to Latest Package Versions, rebuild and scan in the app.
   Aria's `Package.resolved` should move to the new tag.

To try a change in Aria before tagging, drag this folder into Aria's Xcode project (a local override). Remove it
before committing Aria: Aria never commits a path to a machine.

## Changing the models

The models are copista-2m exported to ONNX (`tools/copista_export_onnx.py`) and checked against PyTorch
(`tools/copista_check_onnx.py`). Export gotchas: torchvision `roi_align` has no ONNX export (replaced by an exact
gather), `nn.MultiheadAttention` bakes the sequence length when traced (the encoder layer is rewritten), and the
evidence inputs must be int64. `Vendor/copisteria/` records what the port changed (Apache-2.0 requires it).

## Known weak spots

- A chord line is dropped when the notes have fewer bars than the page prints (`ChordMusicXML` can't place it).
- Parenthesised turnaround chords, e.g. `(Am7 … G7)`, are missed.
- Some pages read extra bars (36 on the OpenScore check: Butterworth, Cowen *The Better Land*, Brahms
  *Die Mainacht* p2).
- An empty staff, or a small ossia staff, can be missed; the rest of that system then still lands in the right
  parts in most cases, but the missed staff's notes are lost.
- Two-page spreads read as fake multi-part systems; one page per photo is expected.
- Photos and photocopies: a page edge in the margin and a curled staff are handled (`Front.edgeRules`,
  `Front.joinSplit`), but the OpenScore check can't show these; check them on real photos.
- The Apple chord route sends crops for every bar even on pages with no chord symbols, which uses up the quota on
  long classical scores.
- On-device chords: an alternate chord in a second row over the line is left out when it falls on the main chord's
  beat (both would play).
- Navigation is written as words plus the standard `<sound>` jump attributes (`ScoreMetadataMusicXML.
  insertPlaybackJumps`), but only when the target is unambiguous: one segno before a D.S., one To Coda and one coda
  for "al Coda", one Fine for "al Fine". A segno or coda sign copisteria missed (small ones often are) leaves the
  jump as words. MuseScore 4.7.6 imports `<sound>` jumps only with "infer text type" on; Aria's engine carries the
  upstream fix (#33802) that imports them regardless, and D.S./D.C./To Coda/Fine are written at the end of their
  bar, where MuseScore expects them.
- On-device text: handwritten headers (Real Book 6) read poorly; lyrics are kept out of staff text by position and
  by look (hyphenated syllables, lowercase words), not perfectly.

## Third-party code

copisteria and copista-2m (Apache-2.0) in `Vendor/copisteria/`. ONNX Runtime 1.27.0 (MIT) is downloaded as a
pinned binary target.

## Publishing ScannerCore source

The original code is GPLv3; retain LICENSE and THIRD_PARTY_NOTICES.md when distributing.
This repository holds ScannerCore only; the app is kept private and is not published. Follow
SOURCE_RELEASE.md and make the exact shipped tag publicly readable before distributing
Aria. Never publish local scans, training data, benchmark outputs or credentials.
