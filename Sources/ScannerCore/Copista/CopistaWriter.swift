import Foundation
#if canImport(Android)
import Android
#endif

// copisteria's writer (write.py): a page's reading -> MusicXML. Transcription only: every decision was the model's.
// Without OCR text boxes (the app reads none yet): no part names from labels, words or multi-rest counts.

extension Copista {
  /// A MusicXML element that keeps its attributes in the order they were set (as ElementTree does).
  final class XE {
    let tag: String
    var attrs: [(String, String)] = []
    var text: String?
    var children: [XE] = []
    init(_ tag: String, _ text: String? = nil, _ attrs: [(String, String)] = []) {
      self.tag = tag; self.text = text; self.attrs = attrs
    }
    @discardableResult func sub(_ tag: String, _ text: Any? = nil, _ attrs: [(String, Any)] = []) -> XE {
      let e = XE(tag, text.map { "\($0)" }, attrs.map { ($0.0, "\($0.1)") })
      children.append(e)
      return e
    }
    func set(_ k: String, _ v: String) { attrs.append((k, v)) }
    func render(_ indent: Int = 0, into out: inout String) {
      func esc(_ s: String, attr: Bool) -> String {
        var r = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
          .replacingOccurrences(of: ">", with: "&gt;")
        if attr { r = r.replacingOccurrences(of: "\"", with: "&quot;") }
        return r
      }
      let pad = String(repeating: "  ", count: indent)
      out += pad + "<" + tag + attrs.map { " \($0.0)=\"\(esc($0.1, attr: true))\"" }.joined()
      if children.isEmpty {
        if let text { out += ">" + esc(text, attr: false) + "</" + tag + ">\n" } else { out += " />\n" }
        return
      }
      out += ">" + (text.map { esc($0, attr: false) } ?? "") + "\n"
      for c in children { c.render(indent + 1, into: &out) }
      out += pad + "</" + tag + ">\n"
    }
  }

  /// MuseScore hangs a grace note on the note after it. A grace note with no note after it in its bar and voice (cue
  /// notes read as graces, running into a rest or the bar line) has nothing to hang on, and a slur ending on it is
  /// left without a parent: MuseScore, Aria's engine included, crashes laying it out. Such a slur is dropped at both
  /// ends; every other slur is left as the reader paired it.
  static func dropDanglingGraceSlurs(_ voices: [[Event]]) {
    var dangling: [(Event, Int)] = []
    for evs in voices {
      for (i, e) in evs.enumerated() where e.grace != "none" && !e.slurs.isEmpty {
        if evs[(i + 1)...].contains(where: { $0.grace == "none" && $0.kind == "note" }) { continue }
        dangling += e.slurs.map { (e, $0.1) }
      }
    }
    if dangling.isEmpty { return }
    // the other end of each: the next stop of that number after a start, the last start before a stop
    let all = voices.joined().filter { !$0.slurs.isEmpty }
    for (e, num) in dangling {
      guard let at = all.firstIndex(where: { $0 === e }) else { continue }
      if e.slurs.contains(where: { $0 == ("start", num) }) {
        if let z = all[(at + 1)...].first(where: { $0.slurs.contains { $0 == ("stop", num) } }) {
          if let i = z.slurs.firstIndex(where: { $0 == ("stop", num) }) { z.slurs.remove(at: i) }
        }
      }
      if e.slurs.contains(where: { $0 == ("stop", num) }) {
        if let a = all[..<at].last(where: { $0.slurs.contains { $0 == ("start", num) } }) {
          if let i = a.slurs.firstIndex(where: { $0 == ("start", num) }) { a.slurs.remove(at: i) }
        }
      }
      e.slurs.removeAll { $0.1 == num }
    }
  }

  final class Event {
    var x: Double
    var kind: String
    var typ = "quarter", dots = 0, voice = 1, chord = false, grace = "none", tup = "none"
    var step = "C", octave = 4, alter = 0
    var tie = false, tieStop = false, unpitched = false
    /// A rest written invisible (time a tuplet group needs that the reader saw nothing in).
    var hidden = false
    var marks: [String] = []
    var dur = Q(1)
    var si = -1
    var tupletMark = "", accidental = "", stem = ""
    var beams: [(Int, String)] = []
    var slurs: [(String, Int)] = []
    var arpeggiate = false
    var pre: [Dir] = [], post: [Dir] = []
    var copied = false
    var onset: Double?
    var onsetP = 0.0
    var dist: (beat: [Double], frac: [Double], tup: [Double]?)?
    /// The model's weights for this note's value and dot count (`Tok.valueP`, `Tok.dotsP`).
    var valueP: [String: Double]?, dotsP: [Double]?

    init(x: Double, kind: String) { self.x = x; self.kind = kind }

    func copy() -> Event {
      let e = Event(x: x, kind: kind)
      e.typ = typ; e.dots = dots; e.voice = voice; e.chord = chord; e.grace = grace; e.tup = tup
      e.step = step; e.octave = octave; e.alter = alter; e.unpitched = unpitched; e.dur = dur; e.si = si
      e.tupletMark = tupletMark; e.accidental = accidental; e.stem = stem; e.arpeggiate = arpeggiate
      e.onset = onset; e.onsetP = onsetP; e.dist = dist; e.hidden = hidden
      e.valueP = valueP; e.dotsP = dotsP
      return e
    }
  }

  /// A direction: dynamics, wedge, octave shift, pedal, segno / coda, clef change.
  struct Dir {
    var x: Double
    var kind: String
    var payload: String
    var size = 0
    var below = false
  }

  /// A printed ending number ("1.", "2."): `x` in staff spaces from the bar's left edge, `top` in staff spaces above
  /// the staff.
  struct EndingGlyph: Equatable {
    var number: String
    var x: Double
    var top: Double
    /// The reader judged it real. A doubtful one (often handwritten) counts only where a repeat sign agrees.
    var sure = true
  }

  /// Where an ending bracket runs, in measures of the part: `closed` when it ends with a down hook (a 1st ending
  /// before its repeat), open ("discontinue") when it just stops (the last ending).
  struct EndingSpan: Equatable {
    var start: Int
    var stop: Int
    var number: String
    var closed: Bool
    /// Closed by the next ending of its set where no repeat sign was read: the brackets imply one.
    var impliedRepeat = false
  }

  struct Marks {
    var left: String?
    var right: String?
    var endings: [EndingGlyph] = []
    /// Tops (staff spaces above the staff) of bracket hooks that close at this bar's right end.
    var endingHooks: [Double] = []
    /// Tops of bracket hooks that open at this bar's left end.
    var bracketStarts: [Double] = []
    var multirest: Int?
    var repeatBar = false
    var endClef: String?
    var meter = false
    /// A bar of rhythm slashes, written with MusicXML's slash measure style.
    var slash = false
  }

  struct BarState: Equatable { var key = 0; var time = "4/4"; var clef = "G2" }

  /// Voices of a bar, in the order they first appear.
  struct Voices {
    var order: [Int] = []
    var map: [Int: [Event]] = [:]
    subscript(v: Int) -> [Event]? {
      get { map[v] }
      set {
        if map[v] == nil, newValue != nil { order.append(v) }
        map[v] = newValue
      }
    }
    var values: [[Event]] { order.map { map[$0]! } }
    var isEmpty: Bool { order.isEmpty }
  }

  final class StaffBar {
    let staff: Int, bar: Int
    var voices: Voices
    var dirs: [Dir]
    var marks: Marks
    let state: BarState
    init(staff: Int, bar: Int, voices: Voices, dirs: [Dir], marks: Marks, state: BarState) {
      self.staff = staff; self.bar = bar; self.voices = voices; self.dirs = dirs; self.marks = marks; self.state = state
    }
  }

  enum Writer {
    static let real = 0.5, onsetP = 0.6
    static let steps = Array("CDEFGAB").map(String.init)
    static let midLine: [String: Int] = [
      "G2": 34, "G1": 36, "F4": 22, "F3": 24, "F5": 20, "C1": 32, "C2": 30, "C3": 28, "C4": 26, "C5": 24,
      "G2_8b": 27, "G2_8a": 41, "G2_15b": 20, "G2_15a": 48, "F4_8b": 15, "F4_8a": 29, "F4_15b": 8, "F4_15a": 36,
      "perc": 34, "other": 34]
    static let clefXML: [String: (String, Int?, Int)] = [
      "G2": ("G", 2, 0), "G1": ("G", 1, 0), "F4": ("F", 4, 0), "F3": ("F", 3, 0), "F5": ("F", 5, 0),
      "C1": ("C", 1, 0), "C2": ("C", 2, 0), "C3": ("C", 3, 0), "C4": ("C", 4, 0), "C5": ("C", 5, 0),
      "G2_8b": ("G", 2, -1), "G2_8a": ("G", 2, 1), "G2_15b": ("G", 2, -2), "G2_15a": ("G", 2, 2),
      "F4_8b": ("F", 4, -1), "F4_8a": ("F", 4, 1), "F4_15b": ("F", 4, -2), "F4_15a": ("F", 4, 2),
      "perc": ("percussion", nil, 0), "other": ("G", 2, 0)]
    static let dyn: Set<String> = ["p", "pp", "ppp", "pppp", "ppppp", "mp", "mf", "f", "ff", "fff", "ffff", "fffff", "fp",
                                   "fz", "sf", "sfz", "sffz", "sfp", "sfpp", "rf", "rfz", "pf"]
    static let artic: [(String, String)] = [("artic_stacc", "staccato"), ("artic_acc", "accent"), ("artic_ten", "tenuto"),
                                            ("artic_marc", "strong-accent"), ("artic_stacciss", "staccatissimo"),
                                            ("artic_acc-soft", "soft-accent")]
    static let tech: [(String, String)] = [("artic_upbow", "up-bow"), ("artic_dnbow", "down-bow"), ("artic_harm", "harmonic"),
                                           ("artic_open", "open-string"), ("artic_stop", "stopped"), ("artic_snap", "snap-pizzicato")]
    static let accidXML: [String: String] = ["sharp": "sharp", "flat": "flat", "natural": "natural", "dsharp": "double-sharp",
                                             "dflat": "flat-flat", "natsharp": "natural-sharp", "natflat": "natural-flat"]
    static let accidAlter: [String: Int] = ["sharp": 1, "flat": -1, "natural": 0, "dsharp": 2, "dflat": -2, "natsharp": 1, "natflat": -1]
    static let ornament: [(String, String)] = [("trill", "trill-mark"), ("mordent", "mordent")]
    static let afterMark: [(String, String)] = [("breath", "breath-mark"), ("caesura", "caesura")]
    static let octave: [String: (Int, String, Int)] = ["octave_8a": (1, "down", 8), "octave_8b": (-1, "up", 8),
                                                        "octave_15a": (2, "down", 15), "octave_15b": (-2, "up", 15)]
    static let beamLevel: [String: Int] = ["eighth": 1, "16th": 2, "32nd": 3, "64th": 4, "128th": 5]
    static let barRight: [String: String] = ["barLine_double": "light-light", "barLine_final": "light-heavy",
                                             "barLine_repeat_end": "light-heavy", "barLine_dashed": "dashed", "barLine_dotted": "dotted"]
    static let shortRight: Set<String> = ["barLine_final", "barLine_repeat_end"]
    static let accAnchor: [String: Double] = ["flat": 0.46, "dflat": 0.46, "natflat": 0.46]
    static let alterKeepP = 0.97
    static let alignBrace = 2.0, alignClef = 1.0, alignShift = 0.01, alignSize = 1.2
    static let tieRise = 2.0, tieFar = 6.0, beamReach = 0.7
    static let gapLogp = log(0.02), overlapLogp = log(0.02), sameOnsetLogp = log(0.05), pastBarLogp = log(0.01)
    static let endGapLogp = log(0.02)
    static let meterLengths = 6
    static let barVoteFloor = log(0.01)

    static func lookup(_ table: [(String, String)], _ k: String) -> String? { table.first { $0.0 == k }?.1 }

    /// Ending numbers and the hooks that close ending brackets, by staff and bar. Both stand above the staff they
    /// belong to, so each goes to the nearest staff below it: the detector's own assignment can give a bracket
    /// printed between two systems (under the lyrics of the line above) to the wrong line. A hook counts only where
    /// it meets a bar line.
    static let doubtfulEnding = 0.15

    static func bracketMarks(_ rd: Reading) -> [Int: [Int: (endings: [EndingGlyph], hooks: [Double], opens: [Double])]] {
      let L = rd.layout
      var out: [Int: [Int: (endings: [EndingGlyph], hooks: [Double], opens: [Double])]] = [:]
      for s in L.syms {
        guard let r = rd.tok[s.i] else { continue }
        let c = cls(rd, s.i)
        let real = (r.realP ?? 0) >= Writer.real
        guard (family(c) == "ending" && (r.realP ?? 0) >= doubtfulEnding)
          || ((c == "spanEnd_tr" || c == "spanEnd_tl") && real)
        else { continue }
        var best: Int?
        for (k, st) in L.staves.enumerated() where st.x0 - 2 * st.sp <= s.cx && s.cx <= st.x1 + 2 * st.sp {
          let gap = (st.y0 - s.box.3) / st.sp
          guard gap > -0.5 && gap <= 14 else { continue }
          if best.map({ L.staves[$0].y0 > st.y0 }) ?? true { best = k }
        }
        guard let k = best else { continue }
        let st = L.staves[k], sp = st.sp
        let (j, _, _, _) = Front.band(L.syms, st, s.cx)
        let bb = L.syms[st.bars[j]].box
        let top = (st.y0 - s.box.1) / sp
        if c == "spanEnd_tr" {
          guard abs(s.box.2 - bb.2) < 2 * sp else { continue }
          out[k, default: [:]][j, default: ([], [], [])].hooks.append(top)
        } else if c == "spanEnd_tl" {
          guard abs(s.box.0 - bb.0) < 2 * sp else { continue }
          out[k, default: [:]][j, default: ([], [], [])].opens.append(top)
        } else {
          let glyph = EndingGlyph(
            number: String(c.dropFirst("ending_".count)), x: (s.cx - bb.0) / sp, top: top, sure: real)
          out[k, default: [:]][j, default: ([], [], [])].endings.append(glyph)
        }
      }
      return out
    }

