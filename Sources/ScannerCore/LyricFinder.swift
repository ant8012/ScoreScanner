import Foundation

/// Finds the lyrics under each staff as word boxes, each paired with the note it is sung on. Geometry only: the
/// words are read later (`LocalTextReader`), and a word that does not read as one is dropped there.
///
/// The band under a staff, down to the chord band of the staff below, is cleared of what the detector found there
/// (notes with their ledger lines, rests, beams, dynamics) and of stems, then cut into pieces. Long thin horizontal
/// strokes at a line's foot are extender lines (a syllable held over more notes); short flat dashes between words
/// are hyphens. The rest is grouped into lines, one per verse, and words. Each word goes to the nearest note above
/// it that no earlier word of its line took, left to right.
public enum LyricFinder {
  public struct Word: Sendable, Equatable {
    public var x0: Int, y0: Int, x1: Int, y1: Int
    /// Layout staff the word belongs to, and its line under that staff (0: the first verse).
    public var staff: Int, verse: Int
    /// The id of the note the word is sung on (`Copista.Writer.noteID`).
    public var noteID: String
    public var hyphenAfter: Bool
    public var extendAfter: Bool
    /// Other notes under the word, left to right: a word whose hyphen touches its letters ("sha-dows") reads as one
    /// and is split onto them.
    public var moreNoteIDs: [String] = []
    /// The word stands between two staves of one system (a voice over its piano), above the lower one.
    public var betweenStaves = false
  }

  /// One piece of ink in the band, in page pixels.
  struct Piece {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var w: Int { x1 - x0 }
    var h: Int { y1 - y0 }
    var cx: Double { Double(x0 + x1) / 2 }
    var cy: Double { Double(y0 + y1) / 2 }
  }

  static func find(_ page: Copista.Gray, _ rd: Copista.Reading) -> [Word] {
    let L = rd.layout
    let order = L.staves.indices.sorted { L.staves[$0].y0 < L.staves[$1].y0 }
    // nothing is sung under the lower staff of a piano's grand staff: what is printed there is pedalling, the
    // left hand's markings, or the page's footer (a hymn's words stand between its two staves, under the upper one)
    let lowerOfGrand = Set(Copista.Writer.placedStaves(rd).filter { $0.grandStaff && $0.staffInPart > 0 }
      .map(\.layoutStaff))
    var out: [Word] = []
    for (n, k) in order.enumerated() where !lowerOfGrand.contains(k) {
      let st = L.staves[k], sp = st.sp
      // down to the chord band of the next staff below
      let below = order.dropFirst(n + 1).map { L.staves[$0] }.first { $0.y0 > st.y1 + 2 * sp }
      // a staff of the same system (the piano under a voice) has no chord band above it: stop just short of it
      let limit = below.map { $0.y0 - ($0.system == st.system && st.system >= 0 ? 0.8 : 2.8) * $0.sp }
        ?? Double(page.height)
      let r0 = Int(st.y1 + 0.5 * sp), r1 = min(page.height, Int(min(limit, st.y1 + 9 * sp)))
      let c0 = max(0, Int(st.x0 - sp)), c1 = min(page.width, Int(st.x1))
      guard r1 - r0 > Int(1.2 * sp), c1 > c0 else { continue }
      let between = below.map { $0.system == st.system && st.system >= 0 } ?? false
      var words = staffWords(page, rd, k, rows: r0..<r1, cols: c0..<c1)
      // a hymn stacks its verses deeper than nine spaces: follow the stack on, line by line, down to the chord
      // band of the staff below, as long as each line keeps to the spacing of the lines above it. Not under the
      // page's last staff: nothing bounds it there, and what stands below is a block of further verses printed as
      // prose, notes on the performance, or the copyright
      if below != nil, limit - Double(r1) >= sp,
        let deeper = staffWords(page, rd, k, rows: r0..<min(page.height, Int(limit)), cols: c0..<c1, stackFrom: r1)
      {
        words = deeper
      }
      out += words.map { w in
        var w = w
        w.betweenStaves = between
        return w
      }
    }
    return out
  }

  static let wide: Set<String> = [
    "measure", "curve", "hairpin", "octave", "pedal", "ending", "tupletBracket", "spanEnd", "trill", "gliss", "grpSym",
  ]

  static func staffWords(_ page: Copista.Gray, _ rd: Copista.Reading, _ k: Int, rows: Range<Int>, cols: Range<Int>)
    -> [Word]
  {
    staffWords(page, rd, k, rows: rows, cols: cols, stackFrom: nil) ?? []
  }

