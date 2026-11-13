import Foundation

extension Copista {
  /// Bars the reader got wrong in ways a score importer will not take, made importable. Only a bar that needs it
  /// changes; every other bar, and the whole file when nothing needs it, is left exactly as written.
  ///
  /// - A pitch no piano reaches (below A0, above C8) is a misread. It is dropped; a note sounding alone keeps its
  ///   time as a hidden rest, so nothing after it moves.
  /// - A staff holds at most four voices. A line beyond that moves into one of the four where that voice is free,
  ///   or is dropped.
  /// - A voice whose notes start where no plain rest can reach (a stray triplet fragment in a bar of plain notes,
  ///   left by a misread run) cannot be laid out, and an importer then rejects the whole score. That voice is
  ///   dropped from the bar. Its rhythm was already wrong; the rest of the score now opens.
  ///
  /// A dropped note gives its time back as a gap, so the notes after it keep their places.
  enum Tidy {
    /// MIDI numbers of A0 and C8, the ends of a piano.
    static let lowest = 21, highest = 108
    static let voicesPerStaff = 4

    final class Group {
      var nodes: [XMLNode]
      let staff: String
      var voice: String
      let start: Int, duration: Int
      let grace: Bool
      init(_ node: XMLNode, start: Int, duration: Int, grace: Bool) {
        nodes = [node]
        staff = node.first("staff")?.text ?? "1"
        voice = node.first("voice")?.text ?? "1"
        self.start = start; self.duration = duration; self.grace = grace
      }
      var end: Int { start + duration }
    }

    static func apply(_ xml: String) -> String {
      guard let root = try? XMLNode.parse(Data(xml.utf8)) else { return xml }
      var changed = false
      for part in root.all("part") {
        var divisions = 1
        for m in part.all("measure") {
          for a in m.all("attributes") {
            if let d = a.first("divisions"), let v = Int(d.text), v > 0 { divisions = v }
          }
          if tidy(m, divisions: divisions) { changed = true }
          if bracketTuplets(m, divisions: divisions) { changed = true }
        }
      }
      if overflowMeters(root) { changed = true }
      guard changed else { return xml }
      return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()
    }

    static func midi(_ note: XMLNode) -> Int? {
      guard let p = note.first("pitch"), let step = p.first("step")?.text,
            let octave = Int(p.first("octave")?.text ?? "") else { return nil }
      let semis = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][step] ?? 0
      let alter = Int((Double(p.first("alter")?.text ?? "0") ?? 0).rounded())
      return (octave + 1) * 12 + semis + alter
    }

    /// The bar's notes as sounding groups (a note and the chord notes stacked on it), with where each starts.
    static func groups(_ m: XMLNode) -> [Group] {
      var cursor = 0
      var out: [Group] = []
      for c in m.children {
        let d = Int(c.first("duration")?.text ?? "") ?? 0
        switch c.tag {
        case "backup": cursor -= d
        case "forward": cursor += d
        case "note":
          if c.first("chord") != nil, let g = out.last { g.nodes.append(c); continue }
          let grace = c.first("grace") != nil
          out.append(Group(c, start: cursor, duration: grace ? 0 : d, grace: grace))
          if !grace { cursor += d }
        default: break
        }
      }
      return out
    }

    /// How far the bar reaches: the furthest point any note or gap takes it.
    static func reach(_ m: XMLNode) -> Int {
      var cursor = 0, end = 0
      for c in m.children {
        let d = Int(c.first("duration")?.text ?? "") ?? 0
        switch c.tag {
        case "backup": cursor -= d
        case "forward": cursor += d
        case "note" where c.first("chord") == nil && c.first("grace") == nil: cursor += d
        default: break
        }
        end = max(end, cursor)
      }
      return end
    }

    /// Whether a stretch of the bar can be filled with plain rests (it is a whole number of 128th notes).
    static func plain(_ gap: Int, divisions: Int) -> Bool { gap >= 0 && (gap * 32) % divisions == 0 }

