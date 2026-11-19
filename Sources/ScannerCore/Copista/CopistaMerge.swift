import Foundation

/// Pages read by copisteria, joined into one score: each part's measures page after page, renumbered. A page that
/// shows fewer parts (a part resting, a system that hides it) gives the parts it lacks silent padding as long
/// as its own bars, so the parts stay in step. The printed-rest pass makes that padding visible. Each page keeps
/// the divisions, key, meter and clefs it states.
enum CopistaMerge {
  static func combine(_ pages: [Data], title: String = "") throws -> Data {
    try combine(pages, title: title, labels: []).xml
  }

  /// `labels`: per page, the instrument name printed beside each of its parts ("" where none was read). Returns
  /// the score and one name per part of it.
  static func combine(_ pages: [Data], title: String = "", labels: [[String]]) throws -> (xml: Data, labels: [String]) {
    let roots = try pages.map { try XMLNode.parse($0) }
    guard let first = roots.first else { throw ScannerError.invalid("The PDF did not contain any readable pages") }
    let partCount = roots.map { $0.all("part").count }.max() ?? 0
    guard partCount > 0 else { throw ScannerError.invalid("No readable music was found") }
    let sigs = roots.enumerated().map { p, root in
      root.all("part").enumerated().map { k, part in
        var s = signature(part, label: p < labels.count && k < labels[p].count ? labels[p][k] : "")
        s.rank = Double(k) / Double(max(1, root.all("part").count - 1))
        return s
      }
    }
    if !samePartsThroughout(sigs) {
      return try aligned(roots, sigs, title: title)
    }
    if let plist = first.first("part-list") {
      var n = plist.all("score-part").count
      while n < partCount {
        n += 1
        plist.children.append(XMLNode("score-part", attributes: ["id": "P\(n)"],
                                      children: [XMLNode("part-name", text: "Part \(n)", attributes: ["print-object": "no"])]))
      }
    }
    let parts = (0..<partCount).map { XMLNode("part", attributes: ["id": "P\($0 + 1)"]) }
    var numbers = [Int](repeating: 0, count: partCount)
    var endedFlagged = false
    for (pageIndex, root) in roots.enumerated() {
      let pageParts = root.all("part")
      if endedFlagged {
        for part in pageParts {
          for t in part.first("measure")?.all("attributes").compactMap({ $0.first("time") }) ?? [] {
            t.attributes["print-object"] = nil
          }
        }
      }
      endedFlagged = pageParts.first?.all("measure").last?.all("attributes").contains {
        ($0.first("time")?.attributes["id"] ?? "").hasPrefix(Copista.Tidy.overflowID)
      } ?? false
      // a page turn starts a new system, so each page's systems stay as printed. Not a new page: the score's page
      // size and staff size are MuseScore's, not the print's, so a printed page rarely fills one page of the score,
      // and a forced page break left a page holding only the systems that spilled over.
      func turn(_ m: XMLNode) {
        guard pageIndex > 0 else { return }
        m.children.removeAll { $0.tag == "print" }
        m.children.insert(XMLNode("print", attributes: ["new-system": "yes"]), at: 0)
      }
      let ref = pageParts.first?.all("measure") ?? []
      let divisions = ref.first?.first("attributes")?.first("divisions")?.text ?? "1"
      for i in 0..<partCount {
        if i < pageParts.count {
          for (k, m) in pageParts[i].all("measure").enumerated() {
            let c = m.copy()
            if k == 0 { turn(c) }
            numbers[i] += 1
            c.attributes["number"] = "\(numbers[i])"
            if numbers[i] > 1 { c.attributes["implicit"] = nil }
            parts[i].children.append(c)
          }
        } else {
          for (k, m) in ref.enumerated() {
            numbers[i] += 1
            let c = XMLNode("measure", attributes: ["number": "\(numbers[i])"])
            if k == 0 { c.children.append(XMLNode("attributes", children: [XMLNode("divisions", text: divisions)])) }
            if k == 0 { turn(c) }
            if k > 0, ref[k].first("print")?.attributes["new-system"] == "yes" {
              c.children.insert(XMLNode("print", attributes: ["new-system": "yes"]), at: 0)
            }
            if k > 0 { carryMeter(from: m, into: c) }
            let length = measureLength(m)
            if length > 0 {
              c.children.append(XMLNode("note", attributes: ["print-object": "no"], children: [
                XMLNode("rest"), XMLNode("duration", text: "\(length)"), XMLNode("voice", text: "1")]))
            }
            parts[i].children.append(c)
          }
        }
      }
    }
    first.children = first.children.filter { $0.tag != "part" } + parts
    if !title.isEmpty && first.first("work") == nil {
      first.children.insert(XMLNode("work", children: [XMLNode("work-title", text: title)]), at: 0)
    }
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
      "<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n" +
      first.serialized()
    return (ScoreValidityMusicXML.repaired(Data(xml.utf8)), labels.first ?? [])
  }

  /// A silent bar standing in for a part the page leaves out takes the page's meter and key changes from the bar
  /// it stands beside: kept in the page's opening meter, a 5/4 rest in a 4/4 bar is a bar MuseScore refuses.
  static func carryMeter(from m: XMLNode, into c: XMLNode) {
    let changes = m.all("attributes").flatMap { a in a.children.filter { $0.tag == "key" || $0.tag == "time" } }
    guard !changes.isEmpty else { return }
    let a = XMLNode("attributes", children: changes.map { x in
      let copy = x.copy()
      copy.attributes["id"] = nil      // XML ids stay unique
      return copy
    })
    let at = c.children.firstIndex { $0.tag != "print" } ?? c.children.count
    c.children.insert(a, at: at)
  }

  /// The meter a page's score ends in ("3/4"), to carry into the next page.
  static func lastMeter(_ xml: Data) -> String? {
    guard let root = try? XMLNode.parse(xml), let part = root.first("part") else { return nil }
    var meter: String?
    for m in part.all("measure") {
      for a in m.all("attributes") {
        // a meter written for one overfull bar is not the meter the music is in
        if let t = a.first("time"), !(t.attributes["id"] ?? "").hasPrefix(Copista.Tidy.overflowID),
           let b = t.first("beats")?.text, let bt = t.first("beat-type")?.text {
          meter = "\(b)/\(bt)"
        }
      }
    }
    return meter
  }

  /// How long a measure runs (in its divisions): the furthest any voice reaches.
  static func measureLength(_ m: XMLNode) -> Int {
    var cursor = 0, end = 0
    for c in m.children {
      let d = Int(c.first("duration")?.text ?? "") ?? 0
      switch c.tag {
      case "note" where c.first("chord") == nil && c.first("grace") == nil: cursor += d
      case "forward": cursor += d
      case "backup": cursor -= d
      default: break
      }
      end = max(end, cursor)
    }
    return end
  }
}
