# ScoreScanner

Reads printed sheet music (a photo, a camera scan or a PDF) into MusicXML on iPhone.

- **Notes** are read on the device by a Swift port of KobiMusic's
  [copisteria](https://github.com/kobimusic/copisteria) reader (copista-2m, Apache-2.0), run with ONNX Runtime.
- **Chord names, title, composer, tempo, instrument names and staff text** are read from the page by Apple's
  Foundation Models on Private Cloud Compute (iOS 27). The on-device model is not used unless a caller turns
  `allowOnDeviceFallback` on.

The repository holds two things:

| Path | What it is |
| --- | --- |
| `Package.swift`, `Sources/`, `Tests/` | **ScannerCore**, the reader, as a Swift package. ScoreScanner and Aria both depend on it. |
| `App/`, `ScoreScanner.xcodeproj` | **ScoreScanner**, the standalone app: library, scan screens, Verovio player, settings. |

## Using the reader

```swift
import ScannerCore

let reading = try await ScoreReader.read(pdf: data) { status in print(status) }
try reading.score.xml.write(to: url)          // MusicXML, chords and text written in
reading.title                                   // the printed title, if read
reading.chordCount                              // chord symbols placed in the score
```

`ScoreReader.read(image:)` reads one page image. `ScoreReadOptions` turns chord and staff-text reading on or off
and sets how many Private Cloud Compute requests run at once. `ScoreReader.cloudReadingAvailable` says whether
Apple's model can be used here; without it, read with `readChordNames: false, readStaffText: false` to get the
notes only. The models ship inside the package (`Sources/ScannerCore/Resources/Models`, 16 MB).

The package supports iOS 16 and macOS 14; reading chords and text needs iOS 27 and an SDK that has
FoundationModels. Read one score at a time: request limits are shared by the process.

What the reader writes:

- A bar that holds more than its meter gets a time signature of its own length with **"check bar"** above it,
  so MuseScore accepts the file and the bar is easy to find and fix.
- Part names it cannot read are written as hidden `Part n` (`print-object="no"`); instrument names read from the
  page replace them when there is one for every part.

## Building and checking

```sh
swift build                 # ScannerCore and ScannerCheck on the Mac
swift test                  # ScannerCore tests
```

Mac reads from the command line (MODELS is `Sources/ScannerCore/Resources/Models`):

```sh
swift run -c release ScannerCheck --scan-pdf score.pdf Sources/ScannerCore/Resources/Models out.musicxml
swift run -c release ScannerCheck --scan-image page.jpg Sources/ScannerCore/Resources/Models out.musicxml
swift run -c release ScannerCheck --copista page.jpg Sources/ScannerCore/Resources/Models outdir
swift run -c release ScannerCheck --chord-crops page.jpg Sources/ScannerCore/Resources/Models outdir
```

The app:

```sh
python3 tools/prepare_player.py   # stages the GPL-3.0 musicxml-player into App/SampleAssets/Player (git-ignored)
xcodebuild -project ScoreScanner.xcodeproj -scheme ScoreScanner -configuration Debug \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
```

Build arm64 only. Launch arguments for unattended scans: `--scan-pdf FILE`, `--scan-file FILE`,
`--scan-sample` (a local `App/SampleAssets/sample.jpg`, not in git). Each scan's score, raw score, chord and text
reports and chord crops land in the app's `Documents/Scans/<id>/`. Private Cloud Compute can throttle a
simulator; test on a physical iPhone when it does.

## Releasing a reader change to Aria

1. Change and test the reader here (`swift test`, a scan in the app).
2. Commit, then tag a version (`git tag 0.2.0`) and push.
3. In Aria, update the ScoreScanner package to that version and run Aria's import check.

While working on both at once, Xcode can use this folder in place of the pinned package: drag the folder into
Aria's project navigator (a local override), and remove it before committing Aria.

## Third-party code

- copisteria and copista-2m: Apache-2.0, `Vendor/copisteria/` (LICENSE, NOTICE, what changed in the port).
  Re-export the models with `tools/copista_export_onnx.py` and check them with `tools/copista_check_onnx.py`.
- ONNX Runtime 1.27.0: MIT, `Vendor/onnxruntime/` (pinned source revision and file checksums).
- musicxml-player (app only, not part of ScannerCore): GPL-3.0, fetched by `tools/prepare_player.py`.
