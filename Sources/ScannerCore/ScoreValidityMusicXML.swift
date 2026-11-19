import Foundation

/// Last, deterministic serialization guard. This does not choose a different model reading: pitches, onsets
/// and sounding lengths survive. Bad tuplets are respelled, missing time gets rests, and an overfull bar keeps
/// its music under an explicit "check bar" meter. `apply` throws rather than return an unchecked repair; the
/// scanner calls `repaired`, which keeps the score as written when a repair cannot finish, so a scan never fails
/// here.
enum ScoreValidityMusicXML {
  typealias Q = Copista.Q
  struct Key: Hashable, Comparable {
    let staff: String, voice: String
    static func < (a: Key, b: Key) -> Bool {
      a.staff == b.staff ? a.voice < b.voice : a.staff < b.staff
    }
  }
  struct Group {
    var start: Q, duration: Q, nodes: [XMLNode]
    var end: Q { start + duration }
  }
  struct Bar {
    let node: XMLNode, divisions: Int, meter: (Int, Int)
    var lines: [Key: [Group]], metadata: [(Q, XMLNode)], reach: Q
  }
  static let types: [(String, Q)] = [
    ("maxima", Q(32)), ("long", Q(16)), ("breve", Q(8)), ("whole", Q(4)), ("half", Q(2)),
    ("quarter", Q(1)), ("eighth", Q(1, 2)), ("16th", Q(1, 4)), ("32nd", Q(1, 8)),
    ("64th", Q(1, 16)), ("128th", Q(1, 32)), ("256th", Q(1, 64)), ("512th", Q(1, 128)),
    ("1024th", Q(1, 256))]
  static func power2(_ n: Int) -> Bool { n > 0 && n & (n - 1) == 0 }
  static func unit(_ q: Q) -> Bool { power2(q.n) && power2(q.d) }
  static func plain(_ q: Q) -> Bool { q >= .zero && power2(q.d) }
  static func ratio(_ n: XMLNode) -> Q {
    guard let t = n.first("time-modification"), let a = Int(t.first("actual-notes")?.text ?? ""),
          let b = Int(t.first("normal-notes")?.text ?? ""), a > 0, b > 0 else { return Q(1) }
    return Q(b, a)
  }
  static func written(_ n: XMLNode) -> Q {
    let base = types.first { $0.0 == n.first("type")?.text }?.1 ?? .zero
    return base * (Q(2) - Q(1, 1 << min(n.all("dot").count, 8)))
  }
  static func marks(_ n: XMLNode, _ kind: String) -> Bool {
    n.first("notations")?.all("tuplet").contains { $0.attributes["type"] == kind } ?? false
  }
  static func remove(_ node: XMLNode, _ tags: Set<String>) { node.children.removeAll { tags.contains($0.tag) } }
  static func set(_ node: XMLNode, _ tag: String, _ value: String) {
    if let c = node.first(tag) { c.text = value } else { node.children.append(XMLNode(tag, text: value)) }
  }
  static func ticks(_ q: Q, _ divisions: Int) throws -> String {
    let t = q * Q(divisions)
    guard t.d == 1 else { throw ScannerError.invalid("MusicXML validity: unrepresentable duration \(q)") }
    return String(t.n)
  }
  static func orderNote(_ n: XMLNode) {
    let keys = ["grace", "cue", "chord", "pitch", "unpitched", "rest", "duration", "tie", "instrument",
      "footnote", "level", "voice", "type", "dot", "accidental", "time-modification", "stem", "notehead",
      "notehead-text", "staff", "beam", "notations", "lyric", "play", "listen"]
    n.children = n.children.enumerated().sorted {
      let a = keys.firstIndex(of: $0.element.tag) ?? 999, b = keys.firstIndex(of: $1.element.tag) ?? 999
      return a == b ? $0.offset < $1.offset : a < b
    }.map(\.element)
  }
  static func parse(_ m: XMLNode, divisions: Int, meter: (Int, Int)) throws -> Bar {
    var cursor = Q.zero, reach = Q.zero, lines: [Key: [Group]] = [:], metadata: [(Q, XMLNode)] = []
    var last: (Key, Int)?
    for c in m.children {
      let duration = Q(try c.duration(), divisions)
      switch c.tag {
      case "backup": cursor -= duration
      case "forward": cursor += duration
      case "note":
        if c.first("chord") != nil, let (k, i) = last {
          lines[k]![i].nodes.append(c)
          reach = max(reach, lines[k]![i].start + duration)
        } else {
          let key = Key(staff: c.first("staff")?.text ?? "1", voice: c.first("voice")?.text ?? "1")
          let d = c.first("grace") == nil ? duration : .zero
          lines[key, default: []].append(Group(start: cursor, duration: d, nodes: [c]))
          last = (key, lines[key]!.count - 1); cursor += d
        }
      default: metadata.append((cursor, c))
      }
      reach = max(reach, cursor)
    }
    return Bar(node: m, divisions: divisions, meter: meter, lines: lines, metadata: metadata, reach: reach)
  }