    static func endingNumbers(_ number: String) -> [Int] {
      number.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The bars each printed ending covers. The detector reads only the number ("1.") and the bracket's corner
    /// hooks, so the bracket is followed to the hook that closes it at a bar line, at the number's height. Without
    /// that hook, an ending followed by a higher one (the 1st before the 2nd) runs to its repeat sign, or to the bar
    /// before the next ending; the last ending, drawn open, keeps its first bar. `bars` holds each measure's marks
    /// (its top staff), `systems` the line each measure is on.
    static func endingSpans(_ bars: [Marks?], systems: [Int]) -> [EndingSpan] {
      // a bar's printed numbers: "1., 2." reads as two glyphs a few staff spaces apart; "x" is a number not read
      func numbers(_ s: Int) -> ([Int], EndingGlyph) {
        let glyphs = bars[s]!.endings.sorted { $0.x < $1.x }
        let together = glyphs.filter { $0.x - glyphs[0].x < 4 }
        return (Array(Set(together.compactMap { Int($0.number) })).sorted(), glyphs[0])
      }
      func repeatEnd(_ m: Int) -> Bool { m >= 0 && m < bars.count && bars[m]?.right == "barLine_repeat_end" }
      // a doubtful number counts where a repeat sign agrees: one closes it on its line (a 1st ending), or it
      // follows one (a 2nd ending)
      func confirmed(_ s: Int) -> Bool {
        if bars[s]!.endings.contains(where: \.sure) || repeatEnd(s - 1) { return true }
        // two numbers a few bars apart confirm each other (a 1st and a 2nd ending)
        let near = max(0, s - 4)...min(bars.count - 1, s + 4)
        if near.contains(where: { $0 != s && !(bars[$0]?.endings.isEmpty ?? true) }) { return true }
        for m in s..<bars.count where systems[m] == systems[s] {
          if repeatEnd(m) { return true }
          if m > s && (bars[m]?.left != nil || !(bars[m]?.endings.isEmpty ?? true)) { break }
        }
        return false
      }
      // an ending carried over a line break, its number printed again at the start of the next line without an
      // opening hook, is one ending; a bracket that opens again is the next ending, whatever number was read
      var starts: [Int] = []
      var renumbered: [Int: [Int]] = [:]
      for s in bars.indices where !(bars[s]?.endings.isEmpty ?? true) && confirmed(s) {
        if let p = starts.last, !(p..<s).contains(where: repeatEnd), !(p + 1...s).contains(where: { bars[$0]?.left != nil }) {
          let (nums, glyph) = numbers(s)
          let before = renumbered[p] ?? numbers(p).0
          let opens = (bars[s]?.bracketStarts ?? []).contains { abs($0 - glyph.top) <= 2 }
          if s > 0, systems[s - 1] != systems[s], systems[s] == systems[p] + 1, nums == before, !opens { continue }
          if s - p <= 6, let b = before.max(), (nums.max() ?? 0) <= b { renumbered[s] = [b + 1] }
        }
        starts.append(s)
      }
      var spans: [EndingSpan] = []
      for (k, s) in starts.enumerated() {
        if let last = spans.last, s <= last.stop { continue }
        var (nums, glyph) = numbers(s)
        if let r = renumbered[s] { nums = r }
        // right after an ending closed by its repeat comes the next number ("2." misread as "1.", or not read)
        let prev = spans.last.flatMap { $0.stop == s - 1 && $0.closed ? endingNumbers($0.number).max() : nil }
        if nums.isEmpty || (prev != nil && nums.max()! <= prev!) { nums = [(prev ?? 0) + 1] }
        // a 2nd ending after a repeat whose 1st ending was not found: the 1st runs back from the repeat to the
        // bracket's opening hook on that line (at the 2nd's height), or is the repeat's own bar
        if nums.min()! >= 2, repeatEnd(s - 1), spans.last?.stop != s - 1 {
          var first = s - 1
          for m in stride(from: s - 1, through: 0, by: -1) where systems[m] >= systems[s - 1] - 1 {
            if m < s - 1 && (repeatEnd(m) || bars[m]?.left != nil) { break }
            if (bars[m]?.bracketStarts ?? []).contains(where: { abs($0 - glyph.top) <= 1.5 }) {
              first = m
              break
            }
          }
          if spans.last.map({ $0.stop < first }) ?? true {
            spans.append(EndingSpan(
              start: first, stop: s - 1,
              number: (1..<nums.min()!).map(String.init).joined(separator: ", "), closed: true))
          }
        }
        let next = starts.dropFirst(k + 1).first
        let nextNums = next.map { renumbered[$0] ?? numbers($0).0 } ?? []
        let lastBar = (bars.indices.last { systems[$0] <= systems[s] + 2 }) ?? s
        // followed by the next ending of its set: the 1st before the 2nd (an unread number counts as the next)
        // (a "1." is never the last, even when the "2." after it was not read)
        let followed = nums.max()! == 1
          || (next.map { $0 <= lastBar + 1 && (nextNums.isEmpty || nextNums.max()! > nums.max()!) } ?? false)
        let end = min(followed ? lastBar : (bars.indices.last { systems[$0] == systems[s] } ?? s), (next ?? Int.max) - 1)
        var stop: Int?, closed = false
        for m in s...max(s, end) {
          guard let marks = bars[m] else { continue }
          if m > s && marks.left != nil {
            stop = followed ? m - 1 : s
            break
          }
          if marks.endingHooks.contains(where: { abs($0 - glyph.top) <= 1.5 }) {
            stop = m; closed = true
            break
          }
          if marks.right == "barLine_repeat_end" && (followed || m == s) {
            stop = m; closed = true
            break
          }
        }
        var implied = false
        if stop == nil, followed, let next {
          stop = next - 1; closed = true
          implied = !repeatEnd(next - 1)
        }
        spans.append(EndingSpan(
          start: s, stop: stop ?? s, number: nums.map(String.init).joined(separator: ", "), closed: closed,
          impliedRepeat: implied))
      }
      return spans
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }
    static func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }

    static func pitch(_ clef: String, _ pos: Int) -> (String, Int) {
      let idx = (midLine[clef] ?? 34) + pos
      return (steps[floorMod(idx, 7)], floorDiv(idx, 7))
    }

    static func clefOfCls(_ cls: String) -> String {
      let name = String(cls.dropFirst("clef_".count))
      return midLine[name] != nil ? name : (name == "perc" ? "perc" : "other")
    }

    /// The reader often puts an 8 under a plain treble clef (on lead sheets that print none), which drops the
    /// line an octave. An octave clef counts only when the detector saw one too: otherwise the plain clef is kept.
    static func seenClef(_ read: String, detected: [String]) -> String {
      guard !detected.isEmpty, !detected.contains(read),
            let suffix = ["_8b", "_8a", "_15b", "_15a"].first(where: { read.hasSuffix($0) })
      else { return read }
      return String(read.dropLast(suffix.count))
    }

    static func seenClef(_ rd: Reading, _ staff: Int, _ bar: Int, _ read: String) -> String {
      let detected = rd.layout.syms.filter { $0.staff == staff && $0.bar == bar && $0.cls.hasPrefix("clef_") }
      return seenClef(read, detected: detected.map { clefOfCls($0.cls) })
    }

    /// A clef symbol: the reader's clef, without an octave mark the detector did not see.
    static func seenClef(_ rd: Reading, _ s: Sym) -> String {
      seenClef(clefOfCls(cls(rd, s.i)), detected: s.cls.hasPrefix("clef_") ? [clefOfCls(s.cls)] : [])
    }

    /// Dynamics the detector is unsure of are mostly chord names in italics ("F", "B°", "E♭7" read as "p", "pp"),
    /// above the staff where chord names go; below it they are mostly real. Measured on 1,022 generated pages
    /// (931 dynamics) and 436 real ones: the 0.6 / 0.3 bars remove 760 of 781 false ones for 39 real ones.
    static let dynamicAboveP = 0.6, dynamicBelowP = 0.3
    /// A dynamic inside a word the chord finder found counts only when the detector is this sure.
    static let dynamicInWordP = 0.8

    static func keptDynamic(_ s: Sym, _ st: Staff) -> Bool {
      s.p >= (s.cy < st.y0 ? dynamicAboveP : dynamicBelowP)
    }

    /// Dynamics the writer keeps that sit inside a word the chord finder found above or below a staff, read with
    /// less than `dynamicInWordP`: a chord name, not a dynamic. On real lead sheets this leaves 4 of 834.
    static func dynamicsInWords(_ rd: Reading, _ words: [ChordFinder.Proposal]) -> [Int] {
      let L = rd.layout
      let text = words.filter { $0.kind == .text }
      return L.syms.compactMap { s -> Int? in
        guard s.staff >= 0, s.staff < L.staves.count, isReal(rd, s.i), family(cls(rd, s.i)) == "dynam",
              s.p < dynamicInWordP, keptDynamic(s, L.staves[s.staff]) else { return nil }
        let pad = 0.3 * L.staves[s.staff].sp
        let inside = text.contains {
          Double($0.x0) - pad <= s.cx && s.cx <= Double($0.x1) + pad && Double($0.y0) - pad <= s.cy
            && s.cy <= Double($0.y1) + pad
        }
        return inside ? s.i : nil
      }
    }

    static func timeLen(_ t: String) -> Q {
      guard t != "other", t.contains("/") else { return Q(4) }
      let p = t.split(separator: "/").map { Int($0)! }
      return Q(p[0] * 4, p[1])
    }

    // MARK: parts
    static func isReal(_ rd: Reading, _ si: Int) -> Bool { (rd.tok[si]?.realP ?? 0) >= real }
    static func cls(_ rd: Reading, _ si: Int) -> String { rd.classes[rd.tok[si]!.cls] }

    static func covered(_ L: Layout, _ box: Box, _ ks: [Int]) -> [Int] {
      ks.indices.filter { p in
        let st = L.staves[ks[p]]
        return box.1 - st.sp <= st.mid && st.mid <= box.3 + st.sp
      }
    }

    /// The two neighbouring staves (as positions in `ks`) a brace pairs. When `covered` finds no pair, the pair
    /// whose combined height overlaps the brace most, by at least half of their union: on a curled photo the staves
    /// bend down (or up) towards the binding, where the brace is, so the brace sits a few staff spaces off the
    /// staves' straight-line position although it is as tall as the pair.
    static func bracePair(_ L: Layout, _ box: Box, _ ks: [Int]) -> [Int]? {
      let cov = covered(L, box, ks)
      if cov.count == 2 && cov[1] == cov[0] + 1 { return cov }
      guard cov.count < 2, ks.count >= 2 else { return nil }
      var best: [Int]?, bestIoU = 0.5
      for p in 0..<(ks.count - 1) {
        let a = L.staves[ks[p]], b = L.staves[ks[p + 1]]
        let inter = min(box.3, b.y1) - max(box.1, a.y0), union = max(box.3, b.y1) - min(box.1, a.y0)
        if union > 0, inter / union >= bestIoU { bestIoU = inter / union; best = [p, p + 1] }
      }
      return best
    }

    static func fullest(_ L: Layout) -> System {
      var t = L.systems[0]
      for sy in L.systems.dropFirst() where sy.staves.count > t.staves.count { t = sy }
      return t
    }

    static func planParts(_ rd: Reading) -> [[Int]] {
      let L = rd.layout
      guard !L.systems.isEmpty else { return [] }
      let tmpl = fullest(L)
      let K = tmpl.staves.count
      var taken = [Bool](repeating: false, count: K)
      var plans: [[Int]] = []
      let braces = L.syms.indices.filter { isReal(rd, $0) && cls(rd, $0) == "grpSym_brace" }.map { L.syms[$0] }
      // the pairs braced in the template system, then those braced in any other system laid out like it (a brace
      // can be missed or sit off its staves on one curled system of a photo while the page's others show it)
      for sy in [tmpl] + L.systems.filter({ $0 !== tmpl && $0.staves.count == K }) {
        for s in braces {
          if let cov = bracePair(L, s.box, sy.staves), !cov.contains(where: { taken[$0] }) {
            for p in cov { taken[p] = true }
            plans.append(cov)
          }
        }
      }
      for p in 0..<K where !taken[p] { plans.append([p]) }
      return Front.stableSorted(plans) { $0[0] < $1[0] }
    }

    static func bracedPairs(_ L: Layout, _ sy: System, _ braces: [Sym]) -> Set<Int> {
      var out = Set<Int>()
      for s in braces {
        if let cov = bracePair(L, s.box, sy.staves) { out.insert(cov[0]) }
      }
      return out
    }

    static func openingClef(_ rd: Reading, _ k: Int) -> String? {
      let bars = rd.layout.staves[k].bars
      guard let b = bars.first, let r = rd.tok[b], r.hasBarHeads else { return nil }
      return r.clef.map { seenClef(rd, k, 0, $0) }
    }

    /// Staves of a system that a brace marks as one half of a pair whose other staff was not found (an empty
    /// piano staff is easy to miss): the brace runs on two staff heights past the one staff it covers.
    /// Position in the system -> true for the upper half, false for the lower.
    static func halfBraced(_ L: Layout, _ sy: System, _ braces: [Sym]) -> [Int: Bool] {
      var out: [Int: Bool] = [:]
      for s in braces {
        let cov = covered(L, s.box, sy.staves)
        guard cov.count == 1 else { continue }
        let st = L.staves[sy.staves[cov[0]]]
        let reach = 2 * (st.y1 - st.y0)
        if s.box.3 > st.y1 + reach / 2 && s.box.1 >= st.y0 - st.sp * 2 { out[cov[0]] = true }
        else if s.box.1 < st.y0 - reach / 2 && s.box.3 <= st.y1 + st.sp * 2 { out[cov[0]] = false }
      }
      return out
    }

