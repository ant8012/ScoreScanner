import Foundation

/// Runs the chord finder on one page from the files `ScannerCheck --copista` writes (layout.json, tok.json), for
/// checking the Swift finder against `tools/chordfind/find.py` on the same input (`finder_parity.py`).
public enum ChordFinderInspect {
  /// `copista` holds layout.json and tok.json; `output` receives the proposals as JSON.
  public static func run(image: URL, copista: URL, output: URL) throws -> String {
    let page = try Copista.decodeGray(Data(contentsOf: image))
    let layout = try loadLayout(copista)
    let start = Date()
    let found = ChordFinder.find(gray: page.pixels, width: page.width, height: page.height, layout: layout)
    let seconds = Date().timeIntervalSince(start)
    try write(found, to: output)
    let words = found.filter { $0.kind == .text }.count
    return "chordfind: \(found.count) proposals, \(words) words, \(String(format: "%.3f", seconds))s"
  }

  /// The finder run inside a full scan (`Scanner.scan`, from copisteria's reading in memory), for checking it
  /// matches the run from dumped files.
  public static func runScan(image: URL, models: URL, output: URL) throws -> String {
    let scan = try Scanner.scan(image: Data(contentsOf: image), models: models)
    try write(scan.chordWords, to: output)
    return "chordfind (scan): \(scan.chordWords.count) proposals"
  }

  static func write(_ found: [ChordFinder.Proposal], to output: URL) throws {
    let json: [[String: Any]] = found.map { p in
      var o: [String: Any] = ["x0": p.x0, "y0": p.y0, "x1": p.x1, "y1": p.y1, "staff": p.staff, "order": p.order,
                              "kind": p.kind.rawValue, "bar": p.bar, "anchor": p.anchor]
      if let b = p.beat { o["beat"] = b }
      if let s = p.beatSource { o["beat_src"] = s }
      if let s = p.sign { o["sign"] = s }
      if p.upperRow { o["row"] = "upper" }
      return o
    }
    try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: output)
  }

  /// The finder's input from copisteria's dumped layout.json and tok.json.
  public static func loadLayout(_ dir: URL) throws -> ChordFinder.Layout {
    guard let L = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("layout.json")))
            as? [String: Any],
          let T = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("tok.json")))
            as? [String: Any] else {
      throw ScannerError.invalid("layout.json or tok.json is not a JSON object")
    }
    func d(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    let staves = (L["staves"] as? [[String: Any]] ?? []).map { s in
      ChordFinder.Staff(x0: d(s["x0"]), x1: d(s["x1"]), y0: d(s["y0"]), y1: d(s["y1"]), sp: d(s["sp"]),
                        bars: (s["bars"] as? [Any] ?? []).map { d($0) })
    }
    let syms = (L["syms"] as? [[String: Any]] ?? []).map { s -> ChordFinder.Symbol in
      let b = (s["box"] as? [Any] ?? []).map { d($0) }
      return ChordFinder.Symbol(cls: s["cls"] as? String ?? "", box: ChordFinder.Box(b[0], b[1], b[2], b[3]),
                                staff: (s["staff"] as? NSNumber)?.intValue ?? -1,
                                bar: (s["bar"] as? NSNumber)?.intValue ?? -1, p: (s["p"] as? NSNumber)?.doubleValue ?? 1)
    }
    var tokens: [Int: ChordFinder.Token] = [:]
    for (k, v) in T {
      guard let i = Int(k), let o = v as? [String: Any] else { continue }
      tokens[i] = ChordFinder.Token(onset: (o["onset"] as? NSNumber)?.doubleValue,
                                    real: (o["real"] as? NSNumber)?.doubleValue, time: o["time"] as? String)
    }
    return ChordFinder.Layout(staves: staves, syms: syms, sp: d(L["sp"]), tokens: tokens)
  }
}
