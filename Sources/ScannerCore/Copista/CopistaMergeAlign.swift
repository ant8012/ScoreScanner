import Foundation

/// Pages of a large score that hide the staves of resting instruments: each page shows a different set of parts.
/// Joined part by part in order, an instrument would land in another's part at every page turn. Instead each page's
/// parts are matched in score order to the parts seen so far, by their staves, clefs and printed names; a part with
/// no match is a new part, silent on the pages before it.
extension CopistaMerge {
  struct PartSignature {
    var staves: Int
    /// The clef signs of the part's opening staves, top down ("GF" for a piano).
    var clefs: String
    /// The instrument its printed name stands for, when the name is known.
    var family: String?
    /// The part's number in its name ("Cl. 2" → "2", "Vln. II" → "2").
    var number: String?
    var label: String
    /// Where it sits on its page, from the top part (0) to the bottom one (1): an orchestra keeps its score order.
    var rank = 0.0
  }

  static func signature(_ part: XMLNode, label: String) -> PartSignature {
    // the first bar's attributes; the clefs where the part first shows them (a part missing from a page's first
    // system opens with none)
    let attributes = part.first("measure")?.all("attributes") ?? []
    let staves = attributes.compactMap { Int($0.first("staves")?.text ?? "") }.first ?? 1
    let withClefs = part.all("measure").lazy.flatMap { $0.all("attributes") }.first { !$0.all("clef").isEmpty }
    let clefs = (withClefs?.all("clef") ?? [])
      .sorted { Int($0.attributes["number"] ?? "1") ?? 1 < Int($1.attributes["number"] ?? "1") ?? 1 }
      .map { String(($0.first("sign")?.text ?? "?").prefix(1)) }.joined()
    let trimmed = label.trimmingCharacters(in: .whitespaces)
    var family: String?
    if let m = InstrumentSounds.match(long: trimmed, short: "") {
      // the instrument, without its key or size: "Clarinet in A" and "Cl." are one family
      family = m.sound.split(separator: ".").prefix(3).joined(separator: ".")
    } else if let sound = InstrumentSounds.nearest(trimmed) {
      family = sound.split(separator: ".").prefix(3).joined(separator: ".")
    }
    let words = InstrumentSounds.key(trimmed).split(separator: " ").map(String.init)
    let roman = ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6"]
    var number: String?
    if words.count > 1, let w = words.last { number = Int(w) != nil ? w : roman[w] }
    return PartSignature(staves: staves, clefs: clefs, family: family, number: number, label: trimmed)
  }

  /// Every page has the same parts in the same order (or the first parts of it): joined part by part, as always.
  static func samePartsThroughout(_ sigs: [[PartSignature]]) -> Bool {
    guard let first = sigs.first else { return true }
    for page in sigs.dropFirst() {
      if page.count > first.count { return false }
      for (a, b) in zip(first, page) where a.staves != b.staves || (!a.clefs.isEmpty && !b.clefs.isEmpty && a.clefs != b.clefs) {
        return false
      }
      if page.count < first.count { return false }
    }
    return true
  }

  /// How well a page's part fits a part of the score: below zero, not at all.
  static func fit(_ a: PartSignature, _ b: PartSignature) -> Double {
    var v = 0.0
    let sameFamily = a.family != nil && a.family == b.family
    if a.staves != b.staves {
      // one instrument on one staff here and divided onto two there (divisi strings, a pair of wind players): its
      // clefs start alike
      let (short, long) = a.clefs.count <= b.clefs.count ? (a.clefs, b.clefs) : (b.clefs, a.clefs)
      guard sameFamily || (!short.isEmpty && long.hasPrefix(short)) else { return -.infinity }
      v -= 0.5
    } else if !a.clefs.isEmpty && !b.clefs.isEmpty {
      if a.clefs == b.clefs { v += 2 } else if a.clefs.first == b.clefs.first { v += 0.5 } else { v -= 2 }
    }
    if let fa = a.family, let fb = b.family { v += fa == fb ? 4 : -6 }
    if let na = a.number, let nb = b.number, a.family != nil, a.family == b.family { v += na == nb ? 1 : -2 }
    // where it sits in its system, from the top: an orchestra keeps its score order
    v += 1.5 - 4 * abs(a.rank - b.rank)
    return v
  }

