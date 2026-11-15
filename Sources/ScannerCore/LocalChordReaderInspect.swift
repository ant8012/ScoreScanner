import Foundation

/// Mac checks for the on-device chord reader against `tools/chordfind` (`onnx_bench.py`, `export_crops.py`).
public enum LocalChordReaderInspect {
  /// Reads the crops an `export_crops.py` folder holds (manifest.json and crop-NNNN.png) and writes
  /// `results-ROUTE.json` in the shape `ocr_bench.py` writes. `chord` is what the app would write into the score:
  /// the readings `ChordText.modelSymbols` accepts, joined by spaces.
  public static func readCrops(models: URL, crops: URL, route: String) throws -> String {
    let model = try LocalChordReader.Model(models: models)
    guard let items = try JSONSerialization.jsonObject(
      with: Data(contentsOf: crops.appendingPathComponent("manifest.json"))) as? [[String: Any]]
    else { throw ScannerError.invalid("manifest.json is not a list") }
    let start = Date()
    var results: [[String: Any]] = []
    for item in items {
      guard let id = item["id"] as? Int, let file = item["file"] as? String else { continue }
      let gray = try Copista.decodeGray(Data(contentsOf: crops.appendingPathComponent(file)))
      let reading = try model.read(LocalChordReader.Image(width: gray.width, height: gray.height, pixels: gray.pixels))
      let chords = LocalChordReader.accepted(reading.text)
      results.append([
        "id": id, "visibleText": reading.text, "score": (reading.score * 10_000).rounded() / 10_000,
        "isChord": !chords.isEmpty, "chord": chords.joined(separator: " "),
      ])
    }
    let seconds = Date().timeIntervalSince(start)
    let json: [String: Any] = [
      "route": route, "seconds": seconds, "requests": results.count, "failed": 0, "batchSeconds": [],
      "results": results,
    ]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
      .write(to: crops.appendingPathComponent("results-\(route).json"))
    return "read \(results.count) crops, \(String(format: "%.1f", 1000 * seconds / Double(max(1, results.count)))) ms each"
  }

  /// Runs the finder and the reader on pages whose copisteria output `--copista` dumped (PAGES/NAME.png with
  /// COP/cop-NAME/layout.json and tok.json), cutting crops in Swift. Writes one JSON list: chart, word box,
  /// reading and score for every word read.
  public static func readPages(pages: URL, copista: URL, models: URL, output: URL) throws -> String {
    let model = try LocalChordReader.Model(models: models)
    let names = try FileManager.default.contentsOfDirectory(atPath: pages.path)
      .filter { $0.hasSuffix(".png") && !$0.contains("-key-") }.sorted()
    var out: [[String: Any]] = []
    let start = Date()
    for file in names {
      let name = String(file.dropLast(4))
      let cop = copista.appendingPathComponent("cop-\(name)")
      guard FileManager.default.fileExists(atPath: cop.appendingPathComponent("layout.json").path) else { continue }
      let gray = try Copista.decodeGray(Data(contentsOf: pages.appendingPathComponent(file)))
      let layout = try ChordFinderInspect.loadLayout(cop)
      let page = LocalChordReader.Image(width: gray.width, height: gray.height, pixels: gray.pixels)
      for word in ChordFinder.find(gray: gray.pixels, width: gray.width, height: gray.height, layout: layout)
      where word.kind == .text {
        guard let cut = LocalChordReader.crop(page: page, word: word, sp: layout.staves[word.staff].sp) else { continue }
        let reading = try model.read(cut.image)
        out.append([
          "chart": name, "word": [word.x0, word.y0, word.x1, word.y1], "visibleText": reading.text,
          "score": (reading.score * 10_000).rounded() / 10_000,
          "chord": LocalChordReader.accepted(reading.text).joined(separator: " "),
        ])
      }
    }
    try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    return "read \(out.count) words on \(names.count) pages in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
  }
}
