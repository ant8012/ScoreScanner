import Foundation
import ScannerCore

// Mac command line for the scanner, for checking reads outside the app.
//   --copista IMAGE MODELS OUTDIR       one page: detections, layout, readings and score.musicxml
//   --scan-image IMAGE MODELS OUT.xml   one page image to MusicXML, as the app reads it
//   --scan-pdf PDF MODELS OUT.xml       a whole PDF, pages joined
//   --chord-crops IMAGE MODELS OUTDIR   the chord strips the app sends for reading, one PGM per bar
//   --chordfind IMAGE COPISTA_DIR OUT.json   the chord finder's word boxes, bars and beats for one page, from the
//                                            layout.json and tok.json --copista wrote (parity with find.py)
//   --chord-read CROPS_DIR MODELS ROUTE       the on-device chord reader on export_crops.py crops, writing
//                                            CROPS_DIR/results-ROUTE.json (parity with onnx_bench.py)
//   --chord-read-pages PAGES COP MODELS OUT.json   finder, crops and reader on pages --copista dumped (COP/cop-NAME)
//   --read-image IMAGE MODELS OUT.xml   one page read as the apps read it, chords and text on this device
//   --read-pdf PDF MODELS OUT.xml       the same for a whole PDF

func writeChordCrops(image: Data, models: URL, output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scan = try Scanner.scan(image: image, models: models) { _ in }
    var manifest: [[String: Int]] = []
    for (index, crop) in try ChordImageCrops.from(scan).enumerated() {
        var pgm = Data("P5\n\(crop.width) \(crop.height)\n255\n".utf8)
        pgm.append(crop.pixels)
        let name = String(format: "crop%03d-system%d-bar%d.pgm", index, (crop.system ?? crop.staff) + 1, crop.bar + 1)
        try pgm.write(to: output.appendingPathComponent(name))
        manifest.append([
            "index": index, "staff": crop.staff, "bar": crop.bar, "pageX": crop.pageX,
            "width": crop.width, "barRight": Int(crop.barRight),
        ])
    }
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("crops.json"))
    print("Wrote \(manifest.count) chord crops")
}

do {
    let arguments = CommandLine.arguments
    if arguments.count == 6, arguments[1] == "--chord-read-pages" {
        let url = { URL(fileURLWithPath: arguments[$0]) }
        print(try LocalChordReaderInspect.readPages(pages: url(2), copista: url(3), models: url(4), output: url(5)))
        exit(0)
    }
    guard arguments.count == 5 else {
        throw ScannerError.invalid(
            "Usage: ScannerCheck --copista|--scan-image|--scan-pdf|--chord-crops|--chordfind INPUT MODELS OUTPUT")
    }
    let input = URL(fileURLWithPath: arguments[2]), models = URL(fileURLWithPath: arguments[3])
    let output = URL(fileURLWithPath: arguments[4])
    switch arguments[1] {
    case "--copista":
        print(try CopistaInspect.run(image: input, models: models, output: output))
    case "--scan-image":
        let scan = try Scanner.scan(image: Data(contentsOf: input), models: models) { print($0) }
        try scan.xml.write(to: output)
        print("PASS: \(scan.staffs.count) staffs, \(scan.seconds)s")
    case "--scan-pdf":
        let result = try PDFScanner.scan(data: Data(contentsOf: input), models: models) { print($0) }
        try result.xml.write(to: output)
        print("PDF PASS: \(result.pageCount) pages, \(result.staffCount) staffs, \(result.seconds)s")
    case "--chordfind-scan":
        print(try ChordFinderInspect.runScan(image: input, models: models, output: output))
    case "--chordfind":
        print(try ChordFinderInspect.run(image: input, copista: models, output: output))
    case "--read-image", "--read-pdf":
        // chords and text on this device: nothing is sent to Apple's model
        let options = ScoreReadOptions(
            readChordNames: true, readStaffText: true, chordReader: .onDevice, textReader: .onDevice)
        precondition(!options.usesAppleModel)
        let data = try Data(contentsOf: input)
        let start = Date()
        let reading = arguments[1] == "--read-image"
            ? try await ScoreReader.read(image: data, models: models, options: options) { print($0) }
            : try await ScoreReader.read(pdf: data, models: models, options: options) { print($0) }
        try reading.score.xml.write(to: output)
        let counts = reading.chords.counts
        print("READ PASS: \(reading.chordCount) chords in the score (accepted \(counts?.accepted ?? 0), unusual "
            + "\(counts?.unusual ?? 0), blocked \(counts?.blocked ?? 0)), chords \(String(format: "%.2f", reading.chords.seconds))s, "
            + "total \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        if let note = reading.chords.routeNote { print("NOTE: \(note)") }
        if let m = reading.text.metadata {
            print("HEADER: title=\"\(m.title)\" composer=\"\(m.composer)\" arranger=\"\(m.arranger)\" tempo=\"\(m.tempoText)\" bpm=\(m.bpm) unit=\(m.beatUnit)")
        }
        for t in reading.text.staffText {
            print("TEXT: system \(t.system) bar \(t.bar + 1) [\(t.category)] \(t.text)")
        }
    case "--chord-read":
        print(try LocalChordReaderInspect.readCrops(models: models, crops: input, route: arguments[4]))
    case "--chord-crops":
        try writeChordCrops(image: Data(contentsOf: input), models: models, output: output)
    default:
        throw ScannerError.invalid("Unknown mode \(arguments[1])")
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(2)
}
