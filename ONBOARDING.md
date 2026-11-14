# Working on ScoreScanner

Start here if you are new to this repo, or an agent opening it for the first time. `README.md` covers using the
package. This file covers changing it.

## What ships where

| Product | Built from | Who uses it |
| --- | --- | --- |
| **ScannerCore** (Swift package library) | `Package.swift`, `Sources/ScannerCore/` | ScoreScanner, and Aria (`hdi200/aria`, `MuseReaderiOS`) by GitHub URL + version tag |
| **ScoreScanner** (iOS app) | `App/`, `ScoreScanner.xcodeproj` (uses the package from `.`) | Ships on its own |
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
   - PDFs: `PDFScanner` renders pages at 2480 px and `CopistaMerge` joins them.
2. **Chord names, on Private Cloud Compute.** `ChordBands`, `ChordPresence` and `ChordImageCrops` cut one strip per
   bar above each staff. `AppleChordReader` asks Apple's model to read them. `ChordGrammar` and `ChordText` check the
   answers, and `ChordMusicXML` places them as `<harmony>` in the right bar.
3. **Page text, on Private Cloud Compute.** `ScoreTextImageCrops` and `AppleScoreTextReader` read the title,
   composer, tempo, instrument names and staff text. `ScoreMetadataMusicXML` writes them in.
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
  - `App/SampleAssets/sample.jpg`, used by `--scan-sample`: local only, not in git.
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

The app builds through the shell. Build **arm64 only**; a universal build fails to find ScannerCore for x86_64.

```sh
python3 tools/prepare_player.py              # once: stages the GPL-3.0 player into App/SampleAssets/Player
xcodebuild -project ScoreScanner.xcodeproj -scheme ScoreScanner -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch>/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
```

For the phone, use `-configuration Release -destination generic/platform=iOS -allowProvisioningUpdates`. The
entitlements include Private Cloud Compute.

### Running a scan without the UI

Launch arguments: `--scan-file FILE`, `--scan-pdf FILE`, `--scan-sample`. The app logs
`SCANNER_TIMING source=… wall=… cloudRequests=… chordRoute=…` when done (or `SCANNER_FULL ERROR`). Each scan's
`score.musicxml`, `score.raw.musicxml`, `apple-chord-report.json` (`counts`: accepted/unusual/blocked/placed),
`apple-score-text-report.json`, `chord-crops/` and `scan.json` land in the app's `Documents/Scans/<id>/`.

- **iPhone** (preferred for cloud reading). The phone must be unlocked.
  ```sh
  xcrun devicectl device install app --device "Jack's iPhone" <dd>/Build/Products/Release-iphoneos/ScoreScanner.app
  xcrun devicectl device process launch --device "Jack's iPhone" --terminate-existing --console \
    com.jackgruber.ScoreScanner --scan-file TestScores/HarbourLights.jpg
  xcrun devicectl device copy from --device "Jack's iPhone" --domain-type appDataContainer \
    --domain-identifier com.jackgruber.ScoreScanner --source Documents/Scans/<id> --destination <scratch>/out
  ```
- **Simulator.** `xcrun simctl launch --console-pty <udid> com.jackgruber.ScoreScanner --scan-file /abs/path`.
  Copy test scores off the phone first with `devicectl device copy from`. Private Cloud Compute can throttle a
  simulator; move to the phone when it does.

Run **one scan at a time**: overlapping launches get cut off and their reports land under the wrong scan.

App settings (`App/ScanOptions.swift`, `SettingsKey`) map to `ScoreReadOptions`: read chord names, read staff
text, prefer Private Cloud Compute, allow on-device fallback (off), cloud requests at once.

### Checking a change

1. `swift test`.
2. For reading changes, run the OpenScore layout check (`tools/eval/README.md`) and compare it page by page
   with a run from before the change.
3. Scan both test scores on the phone and compare with the expected results above, or with a previous scan's
   folder: the same notes, rests and chords in order, and the same title, composer and part names.
4. For notation changes, open the MusicXML in MuseScore 4 (`mscore -o out.mscz score.musicxml`, without `-f`).
   It should import with no "incomplete measure" errors.

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
- Cloud chord reading sends crops for every bar even on pages with no chord symbols, which uses up the quota on
  long classical scores.

## Third-party code

copisteria and copista-2m (Apache-2.0) in `Vendor/copisteria/`. ONNX Runtime 1.27.0 (MIT) is downloaded as a
pinned binary target. The app's player, musicxml-player (GPL-3.0), is fetched by `tools/prepare_player.py` and
never committed. Licence texts the app shows are in `App/SampleAssets/Licenses/`.