  /// MuseScore closes a tuplet using its *raw* normal count and an undotted normal unit. Merely balancing
  /// start/stop tags is insufficient: partial 6:4 groups and dotted inferred units grow on import.
  static func validTuplet(_ groups: [Group], divisions: Int) -> Bool {
    guard let first = groups.first, let tm = first.nodes[0].first("time-modification"),
          let normal = Int(tm.first("normal-notes")?.text ?? ""), normal > 0,
          let actual = Int(tm.first("actual-notes")?.text ?? ""), actual > 0 else { return false }
    let r = ratio(first.nodes[0]); var pos = first.start, total = Q.zero, smallest: Q?
    for g in groups where g.duration > .zero {
      guard g.start == pos, ratio(g.nodes[0]) == r else { return false }
      for n in g.nodes where n.first("grace") == nil {
        guard written(n) * ratio(n) == Q((try? n.duration()) ?? 0, divisions) else { return false }
      }
      total += g.duration; pos += g.duration
      let q = written(g.nodes[0]); guard q > .zero else { return false }
      let small = Q(1, q.d)
      smallest = min(smallest ?? small, small)
    }
    let base = total / Q(normal)
    guard unit(base) else { return false }
    if let nt = tm.first("normal-type") {
      guard types.first(where: { $0.0 == nt.text })?.1 == base else { return false }
      smallest = base
    }
    guard let small = smallest else { return false }
    return total / r / small >= Q(actual)
  }

  static func failures(_ groups: [Group], length: Q, divisions: Int) -> [String] {
    var out = Set<String>(), pos = Q.zero, run: [Group] = []
    for g in groups.sorted(by: { $0.start < $1.start }) {
      if g.duration <= .zero {
        if g.nodes.contains(where: { $0.first("grace") == nil }) { out.insert("nonpositive note duration") }
        continue
      }
      if g.start < pos { out.insert("overlapping voice") }
      if !plain(g.start - pos) || (g.start > pos && g.start - pos < Q(1, 32)) { out.insert("gap needs explicit rests") }
      if g.start < .zero || g.end > length { out.insert("voice outside bar") }
      pos = max(pos, g.end)
      for n in g.nodes where n.first("grace") == nil {
        if Q((try? n.duration()) ?? 0, divisions) != g.duration { out.insert("unequal chord durations") }
        let wholeRest = n.first("rest") != nil && g.duration == length &&
          (n.first("rest")?.attributes["measure"] == "yes" || n.first("type") == nil || n.first("type")?.text == "whole")
        if !wholeRest && written(n) * ratio(n) != Q((try? n.duration()) ?? 0, divisions) {
          out.insert("duration disagrees with note value")
        }
      }
      let n = g.nodes[0]
      if marks(n, "start") && !run.isEmpty { out.insert("restarted tuplet"); run = [] }
      if n.first("time-modification") != nil { run.append(g) }
      else if !run.isEmpty { out.insert("unclosed tuplet"); run = [] }
      if marks(n, "stop") {
        if !validTuplet(run, divisions: divisions) { out.insert("incomplete tuplet") }
        run = []
      }
    }
    if !run.isEmpty { out.insert("unclosed tuplet") }
    if !plain(length - pos) || (length > pos && length - pos < Q(1, 32)) { out.insert("tail needs explicit rests") }
    return out.sorted()
  }
  static func rest(_ duration: Q, at: Q) -> Group {
    Group(start: at, duration: duration,
          nodes: [XMLNode("note", attributes: ["print-object": "no"], children: [XMLNode("rest")])])
  }
  static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
  static func lcm(_ a: Int, _ b: Int) -> Int { a / gcd(a, b) * b }

