import Foundation

/// Finds the text above each staff and cuts it into word boxes, using copisteria's symbol boxes to remove the music,
/// then places each word on a bar and beat. A port of `tools/chordfind/find.py`, kept rule for rule (and tie for tie)
/// so the two give the same boxes; `ChordFinderInspect` and `tools/chordfind/finder_parity.py` check that.
///
/// Above a staff copisteria reads handwritten chord letters as music (a D as ff, an A as a marcato, a C as a
/// fermata), so there only notes it placed in a voice, and the accidentals and dots beside them, are erased.
public enum ChordFinder {
  // MARK: input

  public struct Box: Sendable, Equatable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
      self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    var cx: Double { (x0 + x1) / 2 }
    var cy: Double { (y0 + y1) / 2 }
  }

  public struct Staff: Sendable {
    public var x0: Double, x1: Double, y0: Double, y1: Double, sp: Double
    /// The x of each bar line copisteria found on this staff, left to right.
    public var bars: [Double]
    public init(x0: Double, x1: Double, y0: Double, y1: Double, sp: Double, bars: [Double]) {
      self.x0 = x0; self.x1 = x1; self.y0 = y0; self.y1 = y1; self.sp = sp; self.bars = bars
    }
  }

  public struct Symbol: Sendable {
    public var cls: String
    public var box: Box
    public var staff: Int     // -1: none
    public var bar: Int       // -1: none
    public var p: Double
    public init(cls: String, box: Box, staff: Int, bar: Int, p: Double) {
      self.cls = cls; self.box = box; self.staff = staff; self.bar = bar; self.p = p
    }
  }

  /// What copisteria read for one symbol: its onset in quarter notes from the bar start, how likely it is real,
  /// and the time signature (bar-line symbols).
  public struct Token: Sendable {
    public var onset: Double?
    public var real: Double?
    public var time: String?
    public init(onset: Double? = nil, real: Double? = nil, time: String? = nil) {
      self.onset = onset; self.real = real; self.time = time
    }
  }

  public struct Layout: Sendable {
    public var staves: [Staff]
    public var syms: [Symbol]
    public var sp: Double
    public var tokens: [Int: Token]
    public init(staves: [Staff], syms: [Symbol], sp: Double, tokens: [Int: Token]) {
      self.staves = staves; self.syms = syms; self.sp = sp; self.tokens = tokens
    }
  }

  public struct Parameters: Sendable {
    public var reach = 11.0          // how far above the staff to look, in staff spaces
    public var clear = 0.25          // gap kept above the top staff line
    public var pad = 0.15            // padding around erased symbols
    public var speck = 0.03          // smallest component, in square staff spaces
    public var stemH = 2.0, stemW = 0.4
    public var ledgerH = 0.35, ledgerW = 1.1
    public var longW = 3.0
    public var gap = 0.2             // word break: horizontal gap, as a fraction of the line's letter height
    public var letterPct = 75.0      // letter height = this percentile of piece heights over 0.6 sp
    public var rootGap = 0.8         // a lone capital joins the next word within this many letter heights
    public var trailGap = 0.8        // a small or accidental piece joins the word before it
    public var overlap = 0.25        // same line: vertical overlap as a fraction of the smaller height
    public var gapScale = 1.5, gapCap = 0.35
    public var chordBand = 7.0
    public var attachedMarks = true  // erase confident accents, staccatos and fermatas sitting on a timed note
    public var pageGap = true        // measure letter spacing over the whole page's chord rows, not line by line
    public init() {}
  }

  // MARK: output

  public enum Kind: String, Sendable {
    case text
    case rehearsal
    case sign
    case beforeMusic = "dropped:before-music"
    case lineAbove = "dropped:line-above"
    case stacked = "dropped:stacked"
  }

  public struct Proposal: Sendable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    public var staff: Int
    public var order: Int
    public var kind: Kind
    public var sign: String?
    public var upperRow = false
    public var parts = 0
    public var ink = 0
    public var bar = 0
    /// 1-based beat in quarter notes, nil when the bar has no timed note to place it by.
    public var beat: Double?
    public var beatDistance: Double?
    public var beatSource: String?
    public var anchor = "centre"
    var cx: Double { Double(x0 + x1) / 2 }
  }

  static let erase = ["note", "rest", "accid", "dots", "artic", "flag", "fermata", "clef", "keySig", "meterSig",
                      "dynam", "repeatMark", "breath", "caesura", "mordent", "trill", "tupletNum", "tuplet_", "arpeg",
                      "grpSym", "mRest", "barLine"]
  static let voltaP = 0.25, signP = 0.2
  /// Articulations above a staff that belong to a note: copisteria is confident (0.9+) on real ones, sized like a
  /// mark, and centred over the note they sit on. A handwritten chord letter it misreads as one is rarely confident
  /// and is taller than wide (a big C read as a fermata at 0.51).
  static let markP = 0.6

  // MARK: numpy helpers

  /// np.percentile with linear interpolation.
  static func percentile(_ values: [Double], _ q: Double) -> Double {
    let s = values.sorted()
    let idx = q / 100 * Double(s.count - 1)
    let lo = Int(idx.rounded(.down)), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (idx - Double(lo))
  }

  static func median(_ values: [Double]) -> Double { percentile(values, 50) }

  // MARK: components

  struct Component {
    var x0: Int, y0: Int, x1: Int, y1: Int   // y1, x1 exclusive, as numpy slices
    var area: Int
    var holes = 0
    var thin = false
    var why: String?
    var h: Int { y1 - y0 }
    var w: Int { x1 - x0 }
  }

  /// 8-connected components of a mask (scipy.ndimage.label with a 3x3 structure), numbered in raster order of
  /// their first pixel, each with its own pixels cut to its bounding box.
  static func label8(_ mask: [Bool], width: Int, height: Int) -> [(Component, [Bool])] {
    var lab = [Int32](repeating: 0, count: mask.count)
    var out: [(Component, [Bool])] = []
    var next: Int32 = 0
    var queue: [Int] = []
    for start in 0..<mask.count where mask[start] && lab[start] == 0 {
      next += 1
      lab[start] = next
      queue.removeAll(keepingCapacity: true)
      queue.append(start)
      var head = 0
      var x0 = start % width, x1 = x0, y0 = start / width, y1 = y0
      while head < queue.count {
        let p = queue[head]; head += 1
        let x = p % width, y = p / width
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        for dy in -1...1 {
          let ny = y + dy
          if ny < 0 || ny >= height { continue }
          for dx in -1...1 {
            let nx = x + dx
            if nx < 0 || nx >= width || (dx == 0 && dy == 0) { continue }
            let q = ny * width + nx
            if mask[q] && lab[q] == 0 { lab[q] = next; queue.append(q) }
          }
        }
      }
      let w = x1 - x0 + 1, h = y1 - y0 + 1
      var pix = [Bool](repeating: false, count: w * h)
      for p in queue { pix[(p / width - y0) * w + (p % width - x0)] = true }
      out.append((Component(x0: x0, y0: y0, x1: x1 + 1, y1: y1 + 1, area: queue.count), pix))
    }
    return out
  }

  /// Enclosed white regions of a glyph (scipy: label the padded background with 4-connectivity, count regions that
  /// do not reach the top padding row and have at least 3 pixels).
  static func holes(_ pix: [Bool], w: Int, h: Int) -> Int {
    let W = w + 2, H = h + 2
    var bg = [Bool](repeating: true, count: W * H)
    for y in 0..<h { for x in 0..<w where pix[y * w + x] { bg[(y + 1) * W + x + 1] = false } }
    var seen = [Bool](repeating: false, count: W * H)
    var count = 0
    var queue: [Int] = []
    for start in 0..<bg.count where bg[start] && !seen[start] {
      seen[start] = true
      queue.removeAll(keepingCapacity: true)
      queue.append(start)
      var head = 0, top = false
      while head < queue.count {
        let p = queue[head]; head += 1
        let x = p % W, y = p / W
        if y == 0 { top = true }
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
          let nx = x + dx, ny = y + dy
          if nx < 0 || ny < 0 || nx >= W || ny >= H { continue }
          let q = ny * W + nx
          if bg[q] && !seen[q] { seen[q] = true; queue.append(q) }
        }
      }
      if !top && queue.count >= 3 { count += 1 }
    }
    return count
  }

  /// A rehearsal-mark box: a closed rectangle of thin lines, mostly empty inside.
  static func isFrame(_ pix: [Bool], w: Int, h: Int, sp: Double) -> Bool {
    let hd = Double(h), wd = Double(w)
    guard 1.6 * sp <= hd, hd <= 5 * sp, 1.6 * sp <= wd, wd <= 25 * sp else { return false }
    let t = max(2, Int(0.3 * sp))
    func colsWithInk(_ rows: Range<Int>) -> Double {
      var n = 0
      for x in 0..<w where rows.contains(where: { pix[$0 * w + x] }) { n += 1 }
      return Double(n) / wd
    }
    func rowsWithInk(_ cols: Range<Int>) -> Double {
      var n = 0
      for y in 0..<h where cols.contains(where: { pix[y * w + $0] }) { n += 1 }
      return Double(n) / hd
    }
    let tt = min(t, h), tw = min(t, w)
    let cover = [colsWithInk(0..<tt), colsWithInk(max(0, h - tt)..<h), rowsWithInk(0..<tw), rowsWithInk(max(0, w - tw)..<w)]
    guard cover.min()! > 0.85 else { return false }
    guard h - 2 * t > 0, w - 2 * t > 0 else { return false }   // numpy: mean of an empty slice is nan
    var inside = 0
    for y in t..<(h - t) { for x in t..<(w - t) where pix[y * w + x] { inside += 1 } }
    return Double(inside) / Double((h - 2 * t) * (w - 2 * t)) < 0.35
  }

  static func components(_ mask: [Bool], width: Int, height: Int, sp: Double, p: Parameters)
    -> (comps: [Component], frames: [Component])
  {
    var out: [Component] = [], frames: [Component] = []
    for (comp, pix) in label8(mask, width: width, height: height) {
      var c = comp
      let h = Double(c.h), w = Double(c.w)
      if h <= 4 * sp && w <= 4 * sp { c.holes = holes(pix, w: c.w, h: c.h) }
      if Double(c.area) < p.speck * sp * sp { continue }
      if h >= p.stemH * sp && w <= p.stemW * sp {
        c.thin = true
      } else if h <= p.ledgerH * sp && p.ledgerW * sp <= w && w <= 3.5 * sp {
        c.why = "ledger"
      } else if isFrame(pix, w: c.w, h: c.h, sp: sp) {
        frames.append(c)
        continue
      } else if w >= p.longW * sp && h < 0.35 * w && (Double(c.area) / (h * w) < 0.3 || h <= 1.0 * sp) {
        c.why = "line"
      } else if h > 4.5 * sp {
        c.why = "tall"
      }
      out.append(c)
    }
    return (out, frames)
  }

  // MARK: words

  final class Group {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var parts: [Component]
    init(_ c: Component) { x0 = c.x0; y0 = c.y0; x1 = c.x1; y1 = c.y1; parts = [c] }
  }

  struct Word {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var parts: Int, ink: Int
  }

  /// Python's stable sort by a key.
  static func stableSorted<T>(_ a: [T], by key: (T) -> Double) -> [T] {
    a.enumerated().sorted { (l, r) in
      let kl = key(l.element), kr = key(r.element)
      return kl != kr ? kl < kr : l.offset < r.offset
    }.map(\.element)
  }

  static func words(_ input: [Component], sp: Double, p: Parameters, letterHeight: Double?,
                    pageGap: Double? = nil) -> [Word] {
    let comps = stableSorted(input) { Double($0.x0) }
    let tall = comps.map { Double($0.h) }.filter { $0 > 0.6 * sp }
    let letter = letterHeight ?? percentile(tall.isEmpty ? [1.5 * sp] : tall, p.letterPct)
    var gap = p.gap * letter
    // Loosely set fonts: widen the gap to the spacing this line uses between neighbouring letters, up to a cap.
    var level: [Double] = []
    for (a, b) in zip(comps, comps.dropFirst()) {
      let ov = Double(min(a.y1, b.y1) - max(a.y0, b.y0))
      let g = Double(b.x0 - a.x1)
      if g >= 0 && g <= 0.5 * letter && ov >= 0.5 * Double(min(a.h, b.h)) { level.append(g) }
    }
    if level.count >= 8 { gap = min(max(gap, p.gapScale * median(level)), p.gapCap * letter) }
    // The page's chord-row letter spacing (see find) widens the gap for pieces inside a chord (quality, extension,
    // accidental) but not for a capital-height letter: in a loosely set font the next chord's root sits as close as
    // the letters within one ("F m7 F#o7": 5 px either way), so a root keeps the line's own gap.
    var wideGap = gap
    if let r = pageGap { wideGap = max(gap, min(p.gapScale * r * letter, p.gapCap * letter)) }
    func gapFor(_ c: Component) -> Double {
      let h = Double(c.h)
      let capital = h >= 0.85 * letter && h <= 1.25 * letter && Double(c.w) >= 0.5 * letter
      return capital ? gap : wideGap
    }

    var groups: [Group] = []
    for c in comps {
      var best: Group?, bestOv = 0.0
      for g in groups {
        if Double(c.x0 - g.x1) > gapFor(c) || c.x1 < g.x0 { continue }
        let ov = Double(min(g.y1, c.y1) - max(g.y0, c.y0))
        let need = p.overlap * Double(min(g.y1 - g.y0, c.y1 - c.y0))
        let frac = ov / Double(max(1, c.y1 - c.y0))
        if ov >= need && frac > bestOv { best = g; bestOv = frac }
      }
      if let g = best {
        g.parts.append(c)
        g.x0 = min(g.x0, c.x0); g.y0 = min(g.y0, c.y0); g.x1 = max(g.x1, c.x1); g.y1 = max(g.y1, c.y1)
      } else {
        groups.append(Group(c))
      }
    }

    // A lone capital joins the word after it (copyists leave a wider gap after the root: "D  -7").
    let rootGap = p.rootGap * letter
    if rootGap > 0 {
      groups = stableSorted(groups) { Double($0.x0) }
      var merged = true
      while merged {
        merged = false
        for g in groups {
          let h = Double(g.y1 - g.y0), w = Double(g.x1 - g.x0)
          if g.parts.count != 1 || h < 0.8 * letter || w > 1.3 * h { continue }
          // level with the word after it, or with that word's first piece: an extension written raised
          // ("C 9(#11)") sits higher as a whole word than its first glyph does
          func level(_ o: Group) -> Bool {
            if Double(min(o.y1, g.y1) - max(o.y0, g.y0)) >= 0.5 * min(h, Double(o.y1 - o.y0)) { return true }
            guard let f = o.parts.min(by: { $0.x0 < $1.x0 }) else { return false }
            return Double(min(f.y1, g.y1) - max(f.y0, g.y0)) >= 0.5 * min(h, Double(f.h))
          }
          let nxt = groups.filter { o in
            o !== g && Double(o.x0 - g.x1) >= 0 && Double(o.x0 - g.x1) <= rootGap && level(o)
          }
          if let o = nxt.min(by: { $0.x0 < $1.x0 }) {
            o.parts += g.parts
            o.x0 = g.x0; o.y0 = min(o.y0, g.y0); o.y1 = max(o.y1, g.y1)
            groups.removeAll { $0 === g }
            merged = true
            break
          }
        }
      }
    }

    // A trailing piece joins the chord before it: a raised or small extension, or a lone accidental.
    let trailGap = p.trailGap * letter
    if trailGap > 0 {
      groups = stableSorted(groups) { Double($0.x0) }
      var merged = true
      while merged {
        merged = false
        for g in groups {
          let h = Double(g.y1 - g.y0), w = Double(g.x1 - g.x0)
          let small = h <= 0.8 * letter && w <= 2.0 * letter
          let accidental = g.parts.count <= 2 && h >= 1.6 * w && w <= 0.8 * letter
            && (g.parts.count == 2 || g.parts[0].holes >= 1)
          let short = w <= 2.0 * letter
          if !(small || accidental || short) { continue }
          func fits(_ o: Group) -> Bool {
            let d = Double(g.x0 - o.x1)
            if o === g || !(d >= 0 && d <= trailGap) { return false }
            let oh = Double(o.y1 - o.y0)
            if oh < 0.7 * letter || Double(o.x1 - o.x0) < 0.5 * letter { return false }
            let raised = short && Double(g.y1) <= Double(o.y1) - 0.25 * oh && Double(g.y0) >= Double(o.y0) - 0.8 * letter
            let lvl = (small || accidental) && Double(g.y0) >= Double(o.y0) - 0.6 * letter
              && Double(g.y1) <= Double(o.y1) + 0.3 * letter && Double(g.y1) >= Double(o.y0) + 0.2 * oh
            return raised || lvl
          }
          let prev = groups.filter(fits)
          if var o = prev.first {
            for q in prev.dropFirst() where q.x1 > o.x1 { o = q }   // first maximum, as Python's max
            o.parts += g.parts
            o.x1 = max(o.x1, g.x1); o.y0 = min(o.y0, g.y0); o.y1 = max(o.y1, g.y1)
            groups.removeAll { $0 === g }
            merged = true
            break
          }
        }
      }
    }

    // A bass note written under its chord like a fraction joins it: a narrow piece touching the bottom of the
    // chord above, under its right part.
    var merged = true
    while merged {
      merged = false
      for g in stableSorted(groups, by: { Double($0.y0) }) {
        let gw = Double(g.x1 - g.x0), gh = Double(g.y1 - g.y0)
        if gw > 1.4 * letter || gw < 0.9 * letter || gh < 0.3 * letter { continue }
        let over = groups.filter { o in
          let d = Double(g.y0 - o.y1)
          return o !== g && Double(o.x1 - o.x0) >= letter && o.y0 < g.y0 && d >= -0.2 * letter && d <= 0.15 * letter
            && Double(g.x0) >= Double(o.x0) + 0.8 * letter && Double(g.x1) <= Double(o.x1) + 0.6 * letter
        }
        if var o = over.first {
          for q in over.dropFirst() where q.y1 > o.y1 { o = q }
          o.parts += g.parts
          o.x1 = max(o.x1, g.x1); o.y1 = max(o.y1, g.y1)
          groups.removeAll { $0 === g }
          merged = true
          break
        }
      }
    }
    return groups.map { g in
      Word(x0: g.parts.map(\.x0).min()!, y0: g.parts.map(\.y0).min()!, x1: g.parts.map(\.x1).max()!,
           y1: g.parts.map(\.y1).max()!, parts: g.parts.count, ink: g.parts.reduce(0) { $0 + $1.area })
    }
  }

  // MARK: find

  public static func find(gray: [UInt8], width W: Int, height H: Int, layout L: Layout,
                          parameters p: Parameters = Parameters()) -> [Proposal] {
    let ink = gray.map { $0 < 160 }
    var clean = ink
    let syms = L.syms

    func staffOf(_ s: Symbol) -> Staff? { s.staff >= 0 && s.staff < L.staves.count ? L.staves[s.staff] : nil }
    func above(_ s: Symbol) -> Bool {
      guard let st = staffOf(s) else { return false }
      let mid = (s.box.y0 + s.box.y1) / 2
      return mid < st.y0 || mid > st.y1
    }
    func real(_ i: Int) -> Double {
      guard let t = L.tokens[i] else { return 1.0 }
      return t.real ?? 0.0
    }
    func isNoteOrRest(_ cls: String) -> Bool { cls.hasPrefix("note") || cls.hasPrefix("rest") }

    // Notes and rests in a voice; above the staff they must also be likely real.
    var timed = Set<Int>()
    for (i, s) in syms.enumerated()
    where isNoteOrRest(s.cls) && L.tokens[i]?.onset != nil && (!above(s) || real(i) >= 0.5) {
      timed.insert(i)
    }
    let heads = timed.sorted().filter { syms[$0].cls.hasPrefix("note") }.map { syms[$0].box }

    func besideNote(_ s: Symbol) -> Bool {
      let sp = L.staves[s.staff].sp
      for h in heads {
        if min(s.box.y1, h.y1) - max(s.box.y0, h.y0) <= 0 { continue }
        if s.cls.hasPrefix("accid") && h.x0 - 1.5 * sp <= s.box.x1 && s.box.x1 <= h.x0 + 0.3 * sp { return true }
        if s.cls.hasPrefix("dots") && h.x1 - 0.2 * sp <= s.box.x0 && s.box.x0 <= h.x1 + 1.5 * sp { return true }
      }
      return false
    }

    let voltas = syms.indices.filter { syms[$0].cls.hasPrefix("ending_") && syms[$0].p >= voltaP && above(syms[$0]) }
    func touches(_ a: Box, _ b: Box, _ sp: Double) -> Bool {
      a.x0 - 0.5 * sp <= b.x1 && b.x0 <= a.x1 + 0.5 * sp && a.y0 - 0.5 * sp <= b.y1 && b.y0 <= a.y1 + 0.5 * sp
    }
    let hooks = syms.indices.filter { i in
      syms[i].cls == "spanEnd_tl" && above(syms[i])
        && voltas.contains { v in touches(syms[v].box, syms[i].box, L.staves[syms[v].staff].sp) }
    }
    let trusted = Set(voltas + hooks)
    let signs = voltas + syms.indices.filter {
      (syms[$0].cls == "repeatMark_segno" || syms[$0].cls == "repeatMark_coda") && syms[$0].p >= signP && above(syms[$0])
    }

    // A confident accent, staccato, tenuto or fermata right over a note copisteria timed.
    func attachedMark(_ s: Symbol) -> Bool {
      guard p.attachedMarks, s.p >= markP, s.cls.hasPrefix("artic") || s.cls.hasPrefix("fermata"),
            let st = staffOf(s) else { return false }
      let sp = st.sp
      let w = (s.box.x1 - s.box.x0) / sp, h = (s.box.y1 - s.box.y0) / sp
      if s.cls.hasPrefix("fermata") {
        if w < h || w > 4.5 || h > 3.0 { return false }
      } else if w > 1.8 || h > 2.0 {
        return false
      }
      let cx = (s.box.x0 + s.box.x1) / 2
      return heads.contains { hd in
        abs((hd.x0 + hd.x1) / 2 - cx) <= 0.7 * sp && hd.y0 - s.box.y1 >= -0.5 * sp && hd.y0 - s.box.y1 <= 5.0 * sp
      }
    }

    for (i, s) in syms.enumerated() {
      let sign = trusted.contains(i)
      if s.cls.hasPrefix("repeatMark") && above(s) { continue }
      if !sign && !erase.contains(where: { s.cls.hasPrefix($0) }) { continue }
      if !sign && above(s) && !attachedMark(s) {
        if isNoteOrRest(s.cls) {
          if !timed.contains(i) { continue }
        } else if !((s.cls.hasPrefix("accid") || s.cls.hasPrefix("dots")) && besideNote(s)) {
          continue
        }
      }
      let sp = staffOf(s)?.sp ?? L.sp
      let q = p.pad * sp
      let r0 = max(0, Int(s.box.y0 - q)), r1 = min(H, Int(s.box.y1 + q) + 1)
      let c0 = max(0, Int(s.box.x0 - q)), c1 = min(W, Int(s.box.x1 + q) + 1)
      if r0 >= r1 || c0 >= c1 { continue }
      for y in r0..<r1 { for x in c0..<c1 { clean[y * W + x] = false } }
    }

    let order = stableSorted(Array(L.staves.indices)) { L.staves[$0].y0 }
    let pageX0 = L.staves.isEmpty ? 0 : median(L.staves.map(\.x0))
    let pageX1 = L.staves.isEmpty ? Double(W) : median(L.staves.map(\.x1))
    var proposals: [Proposal] = []
    var twoRows = false
    var prevBottom = 0.0

    struct Line {
      let ord: Int, k: Int, top: Int, left: Int, kept: [Component], frames: [Component], letterHeight: Double?
    }
    var lines: [Line] = []
    for (ord, k) in order.enumerated() {
      let st = L.staves[k]
      let sp = st.sp
      let top = Int(max(prevBottom + 0.5 * sp, st.y0 - p.reach * sp, 0))
      let bottom = Int(st.y0 - p.clear * sp)
      let x0 = min(st.x0, pageX0), x1 = max(st.x1, pageX1)
      let left = Int(max(0, x0 - sp)), right = Int(min(Double(W), x1 + sp))
      prevBottom = st.y1
      if Double(bottom - top) < 2 * sp { continue }
      let rh = min(bottom, H) - top, rw = right - left
      if rh <= 0 || rw <= 0 { continue }
      var region = [Bool](repeating: false, count: rh * rw)
      for y in 0..<rh { for x in 0..<rw { region[y * rw + x] = clean[(top + y) * W + left + x] } }
      var (comps, frames) = components(region, width: rw, height: rh, sp: sp, p: p)

      // A thin sliver touching a notehead is what is left of its stem once the head is erased.
      for j in comps.indices {
        let c = comps[j]
        let gx0 = Double(c.x0 + left), gx1 = Double(c.x1 + left), gy0 = Double(c.y0 + top), gy1 = Double(c.y1 + top)
        if c.thin {
          comps[j].thin = false
          let nearHead = heads.contains { h in
            h.x0 - 0.5 * sp <= gx1 && gx0 <= h.x1 + 0.5 * sp && h.y0 - 4 * sp <= gy1 && gy0 <= h.y1 + 4 * sp
          }
          if nearHead || c.y1 >= rh - 1 || c.y0 <= 0 { comps[j].why = "stem"; continue }
        }
        if comps[j].why != nil || Double(c.w) > 0.45 * sp { continue }
        if c.y1 >= rh - 1 || c.y0 <= 0 { comps[j].why = "stem"; continue }
        if heads.contains(where: { h in
          h.x0 - 0.4 * sp <= gx1 && gx0 <= h.x1 + 0.4 * sp && h.y0 - 0.6 * sp <= gy1 && gy0 <= h.y1 + 0.6 * sp
        }) { comps[j].why = "stem" }
      }
      func inside(_ c: Component, _ f: Component) -> Bool { c.x0 >= f.x0 && c.x1 <= f.x1 && c.y0 >= f.y0 && c.y1 <= f.y1 }
      let kept = comps.filter { c in c.why == nil && !frames.contains { inside(c, $0) } }
      // Letter height from the band chords stand in, so the lyrics of the line above don't set it.
      let band = kept.filter { c in
        Double(c.h) > 0.6 * sp && (st.y0 - Double(top)) - Double(c.y0 + c.y1) / 2 <= p.chordBand * sp
      }.map { Double($0.h) }
      let letterHeight: Double? = band.isEmpty ? nil : percentile(band, p.letterPct)
      lines.append(Line(ord: ord, k: k, top: top, left: left, kept: kept, frames: frames, letterHeight: letterHeight))
    }

    // Letter spacing measured over the whole page's chord rows: a loosely set font (Real Book 3, "B m7 b5") spaces
    // every chord alike, but one line rarely has enough letters to tell.
    var pageRatio: Double?
    if p.pageGap {
      var ratios: [Double] = []
      for line in lines {
        let st = L.staves[line.k], sp = st.sp
        let tall = line.kept.map { Double($0.h) }.filter { $0 > 0.6 * sp }
        let letter = line.letterHeight ?? percentile(tall.isEmpty ? [1.5 * sp] : tall, p.letterPct)
        let row = stableSorted(line.kept.filter { c in
          Double(c.h) > 0.6 * sp && (st.y0 - Double(line.top)) - Double(c.y0 + c.y1) / 2 <= p.chordBand * sp
        }) { Double($0.x0) }
        for (a, b) in zip(row, row.dropFirst()) {
          let ov = Double(min(a.y1, b.y1) - max(a.y0, b.y0))
          let g = Double(b.x0 - a.x1)
          if g >= 0 && g <= 0.5 * letter && ov >= 0.5 * Double(min(a.h, b.h)) { ratios.append(g / letter) }
        }
      }
      if ratios.count >= 8 { pageRatio = median(ratios) }
    }

    for line in lines {
      let (ord, k, top, left, kept, frames) = (line.ord, line.k, line.top, line.left, line.kept, line.frames)
      let st = L.staves[k]
      let sp = st.sp
      var found = words(kept, sp: sp, p: p, letterHeight: line.letterHeight, pageGap: pageRatio).map { w in
        Proposal(x0: w.x0 + left, y0: w.y0 + top, x1: w.x1 + left, y1: w.y1 + top, staff: k, order: ord, kind: .text,
                 parts: w.parts, ink: w.ink)
      }

      // Nothing before the music starts is a chord: the music starts after the clef, key and time signature, or at
      // the start of the staff when a line has none.
      let starts = syms.filter { $0.staff == k && isNoteOrRest($0.cls) }.map(\.box.cx)
      var first = starts.min() ?? st.x0
      let head = syms.filter { s in
        s.staff == k && (s.cls.hasPrefix("clef") || s.cls.hasPrefix("keySig") || s.cls.hasPrefix("meterSig")
                         || s.cls.hasPrefix("timeSig"))
          && st.x0 - 3 * sp <= s.box.x0 && s.box.x0 <= st.x0 + 12 * sp
      }.map(\.box.x1)
      first = min(first, head.max().map { $0 + 0.5 * sp } ?? st.x0 + 1.0 * sp)
      let letter = found.isEmpty ? 1.5 * sp : median(found.map { Double($0.y1 - $0.y0) })
      for j in found.indices where found[j].cx < first - 1.5 * sp { found[j].kind = .beforeMusic }

      // Text belongs to the staff it sits closest to: lyrics hang below the line above.
      if ord > 0 {
        let aboveBottom = L.staves[order[ord - 1]].y1
        for j in found.indices where found[j].kind == .text {
          let c = Double(found[j].y0 + found[j].y1) / 2
          if c - aboveBottom < 0.6 * (st.y0 - c) { found[j].kind = .lineAbove }
        }
      }

      // Chord symbols are the lowest row of text over the staff; tempo, style and rehearsal words sit above them...
      let solid = found.indices.filter { j in
        let w = found[j]
        return w.kind == .text && Double(w.y1 - w.y0) >= max(0.6 * letter, 1.0 * sp) && Double(w.x1 - w.x0) >= 0.6 * sp
      }
      for a in solid {
        for b in solid {
          if b == a || Double(found[b].y0) < Double(found[a].y1) - 0.2 * letter { continue }
          let ov = Double(min(found[a].x1, found[b].x1) - max(found[a].x0, found[b].x0))
          if ov >= 0.3 * Double(min(found[a].x1 - found[a].x0, found[b].x1 - found[b].x0)) {
            found[a].kind = .stacked
            break
          }
        }
      }
      // ...unless the upper words form a row of their own across the line: a second chord row.
      let edges = st.bars + [st.x1]
      func barOf(_ w: Proposal) -> Int {
        let x = w.cx
        return (0..<(edges.count - 1)).filter { x >= edges[$0] }.max() ?? 0
      }
      let candidates = found.indices.filter { found[$0].kind == .text || found[$0].kind == .stacked }
      var rows: [[Int]] = []
      for j in stableSorted(candidates, by: { Double(found[$0].y1) }) {
        if let last = rows.last?.last, abs(Double(found[j].y1 - found[last].y1)) <= 0.5 * letter {
          rows[rows.count - 1].append(j)
        } else {
          rows.append([j])
        }
      }
      for row in rows where row.contains(where: { found[$0].kind == .stacked }) && row.count >= 3
        && Set(row.map { barOf(found[$0]) }).count >= 2 {
        twoRows = true
        for j in row {
          if found[j].kind == .stacked { found[j].kind = .text }
          found[j].upperRow = true
        }
      }
      proposals += found
      for f in frames {
        proposals.append(Proposal(x0: f.x0 + left, y0: f.y0 + top, x1: f.x1 + left, y1: f.y1 + top, staff: k,
                                  order: ord, kind: .rehearsal))
      }
    }
    let orderOf = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    for i in signs {
      let s = syms[i]
      proposals.append(Proposal(x0: Int(s.box.x0), y0: Int(s.box.y0), x1: Int(s.box.x1), y1: Int(s.box.y1),
                                staff: s.staff, order: orderOf[s.staff] ?? 0, kind: .sign, sign: s.cls))
    }
    // A page that prints a second chord row on one line prints it wherever it has alternate changes.
    if twoRows {
      for j in proposals.indices where proposals[j].kind == .stacked {
        proposals[j].kind = .text; proposals[j].upperRow = true
      }
    }
    let anchor = pageAnchor(proposals.filter { $0.kind == .text }, layout: L)
    for j in proposals.indices {
      place(&proposals[j], layout: L, anchor: anchor)
      proposals[j].anchor = anchor
    }
    return proposals
  }

  /// Which part of a chord sits over its note on this page: its centre (MuseScore) or its left edge (most copyists
  /// and many engravers). Whichever lines up with a note or rest more often wins.
  static func pageAnchor(_ words: [Proposal], layout L: Layout) -> String {
    var notes: [Int: [Box]] = [:]
    for (i, s) in L.syms.enumerated()
    where (s.cls.hasPrefix("note") || s.cls.hasPrefix("rest")) && L.tokens[i]?.onset != nil {
      notes[s.staff, default: []].append(s.box)
    }
    var centre = 0, leftVotes = 0
    for w in words {
      guard let boxes = notes[w.staff], !boxes.isEmpty else { continue }
      let sp = L.staves[w.staff].sp
      if Double(w.x1 - w.x0) < 1.0 * sp { continue }
      let dc = boxes.map { abs($0.cx - w.cx) }.min()!
      let dl = boxes.map { abs($0.x0 - Double(w.x0)) }.min()!
      if dc < 0.5 * sp { centre += 1 }
      if dl < 0.5 * sp { leftVotes += 1 }
    }
    return leftVotes > centre ? "left" : "centre"
  }

  /// Bar from the word's position; beat from the note or rest it sits over, or else the nearest strong beat.
  static func place(_ pr: inout Proposal, layout L: Layout, anchor: String) {
    guard pr.staff >= 0, pr.staff < L.staves.count else { return }
    let st = L.staves[pr.staff]
    let sp = st.sp
    let edges = st.bars + [st.x1]
    let x = anchor == "centre" ? pr.cx : Double(pr.x0) + 0.3 * sp
    var bar = 0
    for b in 0..<max(0, edges.count - 1) where x >= edges[b] { bar = b }
    pr.bar = bar
    var points: [(Double, Double)] = []
    for (i, s) in L.syms.enumerated() where s.staff == pr.staff && s.bar == bar {
      guard let on = L.tokens[i]?.onset, s.cls.hasPrefix("note") || s.cls.hasPrefix("rest") else { continue }
      points.append((anchor == "centre" ? s.box.cx : s.box.x0 + 0.3 * sp, on))
    }
    pr.beat = nil; pr.beatDistance = nil; pr.beatSource = nil
    guard var nearest = points.first else { return }
    for q in points.dropFirst() where abs(q.0 - x) < abs(nearest.0 - x) { nearest = q }
    pr.beatDistance = abs(nearest.0 - x) / sp
    if abs(nearest.0 - x) < 1.0 * sp {
      pr.beat = nearest.1 + 1; pr.beatSource = "note"
      return
    }
    // No note under the chord: place it between the notes on either side, then snap to the nearest strong beat.
    let (length, strong) = barLength(layout: L, staff: pr.staff)
    var unique: [(Double, Double)] = []
    for q in points where !unique.contains(where: { $0.0 == q.0 && $0.1 == q.1 }) { unique.append(q) }
    unique.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    let pts = unique + [(bar + 1 < edges.count ? edges[bar + 1] : st.x1, length)]
    var t: Double
    if x <= pts[0].0 {
      t = pts[0].1
    } else {
      t = length
      for (a, b) in zip(pts, pts.dropFirst()) where a.0 <= x && x <= b.0 && b.0 > a.0 {
        t = a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
        break
      }
    }
    t = (t / strong).rounded(.toNearestOrEven) * strong
    pr.beat = min(length - strong, t) + 1; pr.beatSource = "between"
  }

  /// Quarter notes per bar, and the spacing of its strong beats, from the time signature copisteria read.
  static func barLength(layout L: Layout, staff: Int) -> (Double, Double) {
    for (i, s) in L.syms.enumerated() where s.staff == staff {
      guard let t = L.tokens[i]?.time, t != "None", t.contains("/") else { continue }
      let parts = t.split(separator: "/")
      guard parts.count >= 2, let n = Int(parts[0]), let d = Int(parts[1]) else { continue }
      let length = Double(n) * 4 / Double(d)
      if d == 8 && n % 3 == 0 { return (length, 1.5) }
      return (length, n % 2 == 0 && length >= 2 ? 2.0 : 4 / Double(d))
    }
    return (4.0, 2.0)
  }
}

extension ChordFinder {
  /// The finder's input from copisteria's reading of a page: the same staves, symbols and readings
  /// `ScannerCheck --copista` writes to layout.json and tok.json.
  static func layout(_ r: Copista.Reading) -> Layout {
    let L = r.layout
    let staves = L.staves.map { st in
      Staff(x0: st.x0, x1: st.x1, y0: st.y0, y1: st.y1, sp: st.sp, bars: st.bars.map { L.syms[$0].box.0 })
    }
    let syms = L.syms.map { s in
      Symbol(cls: s.cls, box: Box(s.box.0, s.box.1, s.box.2, s.box.3), staff: s.staff, bar: s.bar, p: s.p)
    }
    var tokens: [Int: Token] = [:]
    for (i, t) in r.tok { tokens[i] = Token(onset: t.onset, real: t.realP, time: t.time) }
    return Layout(staves: staves, syms: syms, sp: L.sp, tokens: tokens)
  }
}