    /// Per system: place (in the fullest system) -> staff.
    static func alignSystems(_ rd: Reading, _ plans: [[Int]]) -> [[Int: Int]] {
      let L = rd.layout
      guard !L.systems.isEmpty else { return [] }
      let tmpl = fullest(L)
      let K = tmpl.staves.count
      let pair = Set(plans.filter { $0.count == 2 }.map { $0[0] })
      let braces = L.syms.filter { isReal(rd, $0.i) && cls(rd, $0.i) == "grpSym_brace" }
      let tClef = tmpl.staves.map { openingClef(rd, $0) }
      let tSp = tmpl.staves.map { L.staves[$0].sp }
      var out: [[Int: Int]] = []
      for sy in L.systems {
        let n = sy.staves.count
        func identity() -> [Int: Int] { Dictionary(uniqueKeysWithValues: sy.staves.enumerated().map { ($0.offset, $0.element) }) }
        if n == K { out.append(identity()); continue }
        let own = bracedPairs(L, sy, braces)
        if !own.isEmpty && pair.isEmpty { out.append(identity()); continue }
        let half = pair.isEmpty ? [:] : halfBraced(L, sy, braces)
        let clefs = sy.staves.map { openingClef(rd, $0) }
        func unary(_ i: Int, _ p: Int) -> Double {
          var v = -alignShift * Double(abs(p - i))
          if let c = clefs[i], let t = tClef[p] { v += c == t ? alignClef : -alignClef }
          // a small staff (an ossia or cue line) is not the full-size staff of the same clef beside it
          let sp = L.staves[sy.staves[i]].sp
          if max(sp, tSp[p]) > alignSize * min(sp, tSp[p]) { v -= alignClef }
          if let upper = half[i] { v += pair.contains(upper ? p : p - 1) ? alignBrace : -alignBrace }
          return v
        }
        func link(_ i: Int, _ q: Int, _ p: Int) -> Double {
          var v = 0.0
          if own.contains(i - 1) && p != q + 1 { v -= alignBrace } else if own.contains(i - 1) && pair.contains(q) { v += alignBrace }
          if pair.contains(q) && p != q + 1 { v -= alignBrace }
          if pair.contains(p - 1) && q != p - 1 { v -= alignBrace }
          return v
        }
        var best = [[Double]](repeating: [Double](repeating: -.infinity, count: K), count: n)
        var back = [[Int]](repeating: [Int](repeating: -1, count: K), count: n)
        for p in 0...(K - n) { best[0][p] = unary(0, p) - (pair.contains(p - 1) ? alignBrace : 0) }
        if n > 1 {
          for i in 1..<n {
            for p in i...(K - n + i) {
              for q in (i - 1)..<p {
                let v = best[i - 1][q] + link(i, q, p)
                if v > best[i][p] { best[i][p] = v; back[i][p] = q }
              }
              best[i][p] += unary(i, p)
            }
          }
        }
        var p = n - 1
        for c in (n - 1)..<K where best[n - 1][c] - (pair.contains(c) ? alignBrace : 0) > best[n - 1][p] - (pair.contains(p) ? alignBrace : 0) { p = c }
        var places = [p]
        if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { p = back[i][p]; places.append(p) } }
        var at: [Int: Int] = [:]
        for (pl, k) in zip(places.reversed(), sy.staves) { at[pl] = k }
        out.append(at)
      }
      return out
    }

    static func partGroups(_ rd: Reading, _ plans: [[Int]]) -> [(Int, Int, String)] {
      let L = rd.layout
      guard !L.systems.isEmpty, plans.count >= 2 else { return [] }
      let tmpl = fullest(L)
      var partOf: [Int: Int] = [:]
      for (n, pl) in plans.enumerated() { for p in pl { partOf[p] = n } }
      var out: [(Int, Int, String)] = []
      for s in L.syms where isReal(rd, s.i) {
        let c = cls(rd, s.i)
        guard c == "grpSym_bracket" || c == "grpSym_brace" else { continue }
        let cov = Array(Set(covered(L, s.box, tmpl.staves).compactMap { partOf[$0] })).sorted()
        if cov.count >= 2 && !out.contains(where: { $0.0 == cov[0] && $0.1 == cov[cov.count - 1] }) {
          out.append((cov[0], cov[cov.count - 1], s.cls.hasSuffix("bracket") ? "bracket" : "brace"))
        }
      }
      return out
    }

    /// A bar's key, time and clef. The key changes only where the detector saw a key signature in the bar: the
    /// reader, judging a line in context, can give the line's first bar a key printed only after a double bar
    /// further along, which moves the change bars early (and with it every accidental between). The clef likewise
    /// changes only where a clef is printed: old parts print one on the first line only, and the reader guessed
    /// an alto clef for some of the bare lines. A staff's first bar takes the reader's key and clef as they are.
    static func barState(_ rd: Reading, _ staff: Int, _ bar: Int, _ prev: BarState, first: Bool = false,
                         ensemble: Bool = true) -> BarState {
      var state = prev
      if let r = rd.tok[rd.layout.staves[staff].bars[bar]], r.hasBarHeads {
        if let k = r.key, first || k == prev.key || keySignatureSeen(rd, staff, bar) { state.key = k }
        if let t = r.time { state.time = t }
        if let c = r.clef {
          // a page's first bar takes the reader's clef, but a lead sheet's (one or two parts) only turns into
          // percussion on a sure percussion clef: its bare first lines were read as drums
          let seen = c == prev.clef || clefSeen(rd, staff, bar, to: c)
            || first && (c != "perc" || ensemble)
          if seen { state.clef = seenClef(rd, staff, bar, c) }
        }
      }
      return state
    }

    /// The detector's surest bar line taken for a percussion clef (a Real Book's hand-drawn "‖:" at 0.85); real
    /// ones read 0.92-0.95. In an ensemble a drum staff's small clef can be missed or misread on later pages, so a
    /// part's first bar there takes the reader's clef as it is.
    static let percussionClefP = 0.9

    /// Whether a clef is printed in the bar for a change to `to`: a pitched clef for a pitched one, a sure
    /// percussion clef for percussion.
    static func clefSeen(_ rd: Reading, _ staff: Int, _ bar: Int, to: String) -> Bool {
      rd.layout.syms.contains { s in
        s.staff == staff && s.bar == bar && isReal(rd, s.i) && family(cls(rd, s.i)) == "clef"
          && (to == "perc" ? clefOfCls(cls(rd, s.i)) == "perc" && s.p >= percussionClefP : clefOfCls(cls(rd, s.i)) != "perc")
      }
    }

    /// A bar of rhythm slashes found on the page (`Slashes.bars`): one stemless note per beat on the middle line,
    /// however many slashes were found or read, in a meter counted in quarters. Nil for any other bar.
    static func slashEvents(_ rd: Reading, _ staff: Int, _ bar: Int, _ state: BarState) -> [Event]? {
      guard let found = rd.slashBars[staff]?[bar] else { return nil }
      let parts = state.time.split(separator: "/").compactMap { Int($0) }
      guard parts.count == 2, parts[1] == 4, (2...6).contains(parts[0]), found <= parts[0] else { return nil }
      let L = rd.layout, st = L.staves[staff]
      let left = L.syms[st.bars[bar]].box.0
      let right = bar + 1 < st.bars.count ? L.syms[st.bars[bar + 1]].box.0 : st.x1
      let (step, octave) = pitch(state.clef, 0)
      return (0..<parts[0]).map { i in
        let e = Event(x: left + (Double(i) + 0.5) * (right - left) / Double(parts[0]), kind: "note")
        e.typ = "quarter"; e.voice = 1; e.step = step; e.octave = octave
        e.alter = Vocab.keyAlter(step, state.key); e.stem = "none"
        return e
      }
    }

    static func keySignatureSeen(_ rd: Reading, _ staff: Int, _ bar: Int) -> Bool {
      rd.layout.syms.contains { s in
        s.staff == staff && s.bar == bar && isReal(rd, s.i) && family(cls(rd, s.i)) == "keySig"
      }
    }

    // MARK: a bar's events
    static func events(_ rd: Reading, _ staff: Int, _ bar: Int, clef: String, key: Int) -> ([Event], [Dir], Marks) {
      let L = rd.layout
      let st = L.staves[staff], sp = st.sp
      let syms = Front.stableSorted(L.syms.filter { $0.staff == staff && $0.bar == bar && isReal(rd, $0.i) && $0.fam != "measure" }) { $0.cx < $1.cx }
      let clefSyms = syms.filter { family(cls(rd, $0.i)) == "clef" }
      let clefChanges = clefSyms.map { ($0.cx, seenClef(rd, $0)) }.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
      let notesX = syms.filter { ["note", "rest"].contains(family(cls(rd, $0.i))) }.map(\.cx)
      let firstX = notesX.min() ?? .infinity
      let midClefs = clefChanges.filter { $0.0 > firstX }
      var events: [Event] = [], dirs: [Dir] = [], marks = Marks()
      var markDirs: [(Double, String)] = []
      marks.endClef = midClefs.last?.1
      marks.meter = syms.contains { family(cls(rd, $0.i)) == "meterSig" }
      let bb = L.syms[st.bars[bar]].box
      let bmid = (bb.0 + bb.2) / 2
      for s in syms {
        let r = rd.tok[s.i]!
        let c = rd.classes[r.cls], f = family(c)
        func timed(_ e: Event) {
          e.onset = r.onset; e.onsetP = r.onsetP ?? 0
          if let b = r.onsetBeatP, let fr = r.onsetFracP { e.dist = (b, fr, r.tupP) }
          e.valueP = r.valueP; e.dotsP = r.dotsP
        }
        if f == "note" {
          var cur = clef
          for (x, cc) in midClefs where x < s.cx { cur = cc }
          let (step, octv) = pitch(cur, r.pos)
          let e = Event(x: s.cx, kind: "note")
          e.typ = Vocab.typeOf(c); e.dots = r.dots; e.voice = r.voice; e.chord = (r.chord ?? 0) > 0.5
          e.grace = r.grace; e.tup = r.tup; e.step = step; e.octave = octv
          e.alter = r.alter ?? Vocab.keyAlter(step, key)
          e.tie = (r.tie ?? 0) > 0.5; e.unpitched = cur == "perc"; e.si = s.i
          let stem = s.attrs["stem_dir"] ?? ""
          e.stem = stem == "up" || stem == "down" ? stem : ""
          timed(e)
          events.append(e)
        } else if f == "rest" {
          let e = Event(x: s.cx, kind: "rest")
          e.typ = Vocab.typeOf(c); e.dots = r.dots; e.voice = r.voice; e.tup = r.tup; e.si = s.i
          timed(e)
          events.append(e)
        } else if f == "mRest" || f == "multiRest" {
          if f == "multiRest" { marks.multirest = 1 }
          let e = Event(x: s.cx, kind: "mrest"); e.voice = 1; e.si = s.i
          events.append(e)
        } else if f == "mRpt" || f == "multiRpt" {
          marks.repeatBar = true
        } else if f == "dynam" && dyn.contains(String(c.dropFirst(6))) && keptDynamic(s, st) {
          dirs.append(Dir(x: s.cx, kind: "dyn", payload: String(c.dropFirst(6)), below: s.cy > st.mid))
        } else if f == "hairpin" && (c == "hairpin_cres" || c == "hairpin_dim") {
          dirs.append(Dir(x: s.box.0, kind: "wedge", payload: c == "hairpin_cres" ? "crescendo" : "diminuendo", below: s.cy > st.mid))
          dirs.append(Dir(x: s.box.2, kind: "wedge", payload: "stop", below: s.cy > st.mid))
        } else if lookup(artic, c) != nil || lookup(tech, c) != nil || lookup(ornament, c) != nil || c == "fermata" {
          markDirs.append((s.cx, c))
        } else if lookup(afterMark, c) != nil {
          let left = events.filter { $0.kind == "note" && $0.x < s.cx && s.cx - $0.x < 5 * sp }
          if var m = left.first {
            for e in left.dropFirst() where e.x > m.x { m = e }
            m.marks.append(c)
          }
        } else if f == "barLine" {
          if c == "barLine_repeat_start" && s.cx < bmid { marks.left = "repeat_start" } else if barRight[c] != nil && s.cx >= bmid { marks.right = c }
        } else if f == "clef" && s.cx > firstX {
          dirs.append(Dir(x: s.cx, kind: "clef", payload: seenClef(rd, s)))
        }
      }
      decodeAlters(rd, syms, events, sp)
      for (x, c) in markDirs {
        let cands = events.filter { $0.kind == "note" && abs($0.x - x) < 1.5 * sp }
        if var best = cands.first {
          for e in cands.dropFirst() where abs(e.x - x) < abs(best.x - x) { best = e }
          best.marks.append(c)
        }
      }
      return (events, dirs, marks)
    }

    static func decodeAlters(_ rd: Reading, _ syms: [Sym], _ events: [Event], _ sp: Double) {
      let L = rd.layout
      let heads = events.filter { $0.kind == "note" && !$0.unpitched }
      var pairs: [(Double, Int, Int, Int, String)] = []
      for s in syms {
        let c = cls(rd, s.i)
        let kind = String(c.dropFirst("accid_".count))
        guard family(c) == "accid", let alt = accidAlter[kind] else { continue }
        let ay = s.cy + (accAnchor[kind] ?? 0) * sp
        for e in heads {
          let h = L.syms[e.si]
          let gap = h.box.0 - s.box.2, dy = abs(h.cy - ay)
          if -0.5 * sp < gap && gap < 5 * sp && dy < 0.4 * sp {
            pairs.append((3 * dy / sp + max(0, gap) / sp, s.i, e.si, alt, kind))
          }
        }
      }
      pairs.sort { ($0.0, $0.1, $0.2, $0.3, $0.4) < ($1.0, $1.1, $1.2, $1.3, $1.4) }
      var glyph: [Int: (Int, String)] = [:], used = Set<Int>()
      for (_, gi, ei, alt, kind) in pairs where !used.contains(gi) && glyph[ei] == nil {
        used.insert(gi); glyph[ei] = (alt, kind)
      }
      var held: [String: Int] = [:]
      for e in Front.stableSorted(heads, by: { L.syms[$0.si].cx < L.syms[$1.si].cx }) {
        let line = "\(e.step)\(e.octave)"
        var kind: String?
        let rule: Int
        if let g = glyph[e.si] { rule = g.0; kind = g.1; held[line] = rule } else if let h = held[line] { rule = h } else { continue }
        if rule != e.alter && (rd.tok[e.si]!.heads["alter"]?.p ?? 0) < alterKeepP { e.alter = rule }
        if let kind, accidAlter[kind] == e.alter, let x = accidXML[kind] { e.accidental = x }
      }
    }