  /// Retain external ties only at the appropriate end of a split; all intermediate pieces are continuations.
  static func piece(_ original: XMLNode, index: Int, count: Int) -> XMLNode {
    let n = original.copy()
    if count > 1 {
      if index > 0 { n.attributes["id"] = nil; remove(n, ["lyric", "accidental"]) }
      let start = original.all("tie").contains { $0.attributes["type"] == "start" }
      let stop = original.all("tie").contains { $0.attributes["type"] == "stop" }
      remove(n, ["tie"])
      if let nt = n.first("notations") {
        nt.children.removeAll { $0.tag == "tied" || (index > 0 && $0.tag != "tuplet") }
      }
      if n.first("rest") == nil {
        for t in [("stop", index > 0 || stop), ("start", index + 1 < count || start)] where t.1 {
          n.children.append(XMLNode("tie", attributes: ["type": t.0]))
          if n.first("notations") == nil { n.children.append(XMLNode("notations")) }
          n.first("notations")!.children.append(XMLNode("tied", attributes: ["type": t.0]))
        }
      }
    }
    return n
  }
  static func values(_ duration: Q) throws -> [(Q, String, Int)] {
    let options = types.flatMap { t in (0...2).map { (t.1 * (Q(2) - Q(1, 1 << $0)), t.0, $0) } }
      .sorted { $0.0 > $1.0 }
    var remaining = duration, out: [(Q, String, Int)] = []
    while remaining > .zero {
      guard let v = options.first(where: { $0.0 <= remaining }) else {
        throw ScannerError.invalid("MusicXML validity: note shorter than 1024th")
      }
      out.append(v); remaining -= v.0
    }
    return out
  }
  static func render(_ atoms: [Group], key: Key, divisions: Int, ratio r: Q = Q(1)) throws -> [XMLNode] {
    var actual = r.d, normal = r.n, base = atoms.reduce(Q.zero) { $0 + $1.duration } / Q(r.n)
    var normalType = "quarter"
    if r != Q(1) {
      var multiplier = base.n
      while multiplier > 0 && multiplier % 2 == 0 { multiplier /= 2 }
      actual *= multiplier; normal *= multiplier; base = base / Q(multiplier)
      guard let typ = types.first(where: { $0.1 == base })?.0 else {
        throw ScannerError.invalid("MusicXML validity: unsupported tuplet unit \(base)")
      }
      normalType = typ
    }
    var out: [XMLNode] = []
    for g in atoms {
      if g.duration == .zero {
        for original in g.nodes {
          let n = original.copy(); set(n, "voice", key.voice); set(n, "staff", key.staff); orderNote(n); out.append(n)
        }
        continue
      }
      let pieces = try values(g.duration / r)
      for (j, v) in pieces.enumerated() {
        for (k, orig) in g.nodes.enumerated() {
          if orig.first("grace") != nil {
            if j == 0 {
              let n = orig.copy(); set(n, "voice", key.voice); set(n, "staff", key.staff); orderNote(n); out.append(n)
            }
            continue
          }
          let n = piece(orig, index: j, count: pieces.count)
          remove(n, ["type", "dot", "time-modification", "beam", "chord"])
          n.first("rest")?.attributes["measure"] = nil
          if k > 0 { n.children.append(XMLNode("chord")) }
          set(n, "duration", try ticks(v.0 * r, divisions)); set(n, "type", v.1)
          set(n, "voice", key.voice); set(n, "staff", key.staff)
          for _ in 0..<v.2 { n.children.append(XMLNode("dot")) }
          if let nt = n.first("notations") { remove(nt, ["tuplet"]) }
          if r != Q(1) {
            n.children.append(XMLNode("time-modification", children: [
              XMLNode("actual-notes", text: String(actual)), XMLNode("normal-notes", text: String(normal)),
              XMLNode("normal-type", text: normalType)]))
          }
          orderNote(n); out.append(n)
        }
      }
    }
    if r != Q(1) {
      let heads = out.filter { $0.first("chord") == nil && $0.first("grace") == nil }
      if let first = heads.first, let last = heads.last {
        for (n, kind) in [(first, "start"), (last, "stop")] {
          if n.first("notations") == nil { n.children.append(XMLNode("notations")) }
          n.first("notations")!.children.append(XMLNode("tuplet", attributes: ["type": kind]))
        }
      }
    }
    for n in out { orderNote(n) }
    return out
  }

