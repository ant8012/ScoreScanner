import Foundation

/// Reads one page with the copisteria engine and writes every stage, for checking the port against the Python
/// reader: detections, layout, readings, MusicXML.
public enum CopistaInspect {
  public static func run(image: URL, models: URL, output: URL) throws -> String {
    let start = Date()
    let page = Copista.straightened(try Copista.decodeGray(Data(contentsOf: image)))
    let engine = try Copista.Engine(models: models)
    let loaded = Date()
    let r = try engine.read(page)
    let seconds = Date().timeIntervalSince(loaded)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func write(_ name: String, _ object: Any) throws {
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: output.appendingPathComponent(name))
    }
    try write("dets.json", r.detections.map { d -> [String: Any] in
      var o: [String: Any] = ["cls": d.cls, "conf": d.conf, "xyxy": d.xyxy]
      if let a = d.attrs { o["attrs"] = a; o["attr_p"] = d.attrP; o["attr_dist"] = d.attrDist }
      return o
    })
    let L = r.reading.layout
    try write("layout.json", [
      "imgsz": r.imgsz, "ink": L.ink, "sp": L.sp,
      "staves": L.staves.map { ["y0": $0.y0, "y1": $0.y1, "x0": $0.x0, "x1": $0.x1, "sp": $0.sp, "system": $0.system,
                                "pos": $0.pos, "bars": $0.bars.map { L.syms[$0].box.0 }] as [String: Any] },
      "systems": L.systems.map { ["staves": $0.staves, "columns": $0.columns] },
      "syms": L.syms.map { ["cls": $0.cls, "box": [$0.box.0, $0.box.1, $0.box.2, $0.box.3], "staff": $0.staff, "bar": $0.bar,
                            "synthetic": $0.synthetic, "p": $0.p] as [String: Any] },
      "revised": r.reading.revised.map { ["staff": $0.key, "x": $0.value] }])
    var tok: [String: Any] = [:]
    for (si, t) in r.reading.tok {
      var o: [String: Any] = ["real": t.realP, "cls": r.reading.classes[t.cls]]
      if t.heads["pos"] != nil { o["pos"] = t.pos; o["voice"] = t.voice; o["dots"] = t.dots; o["tup"] = t.tup }
      if t.heads["alter"] != nil { o["alter"] = t.alter.map { "\($0)" } ?? "key" }
      if let on = t.onset { o["onset"] = on }
      if t.hasBarHeads { o["key"] = t.key.map { "\($0)" } ?? "None"; o["time"] = t.time ?? "None"; o["clef"] = t.clef ?? "None" }
      tok[String(si)] = o
    }
    try write("tok.json", tok)
    try Data(r.xml.utf8).write(to: output.appendingPathComponent("score.musicxml"))
    // the page as the reader saw it (after straightening), for drawing the layout over it
    try (Data("P5\n\(page.width) \(page.height)\n255\n".utf8) + Data(page.pixels))
      .write(to: output.appendingPathComponent("page.pgm"))
    return "copista: \(r.detections.count) detections at \(r.imgsz), \(L.staves.count) staves, \(L.systems.count) systems, " +
      "\(r.reading.tok.count) symbols read in \(String(format: "%.2f", seconds))s (models loaded in " +
      "\(String(format: "%.2f", loaded.timeIntervalSince(start)))s)"
  }
}