    // MARK: voices and rhythm
    static func voices(_ events: [Event], _ sp: Double, singleStaffPart: Bool, barLen: Q?, score: inout [Double],
                       fitBar: Bool = false) -> Voices {
      var vs = Voices()
      for e in Front.stableSorted(events, by: { $0.x < $1.x }) { vs[e.voice] = (vs[e.voice] ?? []) + [e] }
      let nVoices = vs.order.count
      for v in vs.order {
        let evs = vs[v]!
        let roots = evs.filter { $0.kind == "note" && $0.grace == "none" && !$0.chord }
        var members: [ObjectIdentifier: [Event]] = [:]
        var order: [Event] = []
        for e in evs {
          if e.kind == "note" && e.chord && e.grace == "none" {
            let near = roots.filter { abs($0.x - e.x) <= 1.5 * sp }
            if var r = near.first {
              for q in near.dropFirst() where abs(q.x - e.x) < abs(r.x - e.x) { r = q }
              members[ObjectIdentifier(r), default: []].append(e)
              continue
            }
            e.chord = false
          }
          order.append(e)
        }
        let strict = singleStaffPart && nVoices == 1
        var refit = Set<ObjectIdentifier>()
        let read = order.map { ($0.typ, $0.dots, $0.tup) }
        if let sc = decodeRhythm(order, strict: strict, barLen: barLen) {
          score.append(sc)
          if fitBar, let barLen,
             let e = fitOneValue(order, read: read, strict: strict, barLen: barLen, score: sc) {
            refit.insert(ObjectIdentifier(e))
          }
        }
        var out: [Event] = []
        var cursor = Q.zero
        for e in order {
          e.dur = e.grace != "none" ? Q.zero : Vocab.duration(e.typ, e.dots, e.tup)
          if e.grace == "none", let on = e.onset, e.onsetP >= onsetP {
            let at = Q(pyRound(on * 48), 48)
            if at != cursor {
              let g = Event(x: e.x - 0.01, kind: "gap"); g.voice = e.voice; g.dur = at - cursor
              out.append(g)
              cursor = at
            }
          }
          out.append(e)
          cursor += e.dur
          for m in members[ObjectIdentifier(e)] ?? [] {
            m.dur = e.dur; m.tup = e.tup
            // the bar fit gave the root another value: the notes of its chord take it too
            if refit.contains(ObjectIdentifier(e)) { m.typ = e.typ; m.dots = e.dots }
            out.append(m)
          }
        }
        let grouped = wholeTuplets(&out)
        vs[v] = out
        func close(_ run: [Event]) {
          if run.count > 1 { run[run.count - 1].tupletMark = "stop" } else if let f = run.first { f.tupletMark = "" }
        }
        var run: [Event] = [], nominal = Q.zero, target: Q?
        for e in out where !e.chord && e.grace == "none" {
          if grouped.contains(ObjectIdentifier(e)) || e.tup == "none" || e.tup == "other" {
            close(run); run = []; nominal = Q.zero; target = nil
            continue
          }
          let a = Int(e.tup.split(separator: "/")[0])!
          if run.isEmpty || run[0].tup != e.tup {
            close(run)
            run = [e]; nominal = Q.zero
            target = Q(a) * (Vocab.typeQ[e.typ] ?? Q(1))
            e.tupletMark = "start"
          } else { run.append(e) }
          nominal += (Vocab.typeQ[e.typ] ?? Q(1)) * (Q(2) - Q(1, 1 << e.dots))
          if let t = target, nominal >= t { close(run); run = []; nominal = Q.zero; target = nil }
        }
        close(run)
      }
      return vs
    }

    /// Tuplets a score importer can read. The reader labels each note's tuplet on its own, so a run can come out with
    /// one note of a sextuplet labelled a triplet (the same length, another label), a note missing (a gap), or a
    /// stray tuplet value among plain notes. Importers take only whole groups; anything else they mark corrupt and
    /// stretch the bar, and the music after it drifts. Each run of tuplet notes of one length ratio (with the gaps
    /// inside it) is made whole, the first of these that works:
    /// - every stretch between the gaps already fills whole groups under one label: relabelled and bracketed so;
    /// - the run's notes fill it exactly at their plain values (sixteenths misread as triplets): written plain, in a
    ///   row from where the run starts;
    /// - stretch by stretch: one label, cut into whole groups, a short last (or first) group finished with hidden
    ///   tuplet rests from the gap beside it, so no note moves; or a lone tuplet note that fits as its plain value
    ///   with the gap after it, written plain.
    /// Anything else is left as read. Returns the events now in whole, bracketed groups.
    static func wholeTuplets(_ out: inout [Event]) -> Set<ObjectIdentifier> {
      final class Unit {
        let head: Event
        var lead: [Event], tail: [Event] = []
        init(_ h: Event, _ l: [Event]) { head = h; lead = l }
      }
      enum Item { case unit(Unit), rest(String, Int) }
      var units: [Unit] = [], lead: [Event] = []
      for e in out {
        if e.grace != "none" { lead.append(e); continue }
        if e.chord, let u = units.last { u.tail.append(e); continue }
        units.append(Unit(e, lead)); lead = []
      }
      func ratio(_ t: String) -> Q? {
        guard t != "none", t != "other" else { return nil }
        let p = t.split(separator: "/").compactMap { Int($0) }
        return p.count == 2 && p[0] > 0 && p[1] > 0 ? Q(p[1], p[0]) : nil
      }
      func isTup(_ u: Unit) -> Bool { (u.head.kind == "note" || u.head.kind == "rest") && ratio(u.head.tup) != nil }
      func isGap(_ u: Unit) -> Bool { u.head.kind == "gap" && Q.zero < u.head.dur }
      func plain(_ e: Event) -> Q { Vocab.duration(e.typ, e.dots, "none") }
      func floor(_ q: Q) -> Int { q.n >= 0 ? q.n / q.d : -((-q.n + q.d - 1) / q.d) }
      // rest values (plain or dotted, down to a 64th) that add up to `q`, longest first
      let restValues = Vocab.typeQuarters.flatMap { t in [(t.0, 1, t.1 * Q(3, 2)), (t.0, 0, t.1)] }
        .filter { !($0.2 < Q(1, 16)) }
      func rests(_ q: Q) -> [(String, Int)]? {
        var left = q, made: [(String, Int)] = []
        while Q.zero < left {
          guard made.count < 4, let v = restValues.first(where: { !(left < $0.2) }) else { return nil }
          made.append((v.0, v.1)); left -= v.2
        }
        return made
      }
      // `seg` cut into whole groups of `label` whose notes are `unit` long; nil when a note would cross a group's
      // end, a group would hold one item or only hidden rests, or the gap beside it lacks the time to finish one
      func cut(_ seg: [Unit], _ label: String, _ unit: Q, before: Q, after: Q) -> (groups: [[Item]], takeBefore: Q, takeAfter: Q)? {
        guard let r = ratio(label), let a = Int(label.split(separator: "/")[0]) else { return nil }
        let G = Q(a) * unit
        var items: [(Unit?, Q)] = seg.map { $0.head.kind == "gap" ? (nil, $0.head.dur / r) : ($0, plain($0.head)) }
        let N = items.reduce(Q.zero) { $0 + $1.1 }
        let whole = Q(floor(N / G)) * G
        let short = whole == N ? Q.zero : whole + G - N
        var takeB = Q.zero, takeA = Q.zero
        if Q.zero < short {
          if !(after < short * r) { items.append((nil, short)); takeA = short * r }
          else if !(before < short * r) { items.insert((nil, short), at: 0); takeB = short * r }
          else { return nil }
        }
        var groups: [[Item]] = [], cur: [Item] = [], cum = Q.zero
        for (u, q) in items {
          var q = q
          if let u {
            let end = Q(floor(cum / G) + 1) * G
            if end < cum + q { return nil }
            cur.append(.unit(u)); cum += q
            if cum == end { groups.append(cur); cur = [] }
            continue
          }
          while Q.zero < q {
            let end = Q(floor(cum / G) + 1) * G
            let piece = min(q, end - cum)
            guard let rs = rests(piece) else { return nil }
            cur += rs.map { .rest($0.0, $0.1) }
            cum += piece; q -= piece
            if cum == end { groups.append(cur); cur = [] }
          }
        }
        guard cur.isEmpty else { return nil }
        for g in groups {
          guard g.count > 1, g.contains(where: { if case .unit = $0 { return true } else { return false } }) else { return nil }
        }
        return (groups, takeB, takeA)
      }
      // the labels to try (most used first) and the note values a group can be counted in (the first note's first)
      func tryCut(_ seg: [Unit], before: Q, after: Q) -> (groups: [[Item]], label: String, takeBefore: Q, takeAfter: Q)? {
        let real = seg.filter { $0.head.kind != "gap" }
        guard let first = real.first else { return nil }
        var count: [String: Int] = [:], labels: [String] = []
        for u in real { if count[u.head.tup] == nil { labels.append(u.head.tup) }; count[u.head.tup, default: 0] += 1 }
        labels = labels.enumerated().sorted { (count[$0.element]!, -$0.offset) > (count[$1.element]!, -$1.offset) }.map(\.element)
        var values = [Vocab.typeQ[first.head.typ] ?? Q(1)]
        for v in real.compactMap({ Vocab.typeQ[$0.head.typ] }).sorted(by: >) where !values.contains(v) { values.append(v) }
        for l in labels {
          for v in values {
            if let c = cut(seg, l, v, before: before, after: after) { return (c.groups, l, c.takeBefore, c.takeAfter) }
          }
        }
        return nil
      }
      // Keep independent, complete groups as evidence even after this pass rewrites their labels.
      var wholeRatios = Set<Q>()
      var stretch: [Unit] = []
      func rememberStretch() {
        if let first = stretch.first, let r = ratio(first.head.tup),
           tryCut(stretch, before: Q.zero, after: Q.zero) != nil { wholeRatios.insert(r) }
        stretch = []
      }
      for u in units {
        if !isTup(u) || (!stretch.isEmpty && ratio(stretch[0].head.tup) != ratio(u.head.tup)) { rememberStretch() }
        if isTup(u) { stretch.append(u) }
      }
      rememberStretch()
      // Compare the two readings using both onset and tuplet evidence. Average the log likelihoods:
      // predictions within one group are correlated. Charge the gapped reading the decoder's existing
      // gap prior; exact duration alone is not evidence for moving a note or discarding a tuplet.
      func plainEvidence(_ run: [Unit], at start: Q, ratio r: Q) -> Bool {
        var at = start, proposed = start, gain = 0.0, count = 0, gaps = 0
        func onsetLogp(_ e: Event, _ q: Q) -> Double? {
          let tick = q * Q(48)
          guard tick.d == 1, tick.n >= 0, let d = e.dist,
                tick.n / 48 < d.beat.count, tick.n % 48 < d.frac.count else { return nil }
          return log(max(1e-6, d.beat[tick.n / 48])) + log(max(1e-6, d.frac[tick.n % 48]))
        }
        for u in run {
          let e = u.head
          defer { at += e.dur }
          if isGap(u) { gaps += 1; continue }
          guard let tp = e.dist?.tup, tp.count == Vocab.tuplets.count,
                let old = onsetLogp(e, at), let new = onsetLogp(e, proposed) else { return false }
          let p = Vocab.tuplets.enumerated().reduce(0.0) { total, t in
            total + (ratio(t.element) == r ? tp[t.offset] : 0)
          }
          gain += new - old + log(max(1e-6, tp[0])) - log(max(1e-6, p))
          count += 1; proposed += plain(e)
        }
        return count > 0 && gain / Double(count) > Double(gaps) * gapLogp
      }
      var grouped = Set<ObjectIdentifier>()
      func bracket(_ groups: [[Item]], _ label: String, voice: Int) -> [Unit] {
        var made: [Unit] = []
        let firstX = groups.lazy.flatMap { $0 }.compactMap { if case .unit(let u) = $0 { return u.head.x } else { return nil } }.first ?? 0
        var x = firstX - 0.002
        for g in groups {
          var heads: [Event] = []
          for it in g {
            switch it {
            case .unit(let u):
              u.head.tup = label; u.head.dur = Vocab.duration(u.head.typ, u.head.dots, label); x = u.head.x
              for m in u.tail { m.tup = label; m.dur = u.head.dur }
              made.append(u); heads.append(u.head)
            case .rest(let t, let d):
              let e = Event(x: x + 0.001, kind: "rest")
              x = e.x
              e.voice = voice; e.typ = t; e.dots = d; e.tup = label; e.hidden = true
              e.dur = Vocab.duration(t, d, label)
              made.append(Unit(e, [])); heads.append(e)
            }
          }
          for h in heads { h.tupletMark = ""; grouped.insert(ObjectIdentifier(h)) }
          heads[0].tupletMark = "start"; heads[heads.count - 1].tupletMark = "stop"
        }
        return made
      }
      // written plain, in a row; a stretch left over at the end stays a gap
      func plainRow(_ seg: [Unit], tailGap: Q, voice: Int) -> [Unit] {
        var made: [Unit] = []
        for u in seg where u.head.kind != "gap" {
          u.head.tup = "none"; u.head.tupletMark = ""; u.head.dur = plain(u.head)
          for m in u.tail { m.tup = "none"; m.dur = u.head.dur }
          made.append(u)
        }
        if Q.zero < tailGap {
          let g = Event(x: (made.last?.head.x ?? 0) + 0.001, kind: "gap")
          g.voice = voice; g.dur = tailGap
          made.append(Unit(g, []))
        }
        return made
      }
      let grid = Q(1, 32)
      var pos: [Q] = [Q.zero]
      for u in units { pos.append(pos[pos.count - 1] + u.head.dur) }
      var i = 0
      while i < units.count {
        guard isTup(units[i]), let r = ratio(units[i].head.tup) else { i += 1; continue }
        var last = i, j = i + 1
        while j < units.count {
          if isTup(units[j]) && ratio(units[j].head.tup) == r { last = j; j += 1 } else if isGap(units[j]) { j += 1 } else { break }
        }
        let voice = units[i].head.voice
        let before = i > 0 && isGap(units[i - 1]) ? units[i - 1].head : nil
        let after = last + 1 < units.count && isGap(units[last + 1]) ? units[last + 1].head : nil
        // the stretches between the gaps inside the run, and those gaps
        var segs: [[Unit]] = [[]], seps: [Event?] = []
        for u in units[i...last] {
          if u.head.kind == "gap" {
            if segs[segs.count - 1].isEmpty, let g = seps.last, let g { g.dur += u.head.dur; u.head.dur = Q.zero; continue }
            segs.append([]); seps.append(u.head)
          } else { segs[segs.count - 1].append(u) }
        }
        var made: [[Unit]]? = nil
        // already whole stretch by stretch
        let fits = segs.map { tryCut($0, before: Q.zero, after: Q.zero) }
        if fits.allSatisfy({ $0 != nil }) {
          made = zip(fits, segs).map { bracket($0.0!.groups, $0.0!.label, voice: voice) }
        }
        // A gap can be a missed member of one group, not a boundary between two groups.
        // Try completing the entire run without moving its recognised notes first.
        let run = Array(units[i...last])
        let acrossGap = seps.isEmpty ? nil : (tryCut(run, before: Q.zero, after: Q.zero)
          ?? tryCut(run, before: before?.dur ?? Q.zero, after: after?.dur ?? Q.zero))
        if made == nil {
          let real = run.filter { $0.head.kind != "gap" }
          let L = pos[last + 1] - pos[i], S = real.reduce(Q.zero) { $0 + plain($1.head) }
          if S == L && pos[i].isMultiple(of: grid) && pos[last + 1].isMultiple(of: grid)
            && (seps.isEmpty || (acrossGap?.groups.count == 1 && !wholeRatios.contains(r) && plainEvidence(run, at: pos[i], ratio: r))) {
            made = [plainRow(run, tailGap: Q.zero, voice: voice)]
            seps = []
          } else if let c = acrossGap {
            before?.dur -= c.takeBefore; after?.dur -= c.takeAfter
            made = [bracket(c.groups, c.label, voice: voice)]
            seps = []
          }
        }
        if made == nil {
          var parts: [[Unit]] = []
          var at = pos[i]
          for (k, seg) in segs.enumerated() {
            let gb = k == 0 ? before : seps[k - 1], ga = k < seps.count ? seps[k] : after
            let segLen = seg.reduce(Q.zero) { $0 + $1.head.dur }
            let next = at + segLen + (k < seps.count ? seps[k]!.dur : Q.zero)
            defer { at = next }
            if let c = tryCut(seg, before: Q.zero, after: Q.zero) ?? tryCut(seg, before: gb?.dur ?? Q.zero, after: ga?.dur ?? Q.zero) {
              gb?.dur -= c.takeBefore; ga?.dur -= c.takeAfter
              parts.append(bracket(c.groups, c.label, voice: voice))
              continue
            }
            if seg.count == 1, let ga, at.isMultiple(of: grid) {
              let need = plain(seg[0].head) - segLen
              if !(ga.dur < need), (at + plain(seg[0].head)).isMultiple(of: grid) {
                ga.dur -= need
                parts.append(plainRow(seg, tailGap: Q.zero, voice: voice))
                continue
              }
            }
            parts.append(seg)
          }
          made = parts
        }
        var region: [Unit] = []
        for (k, p) in made!.enumerated() {
          region += p
          if k < seps.count, let g = seps[k], let u = units[i...last].first(where: { $0.head === g }) { region.append(u) }
        }
        units.replaceSubrange(i...last, with: region)
        pos = [Q.zero]
        for u in units { pos.append(pos[pos.count - 1] + u.head.dur) }
        i += region.count
        if region.isEmpty { i += 1 }
      }
      out = units.flatMap { $0.lead + [$0.head] + $0.tail } + lead
      return grouped
    }