  static func canonical(_ groups: [Group], length: Q, oldDivisions: Int, divisions: Int, key: Key) throws -> [XMLNode] {
    var atoms: [Group] = [], pos = Q.zero
    for g in groups.sorted(by: { $0.start < $1.start }) {
      guard g.start >= pos || g.duration == .zero else {
        throw ScannerError.invalid("MusicXML validity: voice packing failed")
      }
      if g.start > pos { atoms.append(rest(g.start - pos, at: pos)) }
      atoms.append(g); pos = max(pos, g.end)
    }
    if length > pos { atoms.append(rest(length - pos, at: pos)) }
    var denominator = 1
    for g in atoms {
      var odd = g.duration.d
      while odd % 2 == 0 { odd /= 2 }
      denominator = lcm(denominator, odd)
    }
    var numerator = 1
    while numerator * 2 < denominator { numerator *= 2 }
    let r = Q(numerator, denominator)
    var blocks: [Int: Int] = [:]
    for (i, g) in atoms.enumerated() where marks(g.nodes[0], "start") {
      if let end = (i..<atoms.count).first(where: { marks(atoms[$0].nodes[0], "stop") }),
         validTuplet(Array(atoms[i...end]), divisions: oldDivisions) { blocks[i] = end }
    }
    var out: [XMLNode] = [], pending: [Group] = [], total = Q.zero, skip = -1
    for (i, g) in atoms.enumerated() {
      if i <= skip { continue }
      if pending.isEmpty, let end = blocks[i] {
        skip = end
        for keep in atoms[i...end] {
          for orig in keep.nodes {
            let n = orig.copy()
            if n.first("grace") == nil { set(n, "duration", try ticks(keep.duration, divisions)) }
            set(n, "voice", key.voice); set(n, "staff", key.staff); orderNote(n); out.append(n)
          }
        }
      } else if pending.isEmpty && plain(g.duration) {
        if g.duration > .zero && g.nodes.allSatisfy({ $0.first("time-modification") == nil && written($0) == g.duration }) {
          for (j, original) in g.nodes.enumerated() {
            let n = original.copy(); remove(n, ["chord"])
            if j > 0 { n.children.append(XMLNode("chord")) }
            if n.first("grace") == nil { set(n, "duration", try ticks(g.duration, divisions)) }
            set(n, "voice", key.voice); set(n, "staff", key.staff)
            orderNote(n); out.append(n)
          }
        } else { out += try render([g], key: key, divisions: divisions) }
      } else {
        pending.append(g); total += g.duration
        if unit(total / Q(r.n)) {
          out += try render(pending, key: key, divisions: divisions, ratio: r); pending = []; total = .zero
        }
      }
    }
    if !pending.isEmpty { out += try render(pending, key: key, divisions: divisions, ratio: r) }
    return out
  }