    static func remove(_ node: XMLNode, from m: XMLNode) { m.children.removeAll { $0 === node } }

    /// The group out of the bar, its time kept as a gap that belongs to no voice.
    static func drop(_ g: Group, from m: XMLNode) {
      if g.duration > 0, let i = m.children.firstIndex(where: { $0 === g.nodes[0] }) {
        m.children.insert(XMLNode("forward", children: [XMLNode("duration", text: "\(g.duration)")]), at: i)
      }
      for n in g.nodes { remove(n, from: m) }
      g.nodes = []
    }

    static func retag(_ g: Group, _ voice: String) {
      g.voice = voice
      for n in g.nodes { n.first("voice")?.text = voice }
    }

    /// A note turned into a hidden rest of the same length.
    static func hide(_ note: XMLNode) {
      let at = note.children.firstIndex { $0.tag == "pitch" || $0.tag == "unpitched" } ?? 0
      let drop: Set<String> = ["pitch", "unpitched", "tie", "accidental", "stem", "beam", "notations", "lyric", "notehead"]
      note.children.removeAll { drop.contains($0.tag) }
      note.children.insert(XMLNode("rest"), at: min(at, note.children.count))
      note.attributes["print-object"] = "no"
    }

    /// The `id` given to a time signature written for a bar that holds more than its meter, so the meter carried
    /// to the next page skips it.
    static let overflowID = "scan-overflow"

    /// A bar that holds more music than its time signature (a misread rhythm, or a meter change the reader missed)
    /// gets a time signature of its own length, with "check bar" above it, and the next bar returns to the meter. Staves that
    /// stop short fill the rest of the bar with ordinary rests. Nothing is cut; the odd meter shows where to look.
    /// A bar whose length no time signature can state (a stray triplet's worth over) is left as it is.
    static func overflowMeters(_ root: XMLNode) -> Bool {
      let parts = root.all("part").map { $0.all("measure") }
      guard let count = parts.map(\.count).min(), count > 0 else { return false }
      // each part's divisions and the meter its music is in, bar by bar, as written
      var divisions = [Int](repeating: 1, count: parts.count)
      var meters = [(Int, Int)](repeating: (4, 4), count: parts.count)
      var plan: [(index: Int, beats: Int, beatType: Int, meters: [(Int, Int)])] = []
      for i in 0..<count {
        var nominal: [Int] = [], reaches: [Int] = []
        for (p, measures) in parts.enumerated() {
          let m = measures[i]
          for a in m.all("attributes") {
            if let d = a.first("divisions"), let v = Int(d.text), v > 0 { divisions[p] = v }
            if let t = a.first("time"), let b = Int(t.first("beats")?.text ?? ""), let bt = Int(t.first("beat-type")?.text ?? ""),
               b > 0, bt > 0 { meters[p] = (b, bt) }
          }
          nominal.append(divisions[p] * 4 * meters[p].0 / meters[p].1)
          reaches.append(m.attributes["implicit"] == "yes" ? 0 : reach(m))
        }
        // one divisions value on the page, and some part runs past its bar
        guard Set(divisions).count == 1, let div = divisions.first,
              let longest = reaches.max(), zip(reaches, nominal).contains(where: { $0 > $1 }) else { continue }
        // the meter stating that length, counted in the bar's own beat unit when it can be (12/8 in a 9/8 song)
        let unit = meters.first?.1 ?? 4
        guard let beatType = ([unit] + [4, 8, 16, 32]).first(where: { (longest * $0) % (4 * div) == 0 }) else { continue }
        var beats = longest * beatType / (4 * div), unitUsed = beatType
        // 8/8 reads as 4/4; a compound count (12/8, 9/8) keeps its eighths
        while unitUsed > 4, beats % 2 == 0, beats % 3 != 0 { beats /= 2; unitUsed /= 2 }
        guard beats > 0, beats <= 32 else { continue }
        plan.append((i, beats, unitUsed, meters))
      }
      guard !plan.isEmpty else { return false }
      let flagged = Set(plan.map(\.index))
      for (i, beats, beatType, before) in plan {
        for (p, measures) in parts.enumerated() {
          let m = measures[i], div = divisions[p]
          let length = beats * 4 * div / beatType
          setTime(m, beats, beatType, id: "\(overflowID)-\(p + 1)-\(i + 1)")
          if reach(m) > div * 4 * before[p].0 / before[p].1 {
            let words = XMLNode("direction", attributes: ["placement": "above"], children: [
              XMLNode("direction-type", children: [XMLNode("words", text: "check bar")])])
            m.children.insert(words, at: (m.children.lastIndex { $0.tag == "attributes" || $0.tag == "print" } ?? -1) + 1)
          }
          fill(m, to: length)
          // the bar after returns to the meter, unless it states one of its own or is itself flagged
          if i + 1 < measures.count, !flagged.contains(i + 1) {
            let next = measures[i + 1]
            if !next.all("attributes").contains(where: { $0.first("time") != nil }) {
              setTime(next, before[p].0, before[p].1, id: nil)
            }
          }
        }
      }
      return true
    }

