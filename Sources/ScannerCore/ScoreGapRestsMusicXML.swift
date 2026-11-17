import Foundation

/// Give silent scanner gaps ordinary printed rests without moving the MusicXML cursor or adding time.
/// Run at the end of the validity guard; tuplet fillers and cursor-only moves stay untouched.
enum ScoreGapRestsMusicXML {
  typealias Q = Copista.Q
  struct Line: Hashable { let staff: String, voice: String }
  struct Span { let node: XMLNode, line: Line, start: Q, end: Q }
  struct Gap { let node: XMLNode, index: Int, start: Q, duration: Q }

  static func apply(_ data: Data) -> Data {
    guard let xml = String(data: data, encoding: .utf8) else { return data }
    return Data(apply(xml).utf8)
  }

  static func apply(_ xml: String) -> String {
    guard let root = try? XMLNode.parse(Data(xml.utf8)) else { return xml }
    var changed = false
    for part in root.all("part") {
      // The writer numbers voices across the staves (1 on the upper staff, 5 on the lower).
      var main: [String: String] = [:]
      for m in part.all("measure") {
        for n in m.children where n.tag == "note" || n.tag == "forward" {
          let staff = n.first("staff")?.text ?? "1"
          if let voice = n.first("voice")?.text, main[staff] == nil { main[staff] = voice }
        }
      }
      var divisions = 1, beats = 4, beatType = 4
      for m in part.all("measure") {
        for a in m.all("attributes") {
          if let d = Int(a.first("divisions")?.text ?? ""), d > 0 { divisions = d }
          if let t = a.first("time"), let b = Int(t.first("beats")?.text ?? ""), b > 0,
             let unit = Int(t.first("beat-type")?.text ?? ""), unit > 0 { beats = b; beatType = unit }
        }
        if show(m, divisions: divisions, beats: beats, beatType: beatType, main: main) { changed = true }
      }
    }
    guard changed else { return xml }
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()
  }

  static func show(_ m: XMLNode, divisions: Int, beats: Int, beatType: Int, main: [String: String]) -> Bool {
    let children = coalescedPadding(m.children)
    var cursor = Q.zero, reach = Q.zero, lastStart = Q.zero
    var spans: [Span] = [], gaps: [Gap] = [], occupiedStaffs = Set<String>()
    for (i, n) in children.enumerated() {
      let d = Q(Int(n.first("duration")?.text ?? "") ?? 0, divisions)
      switch n.tag {
      case "backup": cursor -= d
      case "forward":
        if d > .zero { gaps.append(Gap(node: n, index: i, start: cursor, duration: d)) }
        cursor += d
      case "note":
        let staff = n.first("staff")?.text ?? "1", voice = n.first("voice")?.text ?? main[staff] ?? "1"
        let grace = n.first("grace") != nil, chord = n.first("chord") != nil
        if !chord { lastStart = cursor }
        let start = chord ? lastStart : cursor
        if !grace && d > .zero {
          spans.append(Span(node: n, line: Line(staff: staff, voice: voice), start: start, end: start + d))
          reach = max(reach, start + d)
          if !chord { cursor += d }
        }
        if n.first("rest") == nil || n.attributes["print-object"] != "no" || n.first("time-modification") != nil {
          occupiedStaffs.insert(staff)
        }
        if !grace && !chord && n.first("rest") != nil && n.attributes["print-object"] == "no"
            && n.first("time-modification") == nil && d > .zero {
          gaps.append(Gap(node: n, index: i, start: start, duration: d))
        }
      default: break
      }
      reach = max(reach, cursor)
    }
    let nominal = Q(beats * 4, beatType)
    let compound = beatType >= 8 && beats > 3 && beats % 3 == 0
    let beat = Q(compound ? 12 : 4, beatType)
    var replacements: [Int: [XMLNode]] = [:]
    for gap in gaps {
      let n = gap.node
      // A voice-less gap Tidy inserted inherits the staff of its surrounding voice run. A backup
      // ends that run; never infer from the next staff/voice after the backup.
      var staff = n.first("staff")?.text
      if staff == nil {
        for c in children.dropFirst(gap.index + 1) {
          if c.tag == "backup" { break }
          if c.tag == "note" || c.tag == "forward", let s = c.first("staff")?.text { staff = s; break }
        }
      }
      if staff == nil {
        for c in children[..<gap.index].reversed() {
          if c.tag == "backup" { break }
          if c.tag == "note" || c.tag == "forward", let s = c.first("staff")?.text { staff = s; break }
        }
      }
      let st = staff ?? "1", voice = n.first("voice")?.text ?? main[st] ?? "1"
      let line = Line(staff: st, voice: voice), end = gap.start + gap.duration
      // Forwards also position attributes or another voice. Printing these as rests would overlap
      // music already present in the main voice and make the validity guard rewrite real notes.
      guard gap.start >= .zero, !spans.contains(where: {
        $0.node !== n && $0.line == line && $0.start < end && gap.start < $0.end
      }) else { continue }
      // A forward following an outgoing tie is not necessarily silent: MuseScore sustains the
      // tied note across it, even when its continuation changes voice. An explicit rest would
      // break that tie. Leave this cursor move alone rather than change sounding playback.
      if n.tag == "forward" {
        let preceding = spans.filter { $0.line == line && $0.end <= gap.start }
        if let last = preceding.map(\.start).max(), preceding.contains(where: {
          $0.start == last && ($0.node.all("tie").contains { $0.attributes["type"] == "start" }
            || $0.node.first("notations")?.all("tied").contains { $0.attributes["type"] == "start" } == true)
        }) { continue }
      }
      let whole = gap.start == .zero && gap.duration == nominal && reach == nominal
        && !occupiedStaffs.contains(st)
      let values: [(Q, String)]
      if whole { values = [(gap.duration, "")] }
      else {
        guard let split = Self.values(gap.duration, at: gap.start, beat: beat, divisions: divisions, compound: compound) else { continue }
        values = split
      }
      replacements[gap.index] = values.enumerated().map { i, value in
        let rest: XMLNode
        if n.tag == "note" && i == 0 {
          rest = n.copy()
          rest.attributes["print-object"] = nil
          rest.attributes["print-spacing"] = nil
          rest.children.removeAll { ["duration", "voice", "type", "dot", "staff"].contains($0.tag) }
          rest.first("rest")?.attributes["measure"] = nil
        } else { rest = XMLNode("note", children: [XMLNode("rest")]) }
        if whole { rest.first("rest")?.attributes["measure"] = "yes" }
        rest.children.append(XMLNode("duration", text: String((value.0 * Q(divisions)).n)))
        rest.children.append(XMLNode("voice", text: voice))
        if !value.1.isEmpty {
          rest.children.append(XMLNode("type", text: value.1))
          if compound && value.0 == beat && !ScoreValidityMusicXML.types.contains(where: { $0.1 == beat }) {
            rest.children.append(XMLNode("dot"))
          }
        }
        if n.first("staff") != nil || st != "1" || main.count > 1 { rest.children.append(XMLNode("staff", text: st)) }
        ScoreValidityMusicXML.orderNote(rest)
        return rest
      }
    }
    guard !replacements.isEmpty else { return false }
    m.children = children.enumerated().flatMap { replacements[$0.offset] ?? [$0.element] }
    return true
  }