  /// Unequal chord members need independent voices. If interval packing really needs a fifth voice,
  /// tied chord slices retain all simultaneous pitches and their original sounding lengths in one voice.
  static func pack(_ lines: [Key: [Group]], divisions: Int) throws -> [Key: [Group]] {
    var result = lines, extras: [(String, Group)] = []
    for (key, groups) in lines {
      result[key] = groups.map { g in
        var root = g
        root.nodes = g.nodes.enumerated().compactMap { i, n in
          let d = Q((try? n.duration()) ?? 0, divisions)
          if i > 0 && d != g.duration && n.first("grace") == nil {
            extras.append((key.staff, Group(start: g.start, duration: d, nodes: [n]))); return nil
          }
          return n
        }
        return root
      }
    }
    for (staff, g) in extras {
      let keys = result.keys.filter { $0.staff == staff }.sorted()
      let target = keys.first { k in result[k]!.allSatisfy { $0.end <= g.start || g.end <= $0.start } }
        ?? Key(staff: staff, voice: String((result.keys.compactMap { Int($0.voice) }.max() ?? 0) + 1))
      result[target, default: []].append(g)
    }
    for staff in Set(result.keys.map(\.staff)).sorted() {
      let keys = result.keys.filter { $0.staff == staff }.sorted()
      let overlapping = keys.contains { key in
        var pos = Q.zero
        for g in result[key]!.sorted(by: { $0.start < $1.start }) where g.duration > .zero {
          if g.start < pos { return true }; pos = g.end
        }
        return false
      }
      guard keys.count > 4 || overlapping else { continue }
      let all = keys.flatMap { result[$0]! }, sounded = all.filter { $0.duration > .zero }
      let boundaries = Set(sounded.flatMap { [$0.start, $0.end] }).sorted()
      var flattened: [Group] = []
      for i in 0..<max(0, boundaries.count - 1) {
        let a = boundaries[i], b = boundaries[i + 1]
        let active = sounded.filter { $0.start <= a && $0.end >= b }
        var nodes: [XMLNode] = []
        for g in active {
          let cuts = boundaries.filter { $0 >= g.start && $0 <= g.end }
          let index = cuts.firstIndex(of: a)!
          for n in g.nodes where n.first("rest") == nil {
            let copy = piece(n, index: index, count: cuts.count - 1)
            set(copy, "duration", try ticks(b - a, divisions)); nodes.append(copy)
          }
        }
        if nodes.isEmpty { flattened.append(rest(b - a, at: a)) }
        else { flattened.append(Group(start: a, duration: b - a, nodes: nodes)) }
      }
      flattened += all.filter { $0.duration == .zero }
      for key in keys { result[key] = nil }
      result[keys[0]] = flattened
    }
    return result
  }

  static func repair(_ bar: Bar, length: Q, resize: Bool) throws {
    // Extra resolution permits tied plain values and exact tuplet rests without decimal divisions.
    let div = bar.divisions * 256
    guard div > 0 && div < 100_000_000 else { throw ScannerError.invalid("MusicXML validity: divisions too large") }
    let lines = try pack(bar.lines, divisions: bar.divisions)
    var prefix: [XMLNode] = [], tail: [XMLNode] = []
    for (pos, original) in bar.metadata {
      let c = original.copy()
      if c.tag == "barline" { if c.attributes["location"] == "left" { prefix.append(c) } else { tail.append(c) }; continue }
      if c.tag == "direction" || c.tag == "harmony" {
        let off = Q(Int(c.first("offset")?.text ?? "0") ?? 0, bar.divisions)
        var at = pos + off
        if at < .zero || at > length { at = off >= .zero && off <= length ? off : min(max(at, .zero), length) }
        remove(c, ["offset"])
        if at != .zero {
          let tags: Set<String> = c.tag == "harmony" ? ["footnote", "level", "staff"] : ["footnote", "level", "voice", "staff", "sound", "listening"]
          let index = c.children.firstIndex { tags.contains($0.tag) } ?? c.children.count
          c.children.insert(XMLNode("offset", text: try ticks(at, div)), at: index)
        }
        prefix.append(c)
      } else if c.tag == "attributes" {
        remove(c, ["divisions"])
        if pos > .zero {
          prefix += [XMLNode("forward", children: [XMLNode("duration", text: try ticks(pos, div))]), c,
            XMLNode("backup", children: [XMLNode("duration", text: try ticks(pos, div))])]
        } else { prefix.append(c) }
      } else { prefix.append(c) }
    }
    let attributes: XMLNode
    if let a = prefix.first(where: { c in c.tag == "attributes" && bar.metadata.contains(where: { $0.0 == .zero && $0.1.tag == "attributes" }) }) { attributes = a }
    else { attributes = XMLNode("attributes"); prefix.insert(attributes, at: 0) }
    attributes.children.insert(XMLNode("divisions", text: String(div)), at: 0)
    if resize {
      remove(attributes, ["time"])
      let beatType = [bar.meter.1, 4, 8, 16, 32, 64, 128].first { (length * Q($0, 4)).d == 1 }!
      let time = XMLNode("time", attributes: ["id": "scan-overflow-validity"], children: [
        XMLNode("beats", text: String((length * Q(beatType, 4)).n)), XMLNode("beat-type", text: String(beatType))])
      let index = attributes.children.firstIndex { ["staves", "part-symbol", "instruments", "clef", "staff-details", "transpose", "directive", "measure-style"].contains($0.tag) } ?? attributes.children.count
      attributes.children.insert(time, at: index)
      if !bar.metadata.contains(where: { $0.1.first("direction-type")?.first("words")?.text == "check bar" }) {
        prefix.append(XMLNode("direction", children: [XMLNode("direction-type", children: [XMLNode("words", text: "check bar")])]))
      }
    }
    var written = prefix
    for (i, key) in lines.keys.sorted().enumerated() {
      if i > 0 { written.append(XMLNode("backup", children: [XMLNode("duration", text: try ticks(length, div))])) }
      written += try canonical(lines[key]!, length: length, oldDivisions: bar.divisions, divisions: div, key: key)
    }
    bar.node.children = written + tail
  }