    /// A time signature at the start of a bar, in its attributes (made if the bar has none), in MusicXML order.
    static func setTime(_ m: XMLNode, _ beats: Int, _ beatType: Int, id: String?) {
      let attrs: XMLNode
      if let a = m.first("attributes") { attrs = a } else {
        attrs = XMLNode("attributes")
        m.children.insert(attrs, at: (m.children.lastIndex { $0.tag == "print" } ?? -1) + 1)
      }
      attrs.children.removeAll { $0.tag == "time" }
      let time = XMLNode("time", attributes: id.map { ["id": $0] } ?? [:], children: [
        XMLNode("beats", text: "\(beats)"), XMLNode("beat-type", text: "\(beatType)")])
      let order = ["footnote", "level", "divisions", "key"]
      let at = (attrs.children.lastIndex { order.contains($0.tag) } ?? -1) + 1
      attrs.children.insert(time, at: at)
    }

    /// Every staff of the bar carried on to `length` with rests: a whole-bar rest is stretched, any other staff that
    /// stops short gets a gap in its first voice, which importers fill with rests.
    static func fill(_ m: XMLNode, to length: Int) {
      var ends: [String: Int] = [:], firstVoice: [String: String] = [:]
      var cursor = 0
      for c in m.children {
        let d = Int(c.first("duration")?.text ?? "") ?? 0
        let staff = c.first("staff")?.text ?? "1"
        switch c.tag {
        case "backup": cursor -= d
        case "forward":
          cursor += d
          ends[staff] = max(ends[staff] ?? 0, cursor)
          if firstVoice[staff] == nil, let v = c.first("voice")?.text { firstVoice[staff] = v }
        case "note":
          if firstVoice[staff] == nil, let v = c.first("voice")?.text { firstVoice[staff] = v }
          if c.first("rest")?.attributes["measure"] == "yes" {
            c.first("duration")?.text = "\(length)"
            cursor += length
            ends[staff] = max(ends[staff] ?? 0, cursor)
            continue
          }
          if c.first("chord") == nil && c.first("grace") == nil { cursor += d }
          ends[staff] = max(ends[staff] ?? 0, cursor)
        default: break
        }
      }
      let at = m.children.lastIndex { $0.tag != "barline" }.map { $0 + 1 } ?? m.children.count
      var added: [XMLNode] = []
      for staff in ends.keys.sorted() {
        guard let end = ends[staff], end < length else { continue }
        if cursor > end { added.append(XMLNode("backup", children: [XMLNode("duration", text: "\(cursor - end)")])) }
        if cursor < end { added.append(XMLNode("forward", children: [XMLNode("duration", text: "\(end - cursor)")])) }
        var fw = [XMLNode("duration", text: "\(length - end)")]
        if let v = firstVoice[staff] { fw.append(XMLNode("voice", text: v)) }
        if m.children.contains(where: { $0.first("staff") != nil }) { fw.append(XMLNode("staff", text: staff)) }
        added.append(XMLNode("forward", children: fw))
        cursor = length
      }
      m.children.insert(contentsOf: added, at: at)
    }