  /// For each of a page's parts, the score part it continues (nil: a new part). Matches keep their order.
  static func alignParts(_ score: [PartSignature], _ page: [PartSignature]) -> [Int?] {
    let n = score.count, m = page.count
    var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
    var move = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)   // 0 match, 1 skip score, 2 skip page
    for i in 0...n { for j in 0...m {
      if i == 0 && j == 0 { continue }
      var v = -Double.infinity, mv = 0
      if i > 0 && j > 0 {
        let f = fit(score[i - 1], page[j - 1])
        if f > 0 && best[i - 1][j - 1] + f > v { v = best[i - 1][j - 1] + f; mv = 0 }
      }
      if i > 0 && best[i - 1][j] > v { v = best[i - 1][j]; mv = 1 }
      if j > 0 && best[i][j - 1] > v { v = best[i][j - 1]; mv = 2 }
      best[i][j] = v; move[i][j] = mv
    } }
    var out = [Int?](repeating: nil, count: m)
    var i = n, j = m
    while i > 0 || j > 0 {
      switch move[i][j] {
      case 0: out[j - 1] = i - 1; i -= 1; j -= 1
      case 1: i -= 1
      default: j -= 1
      }
    }
    return out
  }

  static func aligned(_ roots: [XMLNode], _ sigs: [[PartSignature]], title: String) throws -> (xml: Data, labels: [String]) {
    // the score's parts, in order, each with the page part it was last seen as
    var order: [Int] = []                     // part ids in score order
    var seen: [Int: PartSignature] = [:]
    var firstSeen: [Int: (page: Int, part: Int)] = [:]
    var maps: [[Int?]] = []                   // per page: its part -> part id
    var next = 0
    for (p, page) in sigs.enumerated() {
      // a page of one unnamed part is the top line going on, whatever its clef (a lead sheet's bass line); the
      // part keeps the clefs it is known by
      let lone = p > 0 && page.count == 1 && page[0].family == nil && page[0].staves <= seen[order[0]]!.staves
      let found = p == 0 ? [Int?](repeating: nil, count: page.count)
        : lone ? [0] : alignParts(order.map { seen[$0]! }, page)
      var map = [Int?](repeating: nil, count: page.count)
      let matched = found.map { $0.map { order[$0] } }   // before new parts shift the order
      var at = 0                              // insert new parts after the last matched one
      for (k, sig) in page.enumerated() {
        if let id = matched[k] {
          map[k] = id
          var s = sig
          if seen[id]!.staves > s.staves || lone { s.staves = seen[id]!.staves; s.clefs = seen[id]!.clefs }
          if s.family == nil { s.family = seen[id]!.family; s.number = seen[id]!.number }
          if s.label.isEmpty { s.label = seen[id]!.label }
          seen[id] = s
          at = order.firstIndex(of: id)! + 1
        } else {
          let id = next
          next += 1
          order.insert(id, at: at)
          at += 1
          seen[id] = sig
          firstSeen[id] = (p, k)
          map[k] = id
        }
      }
      maps.append(map)
    }
    let first = roots[0]
    let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let partCount = order.count
    // part list: each part's entry from the page it first appears on, renumbered
    let plist = XMLNode("part-list")
    var labels: [String] = []
    for (n, id) in order.enumerated() {
      let (p, k) = firstSeen[id]!
      let entry = roots[p].first("part-list")?.all("score-part")[safe: k]?.copy() ?? XMLNode("score-part")
      let old = entry.attributes["id"] ?? ""
      renameIDs(entry, from: old, to: "P\(n + 1)")
      entry.attributes["id"] = "P\(n + 1)"
      if entry.first("part-name") == nil {
        entry.children.insert(XMLNode("part-name", text: "Part \(n + 1)", attributes: ["print-object": "no"]), at: 0)
      } else if (entry.first("part-name")?.attributes["print-object"]) == "no" {
        entry.first("part-name")?.text = "Part \(n + 1)"
      }
      plist.children.append(entry)
      labels.append(seen[id]?.label ?? "")
    }
    let parts = (0..<partCount).map { XMLNode("part", attributes: ["id": "P\($0 + 1)"]) }
    var numbers = [Int](repeating: 0, count: partCount)
    // a part's opening attributes (staves and clefs) from its first page, for the silence before it
    var widest: [Int: (page: Int, part: Int, staves: Int)] = [:]
    for (p, map) in maps.enumerated() {
      for (k, id) in map.enumerated() {
        guard let id else { continue }
        let n = sigs[p][k].staves
        if widest[id] == nil || n > widest[id]!.staves { widest[id] = (p, k, n) }
      }
    }
    let opening: [Int: XMLNode] = Dictionary(uniqueKeysWithValues: order.map { id in
      let (p, k, _) = widest[id]!
      return (id, roots[p].all("part")[k].first("measure")?.first("attributes") ?? XMLNode("attributes"))
    })
    let staffCount: [Int: Int] = widest.mapValues(\.staves)
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
      func turn(_ m: XMLNode) {
        guard pageIndex > 0 else { return }
        m.children.removeAll { $0.tag == "print" }
        m.children.insert(XMLNode("print", attributes: ["new-system": "yes"]), at: 0)
      }
      let ref = pageParts.first?.all("measure") ?? []
      let refAttributes = ref.first?.first("attributes")
      let divisions = refAttributes?.first("divisions")?.text ?? "1"
      var source: [Int: XMLNode] = [:]
      for (k, id) in maps[pageIndex].enumerated() { if let id { source[index[id]!] = pageParts[k] } }
      for i in 0..<partCount {
        if let part = source[i] {
          let wide = staffCount[order[i]] ?? 1
          for (k, m) in part.all("measure").enumerated() {
            let c = m.copy()
            if k == 0 { turn(c) }
            if k == 0 && numbers[i] == 0 && wide > 1, let a = c.first("attributes"), a.first("staves") == nil {
              // the part's first bar, on a page that shows only its first staff: the score opens all its staves
              let own = opening[order[i]]!
              var at = a.children.lastIndex { ["divisions", "key", "time"].contains($0.tag) }.map { $0 + 1 } ?? 0
              a.children.insert(XMLNode("staves", text: "\(wide)"), at: at)
              at += 1
              for x in own.all("clef") where (x.attributes["number"] ?? "1") != "1" {
                a.children.insert(x.copy(), at: a.children.lastIndex { $0.tag == "clef" }.map { $0 + 1 } ?? at)
              }
            }
            numbers[i] += 1
            c.attributes["number"] = "\(numbers[i])"
            if numbers[i] > 1 { c.attributes["implicit"] = nil }
            parts[i].children.append(c)
          }
        } else {
          for (k, m) in ref.enumerated() {
            numbers[i] += 1
            let c = XMLNode("measure", attributes: ["number": "\(numbers[i])"])
            if k == 0 {
              let a = XMLNode("attributes", children: [XMLNode("divisions", text: divisions)])
              if numbers[i] == 1 {
                // the part's first bar in the score: its key and meter from the page, its staves and clefs its own
                for tag in ["key", "time"] { if let x = refAttributes?.first(tag) { a.children.append(x.copy()) } }
                let own = opening[order[i]]!
                for tag in ["staves", "clef"] { for x in own.all(tag) { a.children.append(x.copy()) } }
              }
              c.children.append(a)
              turn(c)
            }
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
    first.children = first.children.filter { $0.tag != "part" && $0.tag != "part-list" }
    let at = first.children.firstIndex { !["work", "movement-number", "movement-title", "identification", "defaults",
                                           "credit"].contains($0.tag) } ?? first.children.count
    first.children.insert(plist, at: at)
    dropRestated(parts)
    first.children += parts
    if !title.isEmpty && first.first("work") == nil {
      first.children.insert(XMLNode("work", children: [XMLNode("work-title", text: title)]), at: 0)
    }
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
      "<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n" +
      first.serialized()
    return (ScoreValidityMusicXML.repaired(Data(xml.utf8)), labels)
  }

  /// IDs inside a part's entry ("P3-I1") follow its new number.
  static func renameIDs(_ node: XMLNode, from old: String, to new: String) {
    guard !old.isEmpty else { return }
    for (k, v) in node.attributes where v.hasPrefix(old + "-") { node.attributes[k] = new + v.dropFirst(old.count) }
    for c in node.children { renameIDs(c, from: old, to: new) }
  }
}

private extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