  /// The serialized repair must retain every original attack (including grace notes) and the full sounding
  /// time of each pitch on each staff. Tied continuations may add attacks to the XML, but cannot replace one.
  static func retained(_ before: Bar, _ after: Bar) -> Bool {
    func inventory(_ bar: Bar) -> ([String: Int], [String: Q]) {
      var attacks: [String: Int] = [:], lengths: [String: Q] = [:]
      for (key, groups) in bar.lines {
        for g in groups {
          for n in g.nodes where n.first("rest") == nil {
            let pitch = n.first("pitch")?.serialized() ?? n.first("unpitched")?.serialized() ?? "unknown"
            let grace = n.first("grace") != nil
            let sound = "\(key.staff)|\(pitch)|\(grace)"
            attacks["\(sound)|\(g.start)", default: 0] += 1
            lengths[sound, default: .zero] += grace ? .zero : Q((try? n.duration()) ?? 0, bar.divisions)
          }
        }
      }
      return (attacks, lengths)
    }
    let a = inventory(before), b = inventory(after)
    return a.0.allSatisfy { b.0[$0.key, default: 0] >= $0.value } && a.1 == b.1
  }

  static func apply(_ data: Data) throws -> Data {
    let root = try XMLNode.parse(data)
    guard root.tag == "score-partwise" else { throw ScannerError.invalid("Expected partwise MusicXML") }
    let parts = root.all("part").map { $0.all("measure") }
    var snapshots: [[Bar]] = []
    for measures in parts {
      var divisions = 1, meter = (4, 4), bars: [Bar] = []
      for m in measures {
        // a meter after the bar's first note (beside a clef change for the next bar) starts at the next bar, as
        // MuseScore reads it
        var later: (Int, Int)?
        var sounded = false
        for c in m.children {
          if ["note", "backup", "forward"].contains(c.tag) { sounded = true }
          guard c.tag == "attributes" else { continue }
          if let d = c.first("divisions") { divisions = try d.integer() }
          if let t = c.first("time"), let b = t.first("beats"), let bt = t.first("beat-type") {
            let value = (try b.integer(), try bt.integer())
            if sounded { later = value } else { meter = value }
          }
        }
        guard divisions > 0, meter.0 > 0, meter.1 > 0 else { throw ScannerError.invalid("Invalid MusicXML divisions or meter") }
        bars.append(try parse(m, divisions: divisions, meter: meter))
        if let later { meter = later }
      }
      snapshots.append(bars)
    }
    var changed = false
    for i in 0..<(snapshots.map(\.count).max() ?? 0) {
      let bars = snapshots.compactMap { i < $0.count ? $0[i] : nil }
      guard let first = bars.first else { continue }
      var length = bars.map(\.reach).max() ?? .zero
      if length == .zero { length = Q(first.meter.0 * 4, first.meter.1) }
      // MuseScore rounds non-binary measure lengths to 1/128 whole notes. Pad upwards, never truncate a note.
      if (length * Q(32)).d != 1 { let scaled = length * Q(32); length = Q((scaled.n + scaled.d - 1) / scaled.d, 32) }
      let resize = length > Q(first.meter.0 * 4, first.meter.1) && first.node.attributes["implicit"] != "yes"
      for (p, part) in snapshots.enumerated() where i < part.count {
        let bar = part[i]
        let bad = bar.lines.contains { !failures($0.value, length: length, divisions: bar.divisions).isEmpty }
        let outside = bar.metadata.contains { pos, c in
          guard c.tag == "direction" || c.tag == "harmony" else { return false }
          let at = pos + Q(Int(c.first("offset")?.text ?? "0") ?? 0, bar.divisions)
          return at < .zero || at > length
        }
        let voices = Dictionary(grouping: bar.lines.keys, by: \.staff).values.contains { $0.count > 4 }
        guard bad || outside || voices || resize else { continue }
        try repair(bar, length: length, resize: resize); changed = true
        // Restore inherited divisions and the printed meter at the next bar, using the immutable snapshot.
        if i + 1 < part.count {
          let next = parts[p][i + 1], original = part[i + 1]
          let a: XMLNode
          if let existing = original.metadata.first(where: { $0.0 == .zero && $0.1.tag == "attributes" })?.1 { a = existing }
          else { a = XMLNode("attributes"); next.children.insert(a, at: 0) }
          if a.first("divisions") == nil { a.children.insert(XMLNode("divisions", text: String(original.divisions)), at: 0) }
          if resize && !next.all("attributes").contains(where: { $0.first("time") != nil }) {
            let t = XMLNode("time", children: [XMLNode("beats", text: String(original.meter.0)), XMLNode("beat-type", text: String(original.meter.1))])
            let index = a.children.firstIndex { !["divisions", "key"].contains($0.tag) } ?? a.children.count
            a.children.insert(t, at: index)
          }
        }
        let check = try parse(bar.node, divisions: bar.divisions * 256, meter: bar.meter)
        guard check.lines.allSatisfy({ failures($0.value, length: length, divisions: check.divisions).isEmpty }),
              Dictionary(grouping: check.lines.keys, by: \.staff).values.allSatisfy({ $0.count <= 4 }),
              retained(bar, check) else {
          throw ScannerError.invalid("MusicXML validity: could not repair measure \(bar.node.attributes["number"] ?? String(i + 1))")
        }
      }
    }
    // PDF pages reuse note and generated meter IDs. Keep the first spelling and uniquify subsequent IDs.
    var seen = Set<String>()
    func ids(_ n: XMLNode) {
      if ["note", "time"].contains(n.tag), let id = n.attributes["id"] {
        var value = id, suffix = 1
        while seen.contains(value) { value = "\(id)_\(suffix)"; suffix += 1 }
        if value != id { n.attributes["id"] = value; changed = true }
        seen.insert(value)
      }
      for c in n.children { ids(c) }
    }
    ids(root)
    return changed ? Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()).utf8) : data
  }
  static func apply(_ xml: String) throws -> String { String(decoding: try apply(Data(xml.utf8)), as: UTF8.self) }

  /// Repair rhythmic spelling when possible, then print ordinary silent gaps. If rhythm repair cannot
  /// finish, keep the original pitches and timing rather than lose the scan.
  static func repaired(_ data: Data) -> Data {
    // Repair can itself add silent padding. Print ordinary gaps only after that final spelling;
    // tuplet fillers now have their time-modification and remain hidden.
    ScoreGapRestsMusicXML.apply((try? apply(data)) ?? data)
  }
  static func repaired(_ xml: String) -> String { String(decoding: repaired(Data(xml.utf8)), as: UTF8.self) }
}