    /// Written values, in quarters, a note can be given: whole down to 64th, plain or dotted.
    static let values: [(quarters: Double, type: String, dots: Int)] = [
      (4, "whole", 0), (6, "whole", 1), (2, "half", 0), (3, "half", 1), (1, "quarter", 0), (1.5, "quarter", 1),
      (0.5, "eighth", 0), (0.75, "eighth", 1), (0.25, "16th", 0), (0.375, "16th", 1), (0.125, "32nd", 0),
      (0.1875, "32nd", 1), (0.0625, "64th", 0),
    ]

    /// A tuplet note that starts just after a gap no plain rest fills (a stray triplet value in a run of plain
    /// notes): it is moved back to where the gap starts and written as the plain value that reaches its own end,
    /// when there is one, taking the gap's time. Same pitch and end; only its start and value change.
    static func snap(_ g: Group, from pos: Int, in m: XMLNode, divisions: Int) -> Bool {
      guard let root = g.nodes.first, root.first("time-modification") != nil,
            let at = m.children.firstIndex(where: { $0 === root }), at > 0 else { return false }
      let gap = g.start - pos
      // the gap must be the forward written right before the note
      let before = m.children[at - 1]
      guard before.tag == "forward", let fd = Int(before.first("duration")?.text ?? ""), fd >= gap else { return false }
      let length = g.end - pos
      let q = Double(length) / Double(divisions)
      guard let value = values.first(where: { abs($0.quarters - q) < 1e-9 }) else { return false }
      for n in g.nodes {
        n.first("duration")?.text = "\(length)"
        n.children.removeAll { $0.tag == "time-modification" || $0.tag == "dot" }
        n.first("type")?.text = value.type
        if let t = n.children.firstIndex(where: { $0.tag == "type" }) {
          for _ in 0..<value.dots { n.children.insert(XMLNode("dot"), at: t + 1) }
        }
        if let notations = n.first("notations") {
          notations.children.removeAll { $0.tag == "tuplet" }
          if notations.children.isEmpty { n.children.removeAll { $0 === notations } }
        }
      }
      if fd == gap { m.children.remove(at: at - 1) } else { before.first("duration")?.text = "\(fd - gap)" }
      return true
    }

