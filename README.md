# ScoreScanner

Reads printed sheet music (a photo, a camera scan or a PDF) into MusicXML on iPhone.

- **Notes** are read on the device by a Swift port of KobiMusic's
  [copisteria](https://github.com/kobimusic/copisteria) reader (copista-2m, Apache-2.0), run with ONNX Runtime.
- **Chord names** are read on the device too: a chord finder cuts each word above the staves and a PP-OCRv6 small
  text recogniser fine-tuned on chord symbols reads it (ONNX, no network, any supported device). Apple's model can
  still read them instead (`chordReader: .appleModel`), for comparison.
- **Title, composer, tempo, rehearsal marks, navigation (D.S. al Coda, To Coda, Fine) and other staff text** are
  read on the device too, with the standard PP-OCRv6 small recogniser, when `readStaffText` is on. Apple's
  Foundation Models on Private Cloud Compute (iOS 27) can read them instead (`textReader: .appleModel`).

The repository holds two things:

| Path | What it is |
| --- | --- |
| `Package.swift`, `Sources/`, `Tests/` | **ScannerCore**, the reader, as a Swift package. ScoreScanner and Aria both depend on it. It also builds for Android (Aria's Android app, through Skip): see "Android" below. |
| `App/`, `ScoreScanner.xcodeproj` | **ScoreScanner**, the standalone app: library, scan screens, Verovio player, settings. |

## Using the reader

```swift
import ScannerCore

let reading = try await ScoreReader.read(pdf: data) { status in print(status) }
try reading.score.xml.write(to: url)          // MusicXML, chords and text written in
reading.title                                   // the printed title, if read
reading.chordCount                              // chord symbols placed in the score
```

`ScoreReader.read(image:)` reads one page image. `ScoreReadOptions` turns chord and staff-text reading on or off,
picks the readers (`chordReader` and `textReader`, both `.onDevice` by default) and sets how many Private Cloud
Compute requests run at once. With the defaults a reading never leaves the device (`ScoreReadOptions.usesAppleModel`
is false). `ScoreReader.cloudReadingAvailable` says whether Apple's model can be used here. The models ship inside the
package (`Sources/ScannerCore/Resources/Models`, 58 MB: copista-2m 16 MB, the chord reader 21 MB, the text reader
21 MB).

The package supports iOS 16 and macOS 14; notes and chords read on all of them. Staff text and the Apple chord
route need iOS 27 and an SDK that has FoundationModels. Read one score at a time: request limits are shared by the
process.

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
swift run -c release ScannerCheck --read-image page.jpg Sources/ScannerCore/Resources/Models out.musicxml   # offline
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

## Android

ScannerCore builds for Android with the Swift Android SDK (Skip), for Aria's Android app. What differs there:

- **ONNX Runtime:** `OnnxRuntimeAndroid` gives the same `ORTSession`/`ORTValue` classes as the Objective-C bindings,
  over the C API (`COnnxRuntimeAndroid`), and loads `libonnxruntime.so` at run time. The app packages it from
  `com.microsoft.onnxruntime:onnxruntime-android:1.27.0`.
- **Pages:** there is no Core Graphics or ImageIO, so the app decodes photos and draws PDF pages itself and passes
  each as a binary PPM or PGM: `ScoreReader.read(pageCount:...page:)` asks for one page at a time. PDFs and other
  image formats are read only on Apple platforms.
- **Models:** an Android app gets no resources of this package, so the app ships the `Models` folder itself and
  passes its path as `models:`. `Scanner.bundledModels` points nowhere on Android.
- Apple's model routes (`.appleModel`) are not available.

Check an Android build: `skip android build --arch aarch64 --product ScannerCore` from the repository.

