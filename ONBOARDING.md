# Working on ScoreScanner

> Release handoff, November 20, 2026: the latest public ScannerCore is **0.1.23** (`d14c2a2`), and Aria iOS 7.7.0 (17) and Android 1.4.0 (28) resolve it (Aria source `ce89f6c467`, committed locally, not pushed; builds validated and installed, not yet submitted). Still to check on a phone: scanning the Matrix (memory and time), Lady (drums, transposed parts by ear), and Android runtime. 0.1.20-0.1.23 (Nov 18-19): large orchestral scores and photocopies; hyphenated syllables, page turns without courtesy clefs, a crash at the page's foot; transposition from key signatures; clefs change only where printed (Real Book lines read as drums 52 of 200 pages -> 1); pages joined to the latest page laid out alike; instrument names found as whole words. What is still open: `tools/chordfind/REMAINING_ISSUES.md` ("Nov 19 stuff" first). How changes were checked, with a 0.1.23 baseline: `tools/writercheck/regression-kit/README.md` (local only). Aria uses the bundled on-device copisteria/PaddleOCR readers, not Apple's model. The Private Cloud Compute rule below applies only when explicitly exercising the legacy `.appleModel` route; it must not replace Aria's local readers. Package minimum remains iOS 16, while Aria's app target is iOS 17. Older `HANDOFF_TUPLETS.md` and `ANDROID_4GB_SCANNER_HANDOFF.md` carry follow-up banners. For current Aria binaries, device results, camera/screenshots and source publication gaps, see the local Aria `HANDOFF-SCAN.md` and `promo/scan-import/RELEASE_STATUS.md`.

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
  A breaking change needs a minor version bump and a matching Aria change.

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
   keeps 0.1.23's output as the baseline). Look at the page for every kind of change. Rules around the reader are
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