    /// The tuplet brackets of each voice redrawn where they no longer hold its tuplet notes: a group missing its
    /// start or stop, or tuplet notes left outside any bracket (a voice split moved part of a triplet group, or a
    /// dropped note carried the start). Importers read notes outside a bracket at their plain value, so the bar
    /// comes out long. Voices whose brackets are whole are left as written.
    static func bracketTuplets(_ m: XMLNode, divisions: Int) -> Bool {
      let gs = groups(m).filter { !$0.nodes.isEmpty && !$0.grace && $0.duration > 0 }
      var lines: [String: [Group]] = [:]
      for g in gs { lines["\(g.staff)/\(g.voice)", default: []].append(g) }
      func ratio(_ n: XMLNode) -> String? {
        guard let tm = n.first("time-modification") else { return nil }
        return "\(tm.first("actual-notes")?.text ?? ""):\(tm.first("normal-notes")?.text ?? "")"
      }
      func marks(_ n: XMLNode) -> [String] {
        n.first("notations")?.all("tuplet").map { $0.attributes["type"] ?? "" } ?? []
      }
      var changed = false
      for line in lines.values {
        let line = line.sorted { $0.start < $1.start }
        // are the brackets as written whole?
        var inside = false, broken = false
        for (k, g) in line.enumerated() {
          let r = ratio(g.nodes[0]), mk = marks(g.nodes[0])
          if mk.contains("start") { if inside { broken = true }; inside = true }
          if r != nil && !inside {
            let near = [k - 1, k + 1].filter { line.indices.contains($0) }.map { line[$0] }
            if near.contains(where: { ratio($0.nodes[0]) == r && ($0.end == g.start || g.end == $0.start) }) { broken = true }
          }
          if mk.contains("stop") { if !inside { broken = true }; inside = false }
          if r == nil && inside { broken = true }
        }
        if inside { broken = true }
        guard broken else { continue }
        // redraw: runs of touching notes of one ratio, closed when they fill `normal` notes of their written type
        var want: [ObjectIdentifier: String] = [:]
        var run: [Group] = [], sum = 0, target = 0, current = "", lastEnd = -1
        func close() {
          if run.count > 1 { want[ObjectIdentifier(run[0].nodes[0])] = "start"; want[ObjectIdentifier(run[run.count - 1].nodes[0])] = "stop" }
          run = []; sum = 0
        }
        for g in line {
          let root = g.nodes[0]
          guard let r = ratio(root), let tm = root.first("time-modification") else { close(); lastEnd = g.end; continue }
          if run.isEmpty || r != current || g.start != lastEnd {
            close()
            current = r
            let normal = Double(tm.first("normal-notes")?.text ?? "") ?? 2
            let type = tm.first("normal-type")?.text ?? root.first("type")?.text ?? "eighth"
            let q = values.first { $0.type == type && $0.dots == 0 }?.quarters ?? 0.5
            target = Int((normal * q * Double(divisions)).rounded())
          }
          run.append(g); sum += g.duration; lastEnd = g.end
          if sum >= target { close() }
        }
        close()
        for g in line {
          for (k, n) in g.nodes.enumerated() {
            let w = k == 0 ? want[ObjectIdentifier(n)].map { [$0] } ?? [] : []
            guard marks(n) != w else { continue }
            changed = true
            let notations: XMLNode
            if let have = n.first("notations") { notations = have } else {
              notations = XMLNode("notations")
              n.children.append(notations)
            }
            notations.children.removeAll { $0.tag == "tuplet" }
            if let type = w.first { notations.children.insert(XMLNode("tuplet", attributes: ["type": type]), at: 0) }
            if notations.children.isEmpty { n.children.removeAll { $0 === notations } }
          }
        }
      }
      return changed
    }

    /// The other side of `snap`: a tuplet note followed by a gap no plain rest fills is stretched to the plain value
    /// reaching the next note of its voice, when there is one. The cursor step written right after it (a backup or a
    /// gap) absorbs the change, so nothing else moves; with no such step it is left alone.
    static func stretch(_ g: Group, to end: Int, in m: XMLNode, divisions: Int) -> Bool {
      guard let root = g.nodes.first, root.first("time-modification") != nil,
            let last = g.nodes.last, let at = m.children.firstIndex(where: { $0 === last }),
            at + 1 < m.children.count else { return false }
      let extra = end - g.end
      let step = m.children[at + 1]
      guard extra > 0, step.tag == "backup" || step.tag == "forward",
            let sd = Int(step.first("duration")?.text ?? "") else { return false }
      if step.tag == "forward" && sd < extra { return false }
      let length = end - g.start
      let q = Double(length) / Double(divisions)
      guard let value = values.first(where: { abs($0.quarters - q) < 1e-9 }) else { return false }
      for n in g.nodes {
        n.first("duration")?.text = "\(length)"
        n.children.removeAll { $0.tag == "time-modification" || $0.tag == "dot" }
        n.first("type")?.text = value.type
        if let t = n.children.firstIndex(where: { $0.tag == "type" }) {
          for _ in 0..<value.dots { n.children.insert(XMLNode("dot"), at: t + 1) }
        }
        if let notations = n.first("notations") {
          notations.children.removeAll { $0.tag == "tuplet" }
          if notations.children.isEmpty { n.children.removeAll { $0 === notations } }
        }
      }
      if step.tag == "backup" { step.first("duration")?.text = "\(sd + extra)" }
      else if sd == extra { m.children.remove(at: at + 1) }
      else { step.first("duration")?.text = "\(sd - extra)" }
      return true
    }

