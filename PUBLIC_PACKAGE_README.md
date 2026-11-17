# ScannerCore

Reads printed sheet music images and PDFs into editable MusicXML, entirely offline
with the default options. This is the public Swift package used by Aria.

Requires Swift 6, iOS 16 or macOS 14. Android support uses Swift Android SDK and ONNX
Runtime 1.27.0; the application supplies the model directory and decoded PPM/PGM pages.
The package manifest retains the name ScoreScanner; its library product is ScannerCore.

```swift
.package(url: "https://github.com/hdi200/ScannerCore.git", exact: "0.1.19")
```

```swift
import ScannerCore
let reading = try await ScoreReader.read(pdf: data)
try reading.score.xml.write(to: outputURL)
```

Build and test on macOS with `swift build` and `swift test`.
Run an offline scan with:

```sh
swift run -c release ScannerCheck --scan-pdf score.pdf Sources/ScannerCore/Resources/Models out.musicxml
```

The checked-in models include copista-2m for notation and PP-OCRv6 for chord symbols
and page text. Model export, training and comparison tools and their configuration are
in tools. No private test scores or benchmark crops are distributed. Run one scan at
a time. Optional Apple-model routes require the applicable Apple SDK and availability;
the default reading uses the bundled models rather than an Apple model.

Scans can contain recognition errors. Ordinary silent gaps become printed rests while
tuplet fillers remain hidden; note timing, pickups and short measures are preserved.
Review the result in your score editor.

Copyright 2026 Jack Gruber. Original code is GPL version 3, without warranty. See
LICENSE and THIRD_PARTY_NOTICES.md. Third-party code and models retain their original
licenses. RELEASE_SOURCE.json records file hashes and the originating source tag.