    /// Where a voice's notes end in its bar (as `voices` lays them out from the decoded onsets), and how many start
    /// before the note ahead of them ends.
    static func reach(_ order: [Event]) -> (end: Q, overlaps: Int) {
      var cursor = Q.zero, overlaps = 0
      for e in order where e.grace == "none" {
        if let on = e.onset, e.onsetP >= onsetP {
          let at = Q(pyRound(on * 48), 48)
          if at < cursor { overlaps += 1 }
          cursor = at
        }
        cursor += Vocab.duration(e.typ, e.dots, e.tup)
      }
      return (cursor, overlaps)
    }

    /// The least a runner-up value or dot count must weigh for the bar fit to try it.
    static let runnerUpP = 0.05

    /// A voice that runs past its bar's end is mostly one misread value: a quarter read for an eighth, a dot that
    /// is not there. Each note in turn takes its runner-up values and dot counts as the model weighs them (at least
    /// `runnerUpP`), and the rhythm is decoded again. The most believable reading that ends within the bar (decoded
    /// fit plus the change's log weight against the reading it replaces), and no more overlapping than before, is
    /// kept when it beats the overflowing one. Otherwise the voice stays as read, and the bar keeps its own meter
    /// ("check bar"). A bar the decoder fitted only by making notes tuplets the model ruled out (below
    /// `runnerUpP`) is overfull in disguise, and is tried the same way. `read`: each event's value, dots and tuplet
    /// as read, before decoding.
    @discardableResult
    static func fitOneValue(_ order: [Event], read: [(String, Int, String)], strict: Bool, barLen: Q, score: Double) -> Event? {
      let before = reach(order)
      // the decoder can also squeeze an overfull bar by making notes tuplets the model ruled out
      let forced = zip(order, read).contains { e, r in
        guard e.tup != r.2, let tp = e.dist?.tup, let k = Vocab.tuplets.firstIndex(of: e.tup) else { return false }
        return tp[k] < runnerUpP
      }
      guard before.end > barLen || forced else { return nil }
      func restore() { for (e, r) in zip(order, read) { e.typ = r.0; e.dots = r.1; e.tup = r.2 } }
      var best: (i: Int, typ: String, dots: Int, total: Double)?
      for (i, e) in order.enumerated()
      where e.grace == "none" && (e.kind == "note" || e.kind == "rest") && e.dist != nil {
        var tries: [(String, Int, Double)] = []
        if let vp = e.valueP {
          let now = max(vp[read[i].0] ?? 0, 1e-6)
          for (t, p) in vp where t != read[i].0 && p >= runnerUpP { tries.append((t, read[i].1, log(p / now))) }
        }
        if let dp = e.dotsP, dp.indices.contains(read[i].1) {
          let now = max(dp[read[i].1], 1e-6)
          for (d, p) in dp.enumerated() where d != read[i].1 && p >= runnerUpP { tries.append((read[i].0, d, log(p / now))) }
        }
        for (t, d, cost) in tries.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
          restore()
          e.typ = t; e.dots = d
          guard let sc = decodeRhythm(order, strict: strict, barLen: barLen) else { continue }
          let after = reach(order)
          guard after.end <= barLen, after.overlaps <= before.overlaps else { continue }
          let total = sc + cost
          if total > score && (best == nil || total > best!.total) { best = (i, t, d, total) }
        }
      }
      restore()
      if let best { order[best.i].typ = best.typ; order[best.i].dots = best.dots }
      _ = decodeRhythm(order, strict: strict, barLen: barLen)
      return best.map { order[$0.i] }
    }

    static func decodeRhythm(_ order: [Event], strict: Bool, barLen: Q?) -> Double? {
      let evs = order.filter { $0.grace == "none" && ($0.kind == "note" || $0.kind == "rest") && $0.dist != nil }
      guard !evs.isEmpty else { return nil }
      let G = 48, K = 16 * G
      let NEG = -1e18
      let L48 = barLen.map { Int(($0 * Q(G)).double.rounded(.towardZero)) } ?? K
      func emit(_ e: Event) -> [Double] {
        let pb = e.dist!.beat.map { log(min(max($0, 1e-6), 1)) }, pf = e.dist!.frac.map { log(min(max($0, 1e-6), 1)) }
        var out = [Double](repeating: 0, count: K)
        for b in 0..<16 { for f in 0..<G { out[b * G + f] = pb[b] + pf[f] } }
        if L48 < K { for k in max(0, L48)..<K { out[k] += pastBarLogp } }
        return out
      }
      func tupLogp(_ e: Event, _ t: String) -> Double {
        guard let tp = e.dist!.tup else { return t == e.tup ? 0 : log(0.05) }
        return log(max(1e-6, tp[Vocab.tuplets.firstIndex(of: t)!]))
      }
      func dur48(_ e: Event, _ t: String) -> Int? {
        let d = Vocab.duration(e.typ, e.dots, t) * Q(G)
        return d.d == 1 ? d.n : nil
      }
      func endLogp(_ e: Event, _ t: String) -> ([Double], [Double]) {
        let d = t != "other" ? dur48(e, t) : nil
        guard let d, d != 0 else { return ([Double](repeating: 0, count: K), [Double](repeating: 0, count: K)) }
        return ((0..<K).map { $0 + d > L48 ? pastBarLogp : 0 }, (0..<K).map { $0 + d < L48 ? endGapLogp : 0 })
      }
      func argmaxFirst(_ a: [Double]) -> Int { var k = 0; for i in 1..<a.count where a[i] > a[k] { k = i }; return k }
      if evs.count == 1 {
        let (over, short) = endLogp(evs[0], evs[0].tup)
        let em = emit(evs[0])
        return (0..<K).map { em[$0] + over[$0] + short[$0] }.max()!
      }
      let choices: [[String]] = evs.map { e in
        var seen: [String] = []
        for t in ["none", "3/2", e.tup] where !seen.contains(t) { seen.append(t) }
        return seen.filter { $0 != "other" && (dur48(e, $0) ?? 0) != 0 }
      }
      var score = emit(evs[0])
      var back: [[(Int, Int, Int)]] = []
      for i in 1..<evs.count {
        let prev = evs[i - 1], e = evs[i]
        let em = emit(e)
        var best = [Double](repeating: NEG, count: K)
        var arg = [(Int, Int, Int)](repeating: (0, 0, 0), count: K)
        var pref = score, prefArg = [Int](repeating: 0, count: K)
        for k in 1..<K { pref[k] = max(pref[k - 1], score[k]) }
        var pa = 0
        for k in 0..<K { if score[k] >= pref[k] { pa = max(pa, k) }; prefArg[k] = pa }
        var suf = score, sufArg = [Int](repeating: K, count: K)
        for k in stride(from: K - 2, through: 0, by: -1) { suf[k] = max(suf[k + 1], score[k]) }
        var sa = K
        for k in stride(from: K - 1, through: 0, by: -1) { if score[k] >= suf[k] { sa = min(sa, k) }; sufArg[k] = sa }
        for (c, t) in choices[i - 1].enumerated() {
          guard let d = dur48(prev, t), d > 0, d < K else { continue }
          let tl = tupLogp(prev, t)
          for j in d..<K {
            let v = score[j - d] + tl
            if v > best[j] { best[j] = v; arg[j] = (j - d, c, 0) }
          }
          if d + 1 < K {
            for j in (d + 1)..<K {
              let v = pref[j - d - 1] + tl + gapLogp
              if v > best[j] { best[j] = v; arg[j] = (prefArg[j - d - 1], c, 1) }
            }
          }
          if strict { continue }
          for j in 0..<K {
            let lo = min(max(j - d + 1, 0), K - 1)
            var o = suf[lo] + tl + overlapLogp, osrc = sufArg[lo]
            let same = score[j] + tl + sameOnsetLogp
            if same > o { o = same; osrc = j }
            if o > best[j] { best[j] = o; arg[j] = (osrc, c, 2) }
          }
        }
        score = (0..<K).map { best[$0] + em[$0] }
        back.append(arg)
      }
      let (over, short) = endLogp(evs[evs.count - 1], evs[evs.count - 1].tup)
      score = (0..<K).map { score[$0] + over[$0] }
      var j = argmaxFirst(score)
      let total = score[j] + short[j]
      var states = [j], picks: [Int] = []
      for arg in back.reversed() {
        let (k, c, _) = arg[j]
        picks.append(c); states.append(k); j = k
      }
      states.reverse(); picks.reverse()
      for (i, e) in evs.enumerated() {
        e.onset = Double(states[i]) / Double(G); e.onsetP = 1.0
        if i < picks.count { e.tup = choices[i][picks[i]] }
      }
      return total
    }

    // MARK: ties
    static func drawnTies(_ rd: Reading, _ pairs: [(Event, Event?, Bool)]) -> Set<Int> {
      let L = rd.layout, sym = L.syms
      let curves = sym.filter { $0.staff >= 0 && isReal(rd, $0.i) && cls(rd, $0.i) == "curve" }
      func beside(_ c: Sym, _ a: Sym, _ reach: Double = 0.5) -> Bool {
        let sp = L.staves[a.staff].sp
        return max(c.box.1 - a.cy, a.cy - c.box.3) <= tieRise * sp && a.box.0 - reach * sp <= c.box.0 && c.box.0 <= a.box.2 + 1.5 * sp
      }
      var edges: [(Double, Int, Int)] = []
      for (n, (e, f, _)) in pairs.enumerated() {
        guard let f, e.si >= 0, f.si >= 0 else { continue }
        let a = sym[e.si], z = sym[f.si]
        let st = L.staves[a.staff]
        let sp = st.sp, across = L.staves[z.staff].system != st.system
        for c in curves where c.staff == a.staff && beside(c, a) {
          if across && c.box.2 < st.x1 - 3 * sp { continue }
          if !across && !(z.box.0 - 1.5 * sp <= c.box.2 && c.box.2 <= z.box.2 + 0.5 * sp) { continue }
          edges.append(((abs(c.cy - a.cy) + abs(c.box.0 - a.box.2)) / sp, n, c.i))
        }
      }
      var kept = Set<Int>(), used = Set<Int>()
      for (_, n, c) in edges.sorted(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }) where !kept.contains(n) && !used.contains(c) {
        kept.insert(n); used.insert(c)
      }
      for (n, (e, f, nxt)) in pairs.enumerated() {
        guard !kept.contains(n), let f else { continue }
        if e.si < 0 || f.si < 0 { if nxt { kept.insert(n) }; continue }
        let a = sym[e.si], z = sym[f.si]
        let sp = L.staves[a.staff].sp
        let far = L.staves[z.staff].system != L.staves[a.staff].system || z.box.0 - a.box.2 > tieFar * sp
        let slur = curves.contains { !used.contains($0.i) && $0.staff == a.staff && beside($0, a, 1.5) }
        if !(far && !nxt) && !slur { kept.insert(n) }
      }
      return kept
    }

    // MARK: beams, slurs and other spanners
    static func attach(_ rd: Reading, _ built: [[[StaffBar?]]], _ plans: [[Int]], _ place: [[Int: Int]]) {
      let L = rd.layout, sym = L.syms
      var slot: [Int: Int] = [:]
      for at in place { for (p, k) in at { slot[k] = p } }
      var notesOn: [Int: [Event]] = [:], notesOrder: [Int] = []
      for measures in built {
        for m in measures {
          for st in m {
            guard let st else { continue }
            for evs in st.voices.values {
              for e in evs where e.kind == "note" && !e.copied && e.si >= 0 {
                let k = sym[e.si].staff
                if notesOn[k] == nil { notesOrder.append(k) }
                notesOn[k, default: []].append(e)
              }
            }
          }
        }
      }
      for k in notesOrder { notesOn[k] = Front.stableSorted(notesOn[k]!) { $0.x < $1.x } }
      let spanners = sym.filter { $0.staff >= 0 && isReal(rd, $0.i) }
      var claimed = Set<ObjectIdentifier>()
      var partOf: [Int: Int] = [:]
      for (pi, pl) in plans.enumerated() { for pos in pl { partOf[pos] = pi } }
      func part(_ k: Int, _ fallback: Int) -> Int { slot[k].flatMap { partOf[$0] } ?? fallback }

      // beams
      for b in Front.stableSorted(spanners.filter { cls(rd, $0.i) == "beam" }, by: { $0.box.0 < $1.box.0 }) {
        let sp = L.staves[b.staff].sp
        let stB = L.staves[b.staff]
        let near = [b.staff] + [b.staff - 1, b.staff + 1].filter {
          0 <= $0 && $0 < L.staves.count && L.staves[$0].system == stB.system && part($0, -1) == part(b.staff, -2)
        }
        var under: [Event] = []
        for k in near {
          for e in notesOn[k] ?? [] where !e.chord && e.grace == "none" && !claimed.contains(ObjectIdentifier(e)) {
            let h = sym[e.si].box
            let x = b.cy < sym[e.si].cy ? h.2 : h.0
            guard b.box.0 - beamReach * sp <= x && x <= b.box.2 + beamReach * sp else { continue }
            guard abs(sym[e.si].cy - b.cy) <= (k == b.staff ? 8 : 4.5) * sp, beamLevel[e.typ] != nil else { continue }
            under.append(e)
          }
        }
        if under.count < 2 { continue }
        let vset = Array(Set(under.map(\.voice))).sorted()
        var voice = vset[0]
        for v in vset.dropFirst() where under.filter({ $0.voice == v }).count > under.filter({ $0.voice == voice }).count { voice = v }
        let group = Front.stableSorted(under.filter { $0.voice == voice }) { $0.x < $1.x }
        if group.count < 2 { continue }
        let lv = group.map { beamLevel[$0.typ]! }
        for n in 1...lv.max()! {
          for (i, e) in group.enumerated() where lv[i] >= n {
            let prev = i > 0 && lv[i - 1] >= n
            let nxt = i + 1 < group.count && lv[i + 1] >= n
            var val = prev && nxt ? "continue" : nxt ? "begin" : prev ? "end" : (i + 1 < group.count ? "forward hook" : "backward hook")
            if n == 1 && val.hasSuffix("hook") { val = i == 0 ? "begin" : "end" }
            e.beams.append((n, val))
          }
        }
        for e in group {
          claimed.insert(ObjectIdentifier(e))
          if e.stem.isEmpty { e.stem = b.cy < sym[e.si].cy ? "up" : "down" }
        }
      }

      // slurs
      var nums: [Int: [((Int, Double), Int)]] = [:]
      var order: [ObjectIdentifier: (Int, Double)] = [:]
      for evs in notesOn.values { for e in evs { order[ObjectIdentifier(e)] = (L.staves[sym[e.si].staff].system, e.x) } }
      let curves = spanners.filter { cls(rd, $0.i) == "curve" }.enumerated().sorted {
        ($0.element.staff, $0.element.box.0, $0.offset) < ($1.element.staff, $1.element.box.0, $1.offset)
      }.map(\.element)
      for c in curves {
        let st = L.staves[c.staff], sp = st.sp
        let cand = (notesOn[c.staff] ?? []).filter { abs(sym[$0.si].cy - c.cy) <= 7 * sp }
        if cand.isEmpty { continue }
        let near = cand.filter { c.box.0 - sp <= sym[$0.si].cx && sym[$0.si].cx <= c.box.2 + sp }.map { sym[$0.si].cy }.sorted()
        let over = !near.isEmpty && c.cy < near[near.count / 2]
        let yend = over ? c.box.3 : c.box.1
        func cost(_ e: Event, _ x: Double) -> Double { abs(sym[e.si].cx - x) / sp + 0.5 * abs(sym[e.si].cy - yend) / sp }
        func argmin(_ x: Double) -> Event { var m = cand[0]; for e in cand.dropFirst() where cost(e, x) < cost(m, x) { m = e }; return m }
        let a = argmin(c.box.0)
        var z = argmin(c.box.2)
        if abs(sym[a.si].cx - c.box.0) > 2.5 * sp { continue }
        if abs(sym[z.si].cx - c.box.2) > 2.5 * sp {
          if c.box.2 < st.x1 - 3 * sp { continue }
          guard let nxt = nextSystemFirst(L, notesOn, c.staff, place) else { continue }
          z = nxt
        }
        if a === z { continue }
        if a.tie && a.step == z.step && a.octave == z.octave { continue }
        let oa = order[ObjectIdentifier(a)]!
        let busy = (nums[c.staff] ?? []).filter { $0.0 >= oa }.map(\.1)
        let num = busy.count < 6 ? (1...6).first { !busy.contains($0) }! : 1
        nums[c.staff, default: []].append((order[ObjectIdentifier(z)]!, num))
        a.slurs.append(("start", num)); z.slurs.append(("stop", num))
      }

      for s in spanners {
        let c = cls(rd, s.i)
        let sp = L.staves[s.staff].sp
        let evs = notesOn[s.staff] ?? []
        if c == "arpeg" {
          for e in evs {
            let ls = sym[e.si]
            if s.box.2 - 0.5 * sp <= ls.cx && ls.cx <= s.box.2 + 3 * sp && s.box.1 - sp <= ls.cy && ls.cy <= s.box.3 + sp { e.arpeggiate = true }
          }
        } else if octave[c] != nil || c == "octave_8" {
          let (shift, typ, size) = octave[c] ?? (s.cy < L.staves[s.staff].mid ? (1, "down", 8) : (-1, "up", 8))
          let inside = evs.filter { s.box.0 - sp <= sym[$0.si].cx && sym[$0.si].cx <= s.box.2 + sp }
          if let f = inside.first, let l = inside.last {
            for e in inside { e.octave += shift }
            f.pre.append(Dir(x: f.x, kind: "octave", payload: typ, size: size, below: shift < 0))
            l.post.append(Dir(x: l.x, kind: "octave", payload: "stop", size: size, below: shift < 0))
          }
        } else if c == "pedal" {
          let inside = evs.filter { s.box.0 - sp <= sym[$0.si].cx && sym[$0.si].cx <= s.box.2 + sp }
          if let f = inside.first, let l = inside.last {
            f.pre.append(Dir(x: f.x, kind: "pedal", payload: "start", below: true))
            l.post.append(Dir(x: l.x, kind: "pedal", payload: "stop", below: true))
          }
        } else if (c == "repeatMark_segno" || c == "repeatMark_coda"), var e = evs.first {
          for q in evs.dropFirst() where abs(sym[q.si].cx - s.cx) < abs(sym[e.si].cx - s.cx) { e = q }
          e.pre.append(Dir(x: e.x, kind: c.hasSuffix("segno") ? "segno" : "coda", payload: ""))
        }
      }
    }

    static func nextSystemFirst(_ L: Layout, _ notesOn: [Int: [Event]], _ staff: Int, _ place: [[Int: Int]]) -> Event? {
      let st = L.staves[staff]
      guard st.system + 1 < L.systems.count else { return nil }
      guard let p = place[st.system].sorted(by: { $0.key < $1.key }).first(where: { $0.value == staff })?.key,
            let k = place[st.system + 1][p] else { return nil }
      return notesOn[k]?.first
    }

    // MARK: bar lengths
    static func voiceStarts(_ evs: [Event], _ mrestLen: Q) -> ([Q?], Q) {
      var starts: [Q?] = [], pos = Q.zero, end = Q.zero, root = Q.zero
      for e in evs {
        if e.kind == "gap" { starts.append(nil); pos += e.dur } else if e.chord { starts.append(root) } else {
          starts.append(pos); root = pos
          pos += e.kind == "mrest" ? mrestLen : e.dur
          end = max(end, pos)
        }
      }
      return (starts, end)
    }

    /// The bar fit (`fitOneValue`) mends one voice at a time, but a bar is one column across every staff: when
    /// the other voices still run past the meter, the column's length vote can fall to the meter and `chop` would
    /// cut those voices, dropping a chord no single value can shorten. So each column comes from the fitted build
    /// only where every voice in it then ends within its meter; elsewhere the bar is written as read (a check bar,
    /// its music whole). Both builds read the same events, so their shapes match.
    static func fittedColumns(_ plain: [[[StaffBar?]]], _ fitted: [[[StaffBar?]]]) -> [[[StaffBar?]]] {
      guard plain.count == fitted.count, zip(plain, fitted).allSatisfy({ $0.count == $1.count }) else { return plain }
      var out = plain
      for mi in 0..<(plain.map(\.count).max() ?? 0) {
        let fits = fitted.allSatisfy { ms in
          guard mi < ms.count else { return true }
          return ms[mi].allSatisfy { st in
            guard let st else { return true }
            let len = timeLen(st.state.time)
            return st.voices.values.allSatisfy { voiceStarts($0, len).1 <= len }
          }
        }
        guard fits else { continue }
        for p in out.indices where mi < out[p].count && out[p][mi].count == fitted[p][mi].count { out[p][mi] = fitted[p][mi] }
      }
      return out
    }

    static func columnLengths(_ built: [[[StaffBar?]]]) -> [Q?] {
      var out: [Q?] = []
      for mi in 0..<(built.map(\.count).max() ?? 0) {
        var votes: [(Q, Int)] = []
        var meters = Set<Q>()
        for ms in built {
          guard mi < ms.count, let first = ms[mi].compactMap({ $0 }).first else { continue }
          let barLen = timeLen(first.state.time)
          meters.insert(barLen)
          let short = (mi == 0 && first.marks.meter) || shortRight.contains(first.marks.right ?? "")
          for st in ms[mi] {
            guard let st else { continue }
            let n = st.voices.values.map { voiceStarts($0, barLen).1 }.max() ?? barLen
            let key = short || st.voices.isEmpty ? n : max(n, barLen)
            if let at = votes.firstIndex(where: { $0.0 == key }) { votes[at].1 += 1 } else { votes.append((key, 1)) }
          }
        }
        if votes.isEmpty { out.append(nil); continue }
        var best = votes[0]
        func rank(_ v: (Q, Int)) -> (Int, Int, Q) { (v.1, meters.contains(v.0) ? 1 : 0, Q.zero - v.0) }
        for v in votes.dropFirst() where rank(v) > rank(best) { best = v }
        out.append(best.0)
      }
      return out
    }

    static func fitValue(_ q: Q) -> (String, Int)? {
      for (typ, t) in Vocab.typeQuarters {
        for dots in 0..<3 where t * (Q(2) - Q(1, 1 << dots)) == q { return (typ, dots) }
      }
      return nil
    }

    static func chop(_ evs: [Event], _ cut: Q) -> [Event] {
      let (starts, end) = voiceStarts(evs, cut)
      if end <= cut { return evs }
      var kept: [(Event, Q)] = [], dropped: [Event] = []
      var root: Event?, shortened = false
      for (e, s) in zip(evs, starts) {
        if e.kind == "gap" { continue }
        let s = s!
        if e.chord {
          guard let r = root else { dropped.append(e); continue }
          if shortened { e.typ = r.typ; e.dots = r.dots; e.dur = r.dur; e.beams = [] }
          kept.append((e, s))
          continue
        }
        let length = e.kind == "mrest" ? cut : e.dur
        root = nil; shortened = false
        if s >= cut { dropped.append(e); continue }
        if s + length > cut {
          let fit = (e.kind == "note" || e.kind == "rest") && (e.tup == "none" || e.tup == "other") ? fitValue(cut - s) : nil
          guard let fit else { dropped.append(e); continue }
          e.typ = fit.0; e.dots = fit.1; e.dur = cut - s; e.beams = []
          shortened = true
        }
        root = e
        kept.append((e, s))
      }
      var out: [Event] = [], cursor = Q.zero
      for (e, s) in kept {
        if !e.chord {
          if s != cursor {
            let g = Event(x: e.x - 0.01, kind: "gap"); g.voice = e.voice; g.dur = s - cursor
            out.append(g); cursor = s
          }
          cursor += e.kind == "mrest" ? cut : e.dur
        }
        out.append(e)
      }
      let notes = out.filter { $0.kind == "note" }
      for d in dropped {
        if d.tieStop, let e = notes.last(where: { $0.tie && $0.step == d.step && $0.octave == d.octave }) { e.tie = false }
        for (typ, num) in d.slurs where typ == "stop" && !notes.isEmpty {
          let last = notes.last(where: { !$0.chord }) ?? notes[notes.count - 1]
          if let at = last.slurs.firstIndex(where: { $0 == ("start", num) }) { last.slurs.remove(at: at) } else { last.slurs.append(("stop", num)) }
        }
      }
      let heads = notes.filter { !$0.chord && $0.grace == "none" }
      for lvl in Set(heads.flatMap { $0.beams.map(\.0) }).sorted() {
        var group: [Event] = []
        for e in heads {
          let val = e.beams.first { $0.0 == lvl }?.1
          if val == "begin" || (val == "continue" && group.isEmpty) {
            group = [e]
            e.beams = e.beams.map { ($0.0, $0.0 == lvl ? "begin" : $0.1) }
          } else if val == "continue" { group.append(e) } else if val == "end" {
            if group.isEmpty { e.beams = e.beams.filter { $0.0 < lvl } }
            group = []
          }
        }
        if group.count > 1 { group[group.count - 1].beams = group[group.count - 1].beams.map { ($0.0, $0.0 == lvl ? "end" : $0.1) } } else if let g = group.first { g.beams = g.beams.filter { $0.0 < lvl } }
      }
      var run: [Event] = []
      for e in out where (e.kind == "note" || e.kind == "rest") && !e.chord && e.grace == "none" {
        if e.tupletMark == "start" { run = [e] } else if !run.isEmpty && e.tup == run[0].tup {
          run.append(e)
          if e.tupletMark == "stop" { run = [] }
        } else { run = [] }
      }
      if run.count > 1 { run[run.count - 1].tupletMark = "stop" } else if let f = run.first { f.tupletMark = "" }
      return out
    }

    // MARK: the page's meter
    static func pageMeter(_ rd: Reading, _ build: (String?) -> [Double]) -> String? {
      let L = rd.layout
      guard !L.systems.isEmpty else { return nil }
      let dists = L.systems[0].staves.compactMap { k -> [Double]? in
        guard let b = L.staves[k].bars.first else { return nil }
        return rd.tok[b]?.timeP
      }
      guard !dists.isEmpty else { return nil }
      let p = (0..<dists[0].count).map { i in dists.reduce(0) { $0 + $1[i] } / Double(dists.count) }
      let meters = Vocab.times.enumerated().compactMap { i, t -> (String, Q, Double)? in
        guard let t, t != "other" else { return nil }
        return (t, timeLen(t), p[i])
      }
      let z = meters.reduce(0) { $0 + $1.2 }
      let zz = z != 0 ? z : 1.0
      var lengths: [(Q, String)] = []
      for m in Front.stableSorted(meters, by: { $0.2 > $1.2 }) where !lengths.contains(where: { $0.0 == m.1 }) && lengths.count < meterLengths {
        lengths.append((m.1, m.0))
      }
      let runs = lengths.map { ($0.0, build($0.1)) }
      let n = runs.map(\.1.count).min()!
      var fit: [Q: Double] = [:]
      for (ln, _) in runs { fit[ln] = 0 }
      for i in 0..<n {
        let best = runs.map { $0.1[i] }.max()!
        for (ln, r) in runs { fit[ln]! += max(r[i] - best, barVoteFloor) }
      }
      var bestM: (String, Double)?
      for m in meters where fit[m.1] != nil {
        let v = log(max(m.2 / zz, 1e-9)) + fit[m.1]!
        if bestM == nil || v > bestM!.1 { bestM = (m.0, v) }
      }
      return bestM?.0
    }

    // MARK: MusicXML
    static func roundHalfEven(_ q: Q) -> Int {
      let fl = Int((Double(q.n) / Double(q.d)).rounded(.down))
      let rem = q - Q(fl)
      if rem < Q(1, 2) { return fl }
      if Q(1, 2) < rem { return fl + 1 }
      return fl % 2 == 0 ? fl : fl + 1
    }

    /// Each staff as the score places it: its part (the MusicXML part index), its system, its staff space and
    /// lines, and where its measures start (the left edge of each measure column after the first). For reading
    /// the chord symbols printed above a staff and putting them into the measures they belong to.
    struct PlacedStaff {
      let part: Int, system: Int, grandStaff: Bool
      let sp: Double, x0: Double, x1: Double, y0: Double, y1: Double
      let measureStarts: [Double]
      /// The layout staff it was written from, its place in its part (0 the upper staff of a grand staff), and for
      /// each of the layout staff's bars the measure (0 the first of this staff's measures) it belongs to.
      var layoutStaff = -1, staffInPart = 0
      var barMeasures: [Int] = []
    }

    static func placedStaves(_ rd: Reading) -> [PlacedStaff] {
      let L = rd.layout
      let plans = planParts(rd)
      let place = alignSystems(rd, plans)
      var out: [PlacedStaff] = []
      for (si, sy) in L.systems.enumerated() where si < place.count {
        for (n, pl) in plans.enumerated() {
          for pos in pl {
            guard let k = place[si][pos], let at = sy.staves.firstIndex(of: k), at < sy.columns.count else { continue }
            let st = L.staves[k], cols = sy.columns[at]
            guard cols.count == st.bars.count, !st.bars.isEmpty else { continue }
            var lefts: [Int: Double] = [:]
            var right = -Double.infinity
            for (j, b) in st.bars.enumerated() {
              let box = L.syms[b].box
              lefts[cols[j]] = min(lefts[cols[j]] ?? .infinity, box.0)
              right = max(right, box.2)
            }
            let columns = lefts.keys.sorted()
            let starts = columns.map { lefts[$0]! }
            guard let left = starts.first, right > left else { continue }
            var placed = PlacedStaff(part: n, system: si, grandStaff: pl.count == 2, sp: st.sp, x0: left, x1: right,
                                     y0: st.y0, y1: st.y1, measureStarts: Array(starts.dropFirst()))
            placed.layoutStaff = k
            placed.staffInPart = pl.firstIndex(of: pos) ?? 0
            placed.barMeasures = cols.map { columns.firstIndex(of: $0) ?? 0 }
            out.append(placed)
          }
        }
      }
      return out
    }

    /// Whether the page's first system prints a time signature at its start.
    static func openingPrinted(_ rd: Reading) -> Bool {
      guard let sy = rd.layout.systems.first else { return false }
      return rd.layout.syms.contains { s in
        sy.staves.contains(s.staff) && s.bar == 0 && isReal(rd, s.i) && family(cls(rd, s.i)) == "meterSig"
      }
    }

    /// `carriedMeter`: the meter the previous page ended in. A page that prints no time signature at its start
    /// is still in that meter, so it is used instead of a guess from this page's rhythms.
    static func write(_ rd: Reading, title: String? = nil, carriedMeter: String? = nil) -> String {
      let L = rd.layout
      let plans = planParts(rd)
      let place = alignSystems(rd, plans)
      let root = XE("score-partwise", nil, [("version", "4.0")])
      if let title, !title.isEmpty { root.sub("work").sub("work-title", title) }
      root.sub("identification").sub("encoding").sub("software", "copisteria")
      let plist = root.sub("part-list")
      let groups = partGroups(rd, plans)
      for n in plans.indices {
        for (g, (a, _, sym)) in groups.enumerated() where a == n {
          plist.sub("part-group", nil, [("type", "start"), ("number", g + 1)]).sub("group-symbol", sym)
        }
        plist.sub("score-part", nil, [("id", "P\(n + 1)")]).sub("part-name", "Part \(n + 1)", [("print-object", "no")])
        for (g, (_, b, _)) in groups.enumerated() where b == n {
          plist.sub("part-group", nil, [("type", "stop"), ("number", g + 1)])
        }
      }
      var columns: [(Int, Int)] = []
      for (si, sy) in L.systems.enumerated() {
        let ncol = 1 + (sy.columns.filter { !$0.isEmpty }.map { $0.max()! }.max() ?? -1)
        columns += (0..<ncol).map { (si, $0) }
      }
      let singlePart = plans.count == 1

      let brackets = bracketMarks(rd)
      func build(_ opening: String?, fitBars: Bool = false) -> ([[[StaffBar?]]], [Double]) {
        var built: [[[StaffBar?]]] = []
        var fit: [Double] = []
        for pl in plans {
          var state = [BarState](repeating: BarState(), count: pl.count)
          var first = [Bool](repeating: true, count: pl.count)
          var measures: [[StaffBar?]] = []
          var prevEvents = [[Event]?](repeating: nil, count: pl.count)
          var prevSlash = [Bool](repeating: false, count: pl.count)
          for (si, c) in columns {
            let sy = L.systems[si]
            var m: [StaffBar?] = []
            for (ki, pos) in pl.enumerated() {
              guard let staff = place[si][pos] else { m.append(nil); continue }
              let cols = sy.columns[sy.staves.firstIndex(of: staff)!]
              let bars = cols.indices.filter { cols[$0] == c }
              guard let j = bars.first else { m.append(nil); continue }
              state[ki] = barState(rd, staff, j, state[ki], first: first[ki], ensemble: plans.count >= 3)
              if first[ki] {
                first[ki] = false
                if let opening { state[ki].time = opening }
              }
              var (ev, dirs, marks) = events(rd, staff, j, clef: state[ki].clef, key: state[ki].key)
              for jj in bars {
                marks.endings += brackets[staff]?[jj]?.endings ?? []
                marks.endingHooks += brackets[staff]?[jj]?.hooks ?? []
                marks.bracketStarts += brackets[staff]?[jj]?.opens ?? []
              }
              for j2 in bars.dropFirst() {
                let (ev2, dirs2, marks2) = events(rd, staff, j2, clef: state[ki].clef, key: state[ki].key)
                ev += ev2; dirs += dirs2
                marks.right = marks2.right ?? marks.right
                marks.endClef = marks2.endClef ?? marks.endClef
                marks.repeatBar = marks.repeatBar || marks2.repeatBar
              }
              if bars.count == 1, let slashes = slashEvents(rd, staff, j, state[ki]) {
                ev = slashes
                marks.slash = true
              }
              if marks.repeatBar && ev.isEmpty, let prev = prevEvents[ki], !prev.isEmpty {
                ev = prev.map { e in let c = e.copy(); c.copied = true; return c }
                marks.slash = prevSlash[ki]
              }
              prevSlash[ki] = marks.slash
              let vs = voices(ev, L.staves[staff].sp, singleStaffPart: pl.count == 1, barLen: timeLen(state[ki].time), score: &fit,
                              fitBar: fitBars)
              if !ev.isEmpty { prevEvents[ki] = ev }
              m.append(StaffBar(staff: staff, bar: j, voices: vs, dirs: dirs, marks: marks, state: state[ki]))
              if let ec = marks.endClef { state[ki].clef = ec }
            }
            measures.append(m)
          }
          built.append(measures)
        }
        return (built, fit)
      }

      let carried = carriedMeter.flatMap { m in Vocab.times.contains(m) && m != "other" ? m : nil }
      let opening = carried != nil && !openingPrinted(rd) ? carried : pageMeter(rd) { build($0).1 }
      let built = fittedColumns(build(opening).0, build(opening, fitBars: true).0)

      // ties: the next note of the voice on the same step and octave (this bar or the next)
      var pairs: [(Event, Event?, Bool)] = []
      for measures in built {
        for ki in 0..<(measures.map(\.count).max() ?? 0) {
          var streams = Voices()
          for m in measures {
            guard ki < m.count, let st = m[ki] else { continue }
            for v in st.voices.order { streams[v] = (streams[v] ?? []) + st.voices[v]! }
          }
          for evs in streams.values {
            var group = -1, groups: [Int] = []
            for f in evs { if !(f.kind == "note" && f.chord) { group += 1 }; groups.append(group) }
            for (ai, e) in evs.enumerated() where e.kind == "note" && e.tie {
              var partner: Event?, fi = ai
              for q in (ai + 1)..<min(ai + 12, evs.count) {
                let f = evs[q]
                if f.kind == "note" && f.step == e.step && f.octave == e.octave { partner = f; fi = q; break }
              }
              pairs.append((e, partner, partner != nil && groups[fi] == groups[ai] + 1))
            }
          }
        }
      }
      let kept = drawnTies(rd, pairs)
      for (n, (e, partner, _)) in pairs.enumerated() {
        if !kept.contains(n) { e.tie = false } else if let partner { partner.tieStop = true; partner.alter = e.alter }
      }
      attach(rd, built, plans, place)

      let barEnds = columnLengths(built)
      var allDurs = Set<Q>()
      for measures in built {
        for (mi, m) in measures.enumerated() {
          for st in m {
            guard let st else { continue }
            for v in st.voices.order {
              if let cut = barEnds[mi] { st.voices[v] = chop(st.voices[v]!, cut) }
              allDurs.formUnion(st.voices[v]!.map(\.dur))
            }
          }
        }
      }
      allDurs.formUnion(barEnds.compactMap { $0 })
      for ms in built { for m in ms { if let f = m.first, let f { allDurs.insert(timeLen(f.state.time)) } } }
      var div = 1
      for d in allDurs where !d.isZero {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        div = div * d.d / gcd(div, d.d)
      }
      div = min(div, 10080)
      func units(_ q: Q) -> Int { max(0, roundHalfEven(q * Q(div))) }

      for (n, (pl, measures)) in zip(plans, built).enumerated() {
        let part = root.sub("part", nil, [("id", "P\(n + 1)")])
        dropDanglingGraceSlurs(measures.joined().compactMap { $0 }.flatMap { st in st.voices.order.sorted().map { st.voices[$0]! } })
        var lastKey: Int?, lastTime: String?, lastClefs = [String?](repeating: nil, count: pl.count)
        var meterShown = false
        var number = 0
        let spans = endingSpans(measures.map { $0.compactMap { $0 }.first?.marks }, systems: columns.map(\.0))
        let spanFrom = Dictionary(spans.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        let spanTo = Dictionary(spans.map { ($0.stop, $0) }, uniquingKeysWith: { a, _ in a })
        let multi = pl.count > 1
        var slashOn = [Bool](repeating: false, count: pl.count)
        for (mi, staves) in measures.enumerated() {
          number += 1
          let meas = part.sub("measure", nil, [("number", number)])
          // the page's own line breaks, so a system's measures can be found again (chord placement, layout)
          if mi > 0 && mi < columns.count && columns[mi].1 == 0 { meas.sub("print", nil, [("new-system", "yes")]) }
          guard let first = staves.compactMap({ $0 }).first else {
            if mi == 0 {
              let attrs = meas.sub("attributes")
              attrs.sub("divisions", div)
              if multi { attrs.sub("staves", pl.count) }
            }
            continue
          }
          let key = first.state.key, time = first.state.time
          let clefs = staves.enumerated().map { i, s in s?.state.clef ?? lastClefs[i] }
          var attrs: XE?
          if mi == 0 || key != lastKey || time != lastTime || clefs != lastClefs || first.marks.multirest != nil {
            let a = meas.sub("attributes")
            attrs = a
            if mi == 0 { a.sub("divisions", div) }
            if mi == 0 || key != lastKey { a.sub("key").sub("fifths", key) }
            if (mi == 0 || time != lastTime) && time != "other" {
              let printed = staves.contains { $0?.marks.meter == true }
              meterShown = printed
              let t = a.sub("time", nil, printed ? [] : [("print-object", "no")])
              let bt = time.split(separator: "/")
              t.sub("beats", bt[0]); t.sub("beat-type", bt[1])
            }
            if mi == 0 && multi { a.sub("staves", pl.count) }
            for (i, cl) in clefs.enumerated() {
              guard let cl, mi == 0 || cl != lastClefs[i] else { continue }
              let (sign, line, octc) = clefXML[cl] ?? ("G", 2, 0)
              let ce = multi ? a.sub("clef", nil, [("number", i + 1)]) : a.sub("clef")
              ce.sub("sign", sign)
              if let line { ce.sub("line", line) }
              if octc != 0 { ce.sub("clef-octave-change", octc) }
            }
          }
          lastKey = key; lastTime = time; lastClefs = clefs
          let mr = first.marks.multirest
          if let mr, singlePart, mr > 1, let attrs { attrs.sub("measure-style").sub("multiple-rest", mr) }
          // slash notation starts and stops with the slash bars, staff by staff
          for (ki, st) in staves.enumerated() {
            let want = st?.marks.slash ?? false
            guard want != slashOn[ki] else { continue }
            let a = attrs ?? meas.sub("attributes")
            attrs = a
            a.sub("measure-style", nil, multi ? [("number", ki + 1)] : [])
              .sub("slash", nil, want ? [("type", "start"), ("use-stems", "no")] : [("type", "stop")])
            slashOn[ki] = want
          }
          let barLen = timeLen(time)
          let barEnd = barEnds[mi] ?? barLen
          if first.marks.left != nil || spanFrom[mi] != nil {
            let bl = meas.sub("barline", nil, [("location", "left")])
            if first.marks.left != nil { bl.sub("bar-style", "heavy-light") }
            if let span = spanFrom[mi] { bl.sub("ending", nil, [("number", span.number), ("type", "start")]) }
            if first.marks.left != nil { bl.sub("repeat", nil, [("direction", "forward")]) }
          }
          let opening = mi == 0 && first.marks.meter
          let keepShort = opening || shortRight.contains(first.marks.right ?? "")
          var posQ = Q.zero, maxEnd = Q.zero
          for (ki, st) in staves.enumerated() {
            guard let st else { continue }
            let staffNo = ki + 1
            let sNo: Int? = multi ? staffNo : nil
            // Where each voice number on this staff has got to. The reader can put a second line that sounds at
            // the same time into the same voice (an inner line under held chords, placed by its onsets with a
            // step back in time); MusicXML wants that line in a voice of its own, so it moves to the first voice
            // number on the staff that is free at that point. Nothing is dropped or re-timed.
            var ends: [Int: Q] = [:]
            var lastVoice = 0
            // A line moved off its voice stays in the voice it moved to while that voice is free, so a group (a
            // triplet, a run) is not split between two voices when its own voice frees up mid-group.
            var moved: [Int: Int] = [:]
            func freeVoice(_ v: Int, at t: Q) -> Int {
              if let x = moved[v], (ends[x] ?? Q.zero) <= t { return x }
              guard let end = ends[v], t < end else { moved[v] = nil; return v }
              let used = Set(ends.keys).union([v]).sorted()
              let pick = used.first { $0 != v && (ends[$0] ?? Q.zero) <= t } ?? ((ends.keys.max() ?? v) + 1)
              moved[v] = pick
              return pick
            }
            if st.voices.isEmpty {
              if !posQ.isZero { meas.sub("backup").sub("duration", units(posQ)); posQ = Q.zero }
              let fw = meas.sub("forward")
              fw.sub("duration", units(barEnd))
              if multi { fw.sub("staff", staffNo) }
              posQ = barEnd
              continue
            }
            for (vi, v) in st.voices.order.sorted().enumerated() {
              let evs = st.voices[v]!
              if !posQ.isZero { meas.sub("backup").sub("duration", units(posQ)); posQ = Q.zero }
              let voiceNo = v + 4 * (staffNo - 1)
              var dirs = vi == 0 ? st.dirs.enumerated().sorted {
                ($0.element.x, $0.element.kind, $0.element.payload, $0.offset) < ($1.element.x, $1.element.kind, $1.element.payload, $1.offset)
              }.map(\.element) : []
              // a chord member's directions go with its root
              var cRoot: Event?, cLast: Event?, cMembers: [Event] = []
              for e in evs.map({ Optional($0) }) + [nil] {
                if let e, e.kind == "note" && e.chord, let r = cRoot {
                  r.pre += e.pre; e.pre = []
                  cMembers.append(e); cLast = e
                  continue
                }
                if let cl = cLast, let r = cRoot {
                  let posts = r.post + cMembers.flatMap(\.post)
                  r.post = []
                  for m in cMembers { m.post = [] }
                  cl.post = posts
                }
                if let e, e.kind == "note" || e.kind == "rest" { cRoot = e } else { cRoot = nil }
                cLast = nil; cMembers = []
                if e == nil { break }
              }
              for e in evs {
                while let d = dirs.first, !(e.kind == "note" && e.chord), d.x <= e.x + 0.5 * L.staves[st.staff].sp {
                  direction(meas, dirs.removeFirst(), sNo)
                }
                let dur = e.kind == "mrest" ? barEnd : e.dur
                // a length the bar fit settled on is what plays: the written value follows it (a dotted half whose dot
                // went unread is written as a half lasting three beats otherwise, and players that go by the note's
                // value rather than its duration pad or spill the bar)
                if (e.kind == "note" || e.kind == "rest") && e.grace == "none" && e.tup == "none" && Q.zero < dur
                  && dur != Vocab.duration(e.typ, e.dots, e.tup), let fit = fitValue(dur) {
                  e.typ = fit.0; e.dots = fit.1
                }
                if e.kind == "gap" {
                  if Q.zero < dur {
                    let fw = meas.sub("forward")
                    fw.sub("duration", units(dur)); fw.sub("voice", voiceNo)
                    if multi { fw.sub("staff", staffNo) }
                  } else if dur < Q.zero { meas.sub("backup").sub("duration", units(Q.zero - dur)) }
                  posQ += dur
                  continue
                }
                for d in e.pre { direction(meas, d, sNo) }
                var voice = voiceNo
                if e.chord && lastVoice != 0 { voice = lastVoice }
                else if e.grace == "none" {
                  voice = freeVoice(voiceNo, at: posQ)
                  ends[voice] = posQ + dur
                  lastVoice = voice
                } else {
                  // a grace note goes with the voice its main note is about to take
                  voice = freeVoice(voiceNo, at: posQ)
                }
                note(meas, e, units(dur), voice, sNo, wholeRest: !meterShown)
                for d in e.post { direction(meas, d, sNo) }
                if !e.chord { posQ += dur }
              }
              if vi == 0 && posQ < barEnd && !keepShort {
                // The rest of a short bar, as a gap: its length is often no single written value (a quarter and
                // a sixteenth, a third of a beat), which a typeless hidden rest leaves importers to misread.
                let fv = freeVoice(voiceNo, at: posQ)
                let fw = meas.sub("forward")
                fw.sub("duration", units(barEnd - posQ)); fw.sub("voice", fv)
                if multi { fw.sub("staff", staffNo) }
                ends[fv] = barEnd
                posQ = barEnd
              }
              maxEnd = max(maxEnd, posQ)
              for d in dirs { direction(meas, d, sNo) }
            }
          }
          if opening && Q.zero < maxEnd && maxEnd < barLen { meas.set("implicit", "yes") }
          for (i, s) in staves.enumerated() { if let ec = s?.marks.endClef { lastClefs[i] = ec } }
          let span = spanTo[mi]
          let right = span?.impliedRepeat == true ? "barLine_repeat_end" : first.marks.right
          if right != nil || span != nil {
            let bl = meas.sub("barline", nil, [("location", "right")])
            if let right { bl.sub("bar-style", barRight[right]!) }
            if let span {
              bl.sub("ending", nil, [("number", span.number), ("type", span.closed ? "stop" : "discontinue")])
            }
            if right == "barLine_repeat_end" {
              // the repeat inside a "1, 2." ending (or the 2nd of three) is played once more per extra number
              let times = (spans.first { $0.start <= mi && mi <= $0.stop }).map { endingNumbers($0.number).max() ?? 1 } ?? 1
              bl.sub("repeat", nil, times >= 2 ? [("direction", "backward"), ("times", times + 1)] : [("direction", "backward")])
            }
          }
        }
      }
      var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n"
      root.render(into: &out)
      return out
    }

    static func direction(_ meas: XE, _ d: Dir, _ staffNo: Int?) {
      if d.kind == "clef" {
        let attrs = meas.sub("attributes")
        let (sign, line, octc) = clefXML[d.payload] ?? ("G", 2, 0)
        let ce = staffNo.map { attrs.sub("clef", nil, [("number", $0)]) } ?? attrs.sub("clef")
        ce.sub("sign", sign)
        if let line { ce.sub("line", line) }
        if octc != 0 { ce.sub("clef-octave-change", octc) }
        return
      }
      let de = meas.sub("direction", nil, [("placement", d.below ? "below" : "above")])
      let dt = de.sub("direction-type")
      switch d.kind {
      case "dyn": dt.sub("dynamics").sub(d.payload)
      case "wedge": dt.sub("wedge", nil, [("type", d.payload)])
      case "octave": dt.sub("octave-shift", nil, [("type", d.payload), ("size", d.size)])
      case "pedal": dt.sub("pedal", nil, [("type", d.payload), ("line", "yes")])
      case "segno", "coda": dt.sub(d.kind)
      default: break
      }
      if let staffNo { de.sub("staff", staffNo) }
    }

    /// The id a note written from detector symbol `si` carries, so text read later (lyrics) can find it.
    static func noteID(_ si: Int) -> String { "s\(si)" }

    static func note(_ meas: XE, _ e: Event, _ dur: Int, _ voice: Int, _ staffNo: Int?, wholeRest: Bool) {
      let ne = meas.sub("note", nil, e.kind == "note" && e.si >= 0 && !e.copied ? [("id", noteID(e.si))]
                        : e.hidden ? [("print-object", "no")] : [])
      if e.grace != "none" { ne.sub("grace", nil, e.grace == "unacc" ? [("slash", "yes")] : []) }
      if e.chord { ne.sub("chord") }
      if e.kind == "rest" || e.kind == "mrest" {
        ne.sub("rest", nil, e.kind == "mrest" ? [("measure", "yes")] : [])
      } else if e.unpitched {
        let up = ne.sub("unpitched")
        up.sub("display-step", e.step); up.sub("display-octave", e.octave)
      } else {
        let p = ne.sub("pitch")
        p.sub("step", e.step)
        if e.alter != 0 { p.sub("alter", e.alter) }
        p.sub("octave", e.octave)
      }
      if e.grace == "none" { ne.sub("duration", dur) }
      if e.tieStop { ne.sub("tie", nil, [("type", "stop")]) }
      if e.tie { ne.sub("tie", nil, [("type", "start")]) }
      ne.sub("voice", voice)
      if e.kind == "mrest" {
        if wholeRest { ne.sub("type", "whole") }
      } else {
        ne.sub("type", e.typ == "256" || e.typ == "512" ? e.typ + "th" : e.typ)
        for _ in 0..<e.dots { ne.sub("dot") }
      }
      if !e.accidental.isEmpty { ne.sub("accidental", e.accidental) }
      if e.tup != "none" && e.tup != "other" && e.grace == "none" {
        let an = e.tup.split(separator: "/")
        let tm = ne.sub("time-modification")
        tm.sub("actual-notes", an[0]); tm.sub("normal-notes", an[1])
      }
      if !e.stem.isEmpty && e.kind == "note" { ne.sub("stem", e.stem) }
      if let staffNo { ne.sub("staff", staffNo) }
      for (level, val) in e.beams { ne.sub("beam", val, [("number", level)]) }
      var nots: [(String, [(String, Any)])] = []
      if e.tieStop { nots.append(("tied", [("type", "stop")])) }
      if e.tie { nots.append(("tied", [("type", "start")])) }
      for (typ, num) in e.slurs { nots.append(("slur", [("type", typ), ("number", num)])) }
      if !e.tupletMark.isEmpty { nots.append(("tuplet", [("type", e.tupletMark)])) }
      if e.arpeggiate { nots.append(("arpeggiate", [])) }
      let arts = e.marks.compactMap { lookup(artic, $0) } + e.marks.compactMap { lookup(afterMark, $0) }
      let techs = e.marks.compactMap { lookup(tech, $0) }
      let orns = e.marks.compactMap { lookup(ornament, $0) }
      let ferm = e.marks.contains("fermata")
      if !nots.isEmpty || !arts.isEmpty || !techs.isEmpty || ferm || !orns.isEmpty {
        let nn = ne.sub("notations")
        for (tag, at) in nots { nn.sub(tag, nil, at) }
        if !orns.isEmpty { let oe = nn.sub("ornaments"); for o in orns { oe.sub(o) } }
        if !arts.isEmpty { let ae = nn.sub("articulations"); for a in arts { ae.sub(a) } }
        if !techs.isEmpty { let te = nn.sub("technical"); for t in techs { te.sub(t) } }
        if ferm { nn.sub("fermata") }
      }
    }
  }
}