  /// The guard can spell an empty staff as several anonymous hidden rests. Join adjacent
  /// padding before engraving it, so the empty staff receives one measure rest. Recognized IDs,
  /// lyrics, directions, visible rests and tuplet fillers are never folded into this run.
  static func coalescedPadding(_ children: [XMLNode]) -> [XMLNode] {
    func padding(_ n: XMLNode) -> Bool {
      n.tag == "note" && n.attributes["print-object"] == "no" && n.attributes["id"] == nil
        && n.attributes.keys.allSatisfy { ["print-object", "print-spacing"].contains($0) }
        && n.first("rest") != nil && n.first("rest")!.children.isEmpty
        && n.children.allSatisfy { ["rest", "duration", "voice", "type", "dot", "staff"].contains($0.tag) }
        && (Int(n.first("duration")?.text ?? "") ?? 0) > 0
    }
    var out: [XMLNode] = [], i = 0
    while i < children.count {
      let n = children[i]
      guard padding(n) else { out.append(n); i += 1; continue }
      var j = i + 1, total = Int(n.first("duration")!.text)!
      while j < children.count && padding(children[j])
        && children[j].first("voice")?.text == n.first("voice")?.text
        && children[j].first("staff")?.text == n.first("staff")?.text {
        total += Int(children[j].first("duration")!.text)!; j += 1
      }
      if j > i + 1 {
        let combined = n.copy()
        combined.first("duration")!.text = String(total)
        out.append(combined)
      } else { out.append(n) }
      i = j
    }
    return out
  }

  /// Split at meter beats and aligned subdivisions; plain longer rests can cover aligned whole beats.
  /// Use only values exact in the existing divisions.
  /// A dotted compound beat (6/8, 9/8, ...) is one beat; ordinary beats do not acquire dotted rests.
  static func values(_ duration: Q, at start: Q, beat: Q, divisions: Int, compound: Bool) -> [(Q, String)]? {
    guard ScoreValidityMusicXML.plain(duration), start >= .zero, beat > .zero else { return nil }
    var pos = start, remaining = duration, out: [(Q, String)] = []
    while remaining > .zero {
      let beatNumber = pos / beat
      let next = beat * Q(beatNumber.n / beatNumber.d + 1)
      let available = min(remaining, next - pos)
      let value: (Q, String)?
      if let long = ScoreValidityMusicXML.types.first(where: {
        $0.1 > beat && $0.1 <= remaining && ($0.1 / beat).d == 1
          && (pos / $0.1).d == 1 && ($0.1 * Q(divisions)).d == 1
      }) {
        value = (long.1, long.0)
      } else if compound && available == beat && (pos / beat).d == 1,
         let base = ScoreValidityMusicXML.types.first(where: { $0.1 * Q(3, 2) == beat }) {
        value = (beat, base.0)
      } else {
        value = ScoreValidityMusicXML.types.first(where: {
          $0.1 <= available && (pos / $0.1).d == 1 && ($0.1 * Q(divisions)).d == 1
        }).map { ($0.1, $0.0) }
      }
      guard let value, (value.0 * Q(divisions)).d == 1 else { return nil }
      out.append(value); pos += value.0; remaining -= value.0
    }
    return out
  }
}