  /// With `stackFrom`, the band reaches past the usual depth: lines starting below `stackFrom` are kept only while
  /// they go on the stack of lines above (`stackedLines`), and the result is nil when none does, so the usual band
  /// is used unchanged.
  static func staffWords(_ page: Copista.Gray, _ rd: Copista.Reading, _ k: Int, rows: Range<Int>, cols: Range<Int>,
                         stackFrom: Int?) -> [Word]?
  {
    let L = rd.layout, st = L.staves[k], sp = st.sp
    let w = cols.count, h = rows.count
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
      let row = (rows.lowerBound + y) * page.width + cols.lowerBound
      for x in 0..<w where page.pixels[row + x] < 160 { mask[y * w + x] = true }
    }
    // the notation the detector found here, with a note's ledger lines either side of it
    for s in L.syms where Copista.Writer.isReal(rd, s.i) {
      // compact symbols only: a tie, slur, hairpin or bracket has a wide box that is mostly empty, and clearing
      // it would cut the lyrics under it (their thin lines are left out of the text lines anyway)
      let f = Copista.family(Copista.Writer.cls(rd, s.i))
      // a pedal sign ("Ped.", the release star) is compact; only a pedal line is wide
      guard !wide.contains(f) || (f == "pedal" && s.box.2 - s.box.0 <= 4 * sp) else { continue }
      let px = f == "note" ? 0.75 * sp : 0.15 * sp, py = 0.15 * sp
      let x0 = max(0, Int(s.box.0 - px) - cols.lowerBound), x1 = min(w, Int(s.box.2 + px) - cols.lowerBound + 1)
      let y0 = max(0, Int(s.box.1 - py) - rows.lowerBound), y1 = min(h, Int(s.box.3 + py) - rows.lowerBound + 1)
      guard x0 < x1, y0 < y1 else { continue }
      for y in y0..<y1 { for x in x0..<x1 { mask[y * w + x] = false } }
    }
    // stems hang into the band from the notes above, so a vertical run from its top edge goes; elsewhere only a
    // staff-tall run (a bar line) does: a tall letter (l, k, h) on a page with a small staff is nearly two spaces
    let stem = Int(0.6 * sp), tall = Int(3 * sp)
    for x in 0..<w {
      var y = 0
      while y < h {
        guard mask[y * w + x] else { y += 1; continue }
        var end = y
        while end < h && mask[end * w + x] { end += 1 }
        // stems hang down from the staff above, or rise from a staff of the same system below
        if ((y == 0 || end == h) && end - y >= stem) || end - y >= tall {
          for yy in y..<end { mask[yy * w + x] = false }
        }
        y = end
      }
    }
    // extender lines: long, thin horizontal strokes (recorded, then cleared)
    var rules: [Piece] = []
    let long = Int(2.0 * sp), thin = max(2, Int(0.3 * sp))
    for y in 0..<h {
      var x = 0
      while x < w {
        guard mask[y * w + x] else { x += 1; continue }
        var end = x
        while end < w && mask[y * w + end] { end += 1 }
        if end - x >= long {
          // thin: little ink just above or below the run
          let above = y >= thin ? (x..<end).filter { mask[(y - thin) * w + $0] }.count : 0
          let under = y + thin < h ? (x..<end).filter { mask[(y + thin) * w + $0] }.count : 0
          if above + under < (end - x) / 4 {
            rules.append(Piece(x0: x + cols.lowerBound, y0: y + rows.lowerBound, x1: end + cols.lowerBound,
                               y1: y + 1 + rows.lowerBound))
            for i in x..<end { mask[y * w + i] = false }
          }
        }
        x = end
      }
    }
    let pieces = ChordFinder.label8(mask, width: w, height: h).map(\.0)
      .filter { Double($0.area) >= 0.03 * sp * sp && Double($0.h) <= 2.6 * sp }
      .map { Piece(x0: $0.x0 + cols.lowerBound, y0: $0.y0 + rows.lowerBound, x1: $0.x1 + cols.lowerBound,
                   y1: $0.y1 + rows.lowerBound) }
    var lines = textLines(pieces, sp: sp)
    if let stackFrom {
      guard let stacked = stackedLines(lines, from: stackFrom) else { return nil }
      lines = stacked
    }
    // notes on this staff, one per chord stack, left to right
    var heads: [(x: Double, id: String)] = []
    for s in L.syms.sorted(by: { $0.cx < $1.cx })
    where s.staff == k && Copista.Writer.isReal(rd, s.i) && Copista.family(Copista.Writer.cls(rd, s.i)) == "note" {
      if let last = heads.last, abs(last.x - s.cx) < 0.6 * sp { continue }
      heads.append((s.cx, Copista.Writer.noteID(s.i)))
    }
    var out: [Word] = []
    for (verse, line) in lines.enumerated() {
      out += lineWords(line, rules: rules, heads: heads, staff: k, verse: verse, sp: sp)
    }
    return out
  }

  /// Pieces grouped into lines: letters first, each joining the line whose typical letter it overlaps by half; then
  /// the small pieces (the dots of i and j, hyphens, commas) go to the line around them, so a row of dots cannot
  /// start a line of its own. Lines with fewer than two letters are dropped. Top to bottom.
  static func textLines(_ pieces: [Piece], sp: Double) -> [[Piece]] {
    var lines: [[Piece]] = []
    func core(_ line: [Piece]) -> (Int, Int) {
      let tops = line.map(\.y0).sorted(), bottoms = line.map(\.y1).sorted()
      return (tops[tops.count / 2], bottoms[bottoms.count / 2])
    }
    let tallish = pieces.map(\.h).filter { Double($0) >= 0.5 * sp }.sorted()
    let typical = tallish.isEmpty ? 0.8 * sp : Double(tallish[tallish.count / 2])
    let letters = pieces.filter { Double($0.h) >= 0.55 * typical }
    let small = pieces.filter { Double($0.h) < 0.55 * typical }
    for p in letters.sorted(by: { $0.cy < $1.cy }) {
      if let i = lines.lastIndex(where: { line in
        let (a, b) = core(line)
        return Double(min(b, p.y1) - max(a, p.y0)) >= 0.5 * Double(max(1, min(p.h, b - a)))
      }) {
        lines[i].append(p)
      } else {
        lines.append([p])
      }
    }
    lines = lines.filter { $0.count >= 2 }
    for p in small {
      // the line whose letters reach around it: a dot sits just above, a comma just below
      if let i = lines.indices.min(by: { a, b in
        abs(Double(core(lines[a]).0 + core(lines[a]).1) / 2 - p.cy)
          < abs(Double(core(lines[b]).0 + core(lines[b]).1) / 2 - p.cy)
      }) {
        let (top, foot) = core(lines[i])
        let h = Double(foot - top)
        if p.cy >= Double(top) - 0.7 * h && p.cy <= Double(foot) + 0.5 * h { lines[i].append(p) }
      }
    }
    return lines.sorted { core($0).0 < core($1).0 }
  }

  /// The lines above `from`, then those reaching below it that go on the stack: each a line further at the spacing of the
  /// two lines before it (within a quarter) and with letters of their height (within a third). Nil when no line
  /// below `from` does: a verse stack needs two lines to set its spacing, and a line at another spacing or size is
  /// other text (the footer, the next line's tempo or title).
  static func stackedLines(_ lines: [[Piece]], from: Int) -> [[Piece]]? {
    func core(_ line: [Piece]) -> (top: Int, foot: Int) {
      let tops = line.map(\.y0).sorted(), bottoms = line.map(\.y1).sorted()
      return (tops[tops.count / 2], bottoms[bottoms.count / 2])
    }
    var kept: [[Piece]] = []
    var deeper = false
    for line in lines {
      let c = core(line)
      // a line the usual band held whole; one it cut through must go on the stack too
      if c.foot <= from {
        kept.append(line)
        continue
      }
      guard kept.count >= 2 else { break }
      let last = core(kept[kept.count - 1]), before = core(kept[kept.count - 2])
      let pitch = Double(last.top - before.top), height = Double(last.foot - last.top)
      let step = Double(c.top - last.top), h = Double(c.foot - c.top)
      guard height > 0, pitch > height, pitch <= 3 * height, step >= 0.75 * pitch, step <= 1.25 * pitch,
        abs(h - height) <= 0.34 * height
      else { break }
      kept.append(line)
      deeper = true
    }
    return deeper ? kept : nil
  }

  /// A line cut into words at gaps wider than a letter space, with its hyphens and extenders, each word placed on
  /// a note.
  /// A lyric line's typical distance from a word's centre to its note's, in word widths (measured: lyric lines
  /// 0.0-0.5, the chord band and stray lines 0.7-4).
  static let centredMax = 0.75

  static func lineWords(_ line: [Piece], rules: [Piece], heads: [(x: Double, id: String)], staff: Int, verse: Int,
                        sp: Double) -> [Word] {
    let heights = line.map(\.h).sorted()
    let letter = Double(heights[heights.count * 3 / 4])
    let tops = line.map(\.y0).sorted(), bottoms = line.map(\.y1).sorted()
    let top = Double(tops[tops.count / 2]), foot = Double(bottoms[bottoms.count / 2])
    // a hyphen: a short flat dash at about mid-letter height
    func isHyphen(_ p: Piece) -> Bool {
      Double(p.h) <= 0.3 * letter && p.w >= p.h + 1 && Double(p.w) <= 1.6 * letter
        && p.cy > top + 0.2 * (foot - top) && p.cy < foot - 0.15 * (foot - top)
    }
    let hyphens = line.filter(isHyphen)
    var groups: [[Piece]] = []
    for p in line.filter({ !isHyphen($0) }).sorted(by: { $0.x0 < $1.x0 }) {
      // a hyphen between the two pieces keeps them apart (by its centre: a tight hyphen's box overlaps theirs)
      if let g = groups.last, let b = g.last, Double(p.x0 - g.map(\.x1).max()!) <= 0.45 * letter,
        !hyphens.contains(where: { $0.cx > b.cx && $0.cx < p.cx }) {
        groups[groups.count - 1].append(p)
      } else {
        groups.append([p])
      }
    }
    // words set so close they touch ("rainlove"): a word over two or more notes is cut between them at a gap
    // clearly wider than its letter spacing
    var split: [[Piece]] = []
    for g in groups {
      let x0 = g.map(\.x0).min()!, x1 = g.map(\.x1).max()!
      let inside = heads.map(\.x).filter { Double(x0) <= $0 && $0 <= Double(x1) }
      guard inside.count >= 2, g.count >= 4 else { split.append(g); continue }
      var gaps: [(at: Int, size: Int)] = []
      var reach = g[0].x1
      for i in 1..<g.count {
        gaps.append((i, g[i].x0 - reach))
        reach = max(reach, g[i].x1)
      }
      let typical = gaps.map(\.size).sorted()[gaps.count / 2]
      var cuts: [Int] = []
      for (a, b) in zip(inside, inside.dropFirst()) {
        let between = gaps.filter { gap in
          let mid = Double(g[gap.at].x0)
          return a < mid && mid < b
        }
        if let widest = between.max(by: { $0.size < $1.size }),
          Double(widest.size) >= max(2 * Double(typical), 0.12 * letter) {
          cuts.append(widest.at)
        }
      }
      var start = 0
      for c in cuts.sorted() where c > start {
        split.append(Array(g[start..<c]))
        start = c
      }
      split.append(Array(g[start...]))
    }
    let boxes = split.map { g in
      Piece(x0: g.map(\.x0).min()!, y0: g.map(\.y0).min()!, x1: g.map(\.x1).max()!, y1: g.map(\.y1).max()!)
    }
    var out: [Word] = []
    var offsets: [Double] = []   // each word's centre from its note's, in word widths
    var used = Set<Int>(), lastNote = -1
    for (i, b) in boxes.enumerated() where Double(b.h) >= 0.5 * letter {
      let nextX = i + 1 < boxes.count ? boxes[i + 1].cx : Double(Int32.max)
      let hyphen = hyphens.contains { $0.cx > Double(b.x1) - 0.3 * letter && $0.cx < nextX }
      let extend = rules.contains { r in
        Double(r.x0) >= Double(b.x1) - 0.3 * letter && Double(r.x0) <= Double(b.x1) + 1.5 * letter
          && abs(Double(r.y0) - foot) <= 0.5 * letter
      }
      // the nearest note from the word's span, after the note the word before took
      var best: Int?, bestD = 2.5 * sp
      for (n, hd) in heads.enumerated() where n > lastNote && !used.contains(n) {
        let d = hd.x < Double(b.x0) ? Double(b.x0) - hd.x : hd.x > Double(b.x1) ? hd.x - Double(b.x1) : 0
        let tie = abs(hd.x - b.cx)
        // under the word itself: the first such note, where the word starts
        if d == 0, best.map({ bestD > 0 || heads[$0].x > hd.x }) ?? true {
          best = n
          bestD = 0
          continue
        }
        if bestD > 0, d < bestD || (d == bestD && best.map { abs(heads[$0].x - b.cx) > tie } ?? true) {
          best = n
          bestD = d
        }
      }
      guard let n = best else { continue }
      used.insert(n)
      lastNote = n
      // further notes under the word itself, for a word that reads with a hyphen inside
      var more: [String] = []
      for m in heads.indices where m > n && heads[m].x > Double(b.x0) && heads[m].x < Double(b.x1) && !used.contains(m) {
        more.append(heads[m].id)
      }
      out.append(Word(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, staff: staff, verse: verse, noteID: heads[n].id,
                      hyphenAfter: hyphen, extendAfter: extend, moreNoteIDs: more))
      offsets.append(abs(heads[n].x - b.cx) / Double(max(b.w, 1)))
    }
    // lyrics sit centred under their notes; a line whose words mostly do not is other text (often the chord
    // band of the line below)
    let o = offsets.sorted()
    if o.count >= 2 && o[o.count / 2] > centredMax { return [] }
    return out
  }
}