    /// A gap ending in one or two tuplet notes' length, beside tuplet notes, is a tuplet note the reader missed: that
    /// part is filled with tuplet rests of the value, just before the note (a rest shows where a note was missed; no
    /// note is guessed), and the rest of the gap is left to plain rests. The group is then whole, and its brackets are
    /// redrawn on the beat. The cursor step written before the note (a gap or a backup) gives up the rests' time.
    static func fillTuplet(_ g: Group, after previous: Group?, from pos: Int, in m: XMLNode, divisions: Int) -> Bool {
      let ref: XMLNode
      if g.nodes[0].first("time-modification") != nil { ref = g.nodes[0] }
      else if let p = previous, p.end == pos, p.nodes[0].first("time-modification") != nil { ref = p.nodes[0] }
      else { return false }
      let unit = Int(ref.first("duration")?.text ?? "") ?? 0
      let gap = g.start - pos
      guard unit > 0, let k = (1...2).first(where: { gap >= $0 * unit && plain(gap - $0 * unit, divisions: divisions) }),
            let at = m.children.firstIndex(where: { $0 === g.nodes[0] }), at > 0 else { return false }
      let fill = k * unit
      let before = m.children[at - 1]
      guard before.tag == "forward" || before.tag == "backup",
            let bd = Int(before.first("duration")?.text ?? "") else { return false }
      if before.tag == "forward" && bd < fill { return false }
      var rests: [XMLNode] = []
      for _ in 0..<k {
        var parts = [XMLNode("rest"), XMLNode("duration", text: "\(unit)")]
        if let v = g.nodes[0].first("voice") { parts.append(XMLNode("voice", text: v.text)) }
        if let t = ref.first("type") { parts.append(XMLNode("type", text: t.text)) }
        for _ in ref.all("dot") { parts.append(XMLNode("dot")) }
        if let tm = ref.first("time-modification") { parts.append(tm.copy()) }
        if let st = g.nodes[0].first("staff") { parts.append(XMLNode("staff", text: st.text)) }
        rests.append(XMLNode("note", children: parts))
      }
      m.children.insert(contentsOf: rests, at: at)
      if before.tag == "backup" { before.first("duration")?.text = "\(bd + fill)" }
      else if bd == fill { m.children.remove(at: at - 1) }
      else { before.first("duration")?.text = "\(bd - fill)" }
      return true
    }

