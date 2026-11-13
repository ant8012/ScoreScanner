import Foundation
import ScannerCore

// Mac command line for the scanner, for checking reads outside the app.
//   --copista IMAGE MODELS OUTDIR       one page: detections, layout, readings and score.musicxml
//   --scan-image IMAGE MODELS OUT.xml   one page image to MusicXML, as the app reads it
//   --scan-pdf PDF MODELS OUT.xml       a whole PDF, pages joined
//   --chord-crops IMAGE MODELS OUTDIR   the chord strips the app sends for reading, one PGM per bar

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
    guard arguments.count == 5 else {
        throw ScannerError.invalid("Usage: ScannerCheck --copista|--scan-image|--scan-pdf|--chord-crops INPUT MODELS OUTPUT")
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