    static func tidy(_ m: XMLNode, divisions: Int) -> Bool {
      var changed = false

      // pitches out of range
      for g in groups(m) {
        let out = g.nodes.filter { n in midi(n).map { $0 < lowest || $0 > highest } ?? false }
        guard !out.isEmpty else { continue }
        changed = true
        if out.count == g.nodes.count {
          if g.grace { for n in g.nodes { remove(n, from: m) } } else {
            hide(g.nodes[0])
            for n in g.nodes.dropFirst() { remove(n, from: m) }
          }
        } else {
          let rootGone = out.contains { $0 === g.nodes[0] }
          for n in out { remove(n, from: m) }
          if rootGone, let next = g.nodes.first(where: { n in !out.contains { $0 === n } }) {
            next.children.removeAll { $0.tag == "chord" }
          }
        }
      }

      // at most four voices on a staff
      var gs = groups(m)
      func voicesByStaff() -> [String: [String]] {
        var v: [String: [String]] = [:]
        for g in gs where !g.nodes.isEmpty && !(v[g.staff] ?? []).contains(g.voice) { v[g.staff, default: []].append(g.voice) }
        return v
      }
      func busy(_ staff: String, _ voice: String, _ s: Int, _ e: Int, except: Group) -> Bool {
        gs.contains { $0 !== except && !$0.nodes.isEmpty && $0.staff == staff && $0.voice == voice
          && $0.duration > 0 && $0.start < e && s < $0.end }
      }
      for (staff, voices) in voicesByStaff() where voices.count > voicesPerStaff {
        let kept = Array(voices.prefix(voicesPerStaff))
        for g in gs where g.staff == staff && !kept.contains(g.voice) && !g.nodes.isEmpty {
          changed = true
          let e = max(g.end, g.start + 1)
          if let v = kept.first(where: { !busy(staff, $0, g.start, e, except: g) }) { retag(g, v) } else { drop(g, from: m) }
        }
      }

      // a lone tuplet note that leaves a gap no plain rest fills becomes the plain note filling it (any voice)
      gs = groups(m)
      for (staff, voices) in voicesByStaff() {
        for voice in voices {
          let line = gs.filter { $0.staff == staff && $0.voice == voice && !$0.nodes.isEmpty && $0.duration > 0 }
            .sorted { $0.start < $1.start }
          var pos = 0
          var previous: Group?
          for g in line {
            if g.start > pos, !plain(g.start - pos, divisions: divisions) {
              if snap(g, from: pos, in: m, divisions: divisions) {
                changed = true
              } else if let p = previous, p.end == pos, stretch(p, to: g.start, in: m, divisions: divisions) {
                changed = true
              } else if fillTuplet(g, after: previous, from: pos, in: m, divisions: divisions) {
                changed = true
              }
            }
            pos = max(pos, g.end)
            previous = g
          }
        }
      }

      // voices an importer cannot lay out
      gs = groups(m)
      let barReach = reach(m)
      for (staff, voices) in voicesByStaff() {
        for voice in voices.dropFirst() {
          // Walk the voice in time: a note that overlaps the one before it, or starts where no plain rest can
          // reach from there, is dropped on its own; the voice's other notes stay.
          let line = gs.filter { $0.staff == staff && $0.voice == voice && !$0.nodes.isEmpty && $0.duration > 0 }
            .sorted { $0.start < $1.start }
          var kept: [Group] = []
          var pos = 0
          for g in line {
            if g.start < pos || !plain(g.start - pos, divisions: divisions) { drop(g, from: m); changed = true; continue }
            kept.append(g)
            pos = g.end
          }
          // the voice must also end where plain rests can carry it to the end of the bar
          while let last = kept.last, !plain(barReach - last.end, divisions: divisions) {
            drop(last, from: m); changed = true
            kept.removeLast()
          }
          // grace notes of a voice left with no notes go too
          if kept.isEmpty, !line.isEmpty {
            for g in gs where g.staff == staff && g.voice == voice && g.grace && !g.nodes.isEmpty { drop(g, from: m) }
          }
        }
      }

      guard changed else { return false }
      // a gap still tagged with a voice that now has no notes, or that runs through that voice's own notes,
      // would make the importer fill it: it becomes a plain gap
      let left = groups(m)
      var cursor = 0
      for c in m.children {
        let d = Int(c.first("duration")?.text ?? "") ?? 0
        switch c.tag {
        case "backup": cursor -= d
        case "forward":
          if let v = c.first("voice")?.text {
            let st = c.first("staff")?.text ?? "1"
            let mine = left.filter { $0.staff == st && $0.voice == v && $0.duration > 0 }
            if mine.isEmpty || mine.contains(where: { $0.start < cursor + d && cursor < $0.end }) {
              c.children.removeAll { $0.tag == "voice" || $0.tag == "staff" }
            }
          }
          cursor += d
        case "note" where c.first("chord") == nil && c.first("grace") == nil: cursor += d
        default: break
        }
      }
      return true
    }
  }
}
