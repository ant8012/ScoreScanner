import Foundation
#if canImport(Android)
import Android
#endif

extension Copista.Writer {
  /// The chord finder's words without the tuplet numbers it took for text: a triplet's "3" over a beam reads as a
  /// "B" chord. A word goes when a tuplet number the detector is sure of covers most of it and a beam or note sits
  /// just below that number, where a tuplet's number is printed.
  static func withoutTupletNumbers(_ words: [ChordFinder.Proposal], _ rd: Copista.Reading) -> [ChordFinder.Proposal] {
    let L = rd.layout
    let numbers = L.syms.filter { s in
      guard (rd.tok[s.i]?.realP ?? 0) >= 0.9, Copista.family(cls(rd, s.i)) == "tupletNum", s.staff >= 0,
        s.staff < L.staves.count else { return false }
      let sp = L.staves[s.staff].sp
      return L.syms.contains { o in
        guard isReal(rd, o.i) else { return false }
        let f = Copista.family(cls(rd, o.i))
        return (f == "beam" || f == "note" || f == "tupletBracket")
          && o.box.1 >= s.box.3 - 0.3 * sp && o.box.1 - s.box.3 <= 2 * sp
          && o.box.0 - sp <= s.cx && s.cx <= o.box.2 + sp
      }
    }
    guard !numbers.isEmpty else { return words }
    return words.filter { w in
      let area = Double(max(1, (w.x1 - w.x0) * (w.y1 - w.y0)))
      return !numbers.contains { n in
        let ox = min(Double(w.x1), n.box.2) - max(Double(w.x0), n.box.0)
        let oy = min(Double(w.y1), n.box.3) - max(Double(w.y0), n.box.1)
        return ox > 0 && oy > 0 && ox * oy >= 0.5 * area
      }
    }
  }
}

extension Copista.Writer {
  /// The chord finder's words without the notation it took for text, which the chord and text readers would
  /// otherwise read as words:
  /// - a note above (or below) the staff with its ledger lines and stem: a stem crossed by two or three ledger
  ///   lines reads as a capital "E". A word goes when most of it lies in that note's column, between its head and
  ///   the staff. A chord is never printed there: it would sit on the note.
  /// - a pedal sign the detector found ("Ped.", the release star), which reads as "Led." or "Re.".
  static func withoutNotation(_ words: [ChordFinder.Proposal], _ rd: Copista.Reading) -> [ChordFinder.Proposal] {
    let L = rd.layout
    var zones: [Copista.Box] = []
    for s in L.syms where s.staff >= 0 && s.staff < L.staves.count && isReal(rd, s.i) {
      let st = L.staves[s.staff], sp = st.sp
      switch Copista.family(cls(rd, s.i)) {
      case "note":
        if s.box.3 <= st.y0 + 0.25 * sp {
          zones.append((s.box.0 - 0.6 * sp, s.box.1, s.box.2 + 0.6 * sp, st.y0 + 0.25 * sp))
        } else if s.box.1 >= st.y1 - 0.25 * sp {
          zones.append((s.box.0 - 0.6 * sp, st.y1 - 0.25 * sp, s.box.2 + 0.6 * sp, s.box.3))
        }
      case "pedal" where s.box.2 - s.box.0 <= 4 * sp:
        zones.append(s.box)
      default:
        break
      }
    }
    guard !zones.isEmpty else { return words }
    return words.filter { w in
      let area = Double(max(1, (w.x1 - w.x0) * (w.y1 - w.y0)))
      return !zones.contains { z in
        let ox = min(Double(w.x1), z.2) - max(Double(w.x0), z.0)
        let oy = min(Double(w.y1), z.3) - max(Double(w.y0), z.1)
        return ox > 0 && oy > 0 && ox * oy >= 0.6 * area
      }
    }
  }
}

extension Copista {
  /// Bars filled with rhythm slashes: a stemless slash per beat on the middle line, as lead sheets print solos and
  /// comping ("fill with slashes"). The detector has no slash class: it reads them as quarter notes on the middle
  /// line, as quarter rests, or not at all. So the slashes are found in the page itself, and the detector's reading
  /// only decides whether anything else is in the bar.
  ///
  /// A slash is a straight, thick stroke rising to the right, centred on the middle line, 1.2-2.7 staff spaces
  /// tall. Staff lines (thin runs) and bar lines and stems (staff-tall runs) are taken out column by column first, so
  /// a slash crossing a line stays whole on a tilted photo. A bar counts only with two or more slashes and nothing
  /// else read in it: every note or rest the detector put there sits on a slash.
  ///
  /// Measured on 60 MuseScore lead sheets with trap bars (B quarters, eighths, halves, accents on the middle line),
  /// clean and rough: 854 of 855 slash bars, none false. On 436 real fake-book and Real Book pages, printed and
  /// handwritten, it flags 22 bars, all slash bars.
  enum Slashes {
    static let heightRange = 1.2...2.7, widthRange = 0.9...2.2
    /// Of the stroke from horizontal; quarter rests lean at 79° and more.
    static let angleRange = 42.0...70.0
    static let elongationMin = 2.6, thicknessRange = 0.18...0.9, centreTolerance = 0.6

    struct Blob {
      var x0: Int, y0: Int, x1: Int, y1: Int
      var height: Double, width: Double, angle: Double, rising: Bool, elongation: Double, thickness: Double
      var centre: Double
      var cx: Double { Double(x0 + x1) / 2 }
      var isSlash: Bool {
        heightRange.contains(height) && widthRange.contains(width) && angleRange.contains(angle) && rising
          && elongation >= elongationMin && thicknessRange.contains(thickness) && abs(centre) <= centreTolerance
      }
    }

    /// Slash bars by layout staff and bar, with the number of slashes found in each.
    static func bars(_ page: Gray, _ rd: Reading) -> [Int: [Int: Int]] {
      let L = rd.layout
      var out: [Int: [Int: Int]] = [:]
      for (k, st) in L.staves.enumerated() where !st.bars.isEmpty {
        let found = blobs(page, st).filter(\.isSlash)
        guard found.count >= 2 else { continue }
        let sp = st.sp
        for j in st.bars.indices {
          let left = L.syms[st.bars[j]].box.0
          let right = j + 1 < st.bars.count ? L.syms[st.bars[j + 1]].box.0 : st.x1
          let inside = found.filter { left <= $0.cx && $0.cx < right }
          guard inside.count >= 2 else { continue }
          let unexplained = L.syms.contains { s in
            guard s.staff == k, s.bar == j, Writer.isReal(rd, s.i) else { return false }
            let f = family(Writer.cls(rd, s.i))
            guard f == "note" || f == "rest" else { return false }
            return !inside.contains { Double($0.x0) - 0.3 * sp <= s.cx && s.cx <= Double($0.x1) + 0.3 * sp }
          }
          if !unexplained { out[k, default: [:]][j] = inside.count }
        }
      }
      return out
    }

    /// Ink around a staff's middle line, cut into blobs and measured in staff spaces.
    static func blobs(_ page: Gray, _ st: Staff) -> [Blob] {
      let sp = st.sp
      let mid = (st.y0 + st.y1) / 2
      let r0 = max(0, Int(mid - 2 * sp)), r1 = min(page.height, Int(mid + 2 * sp) + 1)
      let c0 = max(0, Int(st.x0)), c1 = min(page.width, Int(st.x1) + 1)
      let w = c1 - c0, h = r1 - r0
      guard w > 2, h > 2 else { return [] }
      var mask = [Bool](repeating: false, count: w * h)
      for y in 0..<h { for x in 0..<w where page.pixels[(r0 + y) * page.width + c0 + x] < 160 { mask[y * w + x] = true } }
      // column by column, drop line-thin runs (staff lines at any tilt) and staff-tall runs (bar lines, stems)
      let thin = max(2, Int(0.42 * sp)), tall = Int(3 * sp)
      for x in 0..<w {
        var y = 0
        while y < h {
          guard mask[y * w + x] else { y += 1; continue }
          var end = y
          while end < h && mask[end * w + x] { end += 1 }
          if end - y <= thin || end - y >= tall { for yy in y..<end { mask[yy * w + x] = false } }
          y = end
        }
      }
      var out: [Blob] = []
      for (c, pix) in ChordFinder.label8(mask, width: w, height: h) where Double(c.area) >= 0.3 * sp * sp {
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for yy in 0..<c.h {
          for xx in 0..<c.w where pix[yy * c.w + xx] {
            let fx = Double(xx), fy = Double(yy)
            n += 1; sx += fx; sy += fy; sxx += fx * fx; syy += fy * fy; sxy += fx * fy
          }
        }
        let mx = sx / n, my = sy / n
        let cxx = sxx / n - mx * mx, cyy = syy / n - my * my, cxy = sxy / n - mx * my
        let tr = cxx + cyy, root = sqrt(max(0, tr * tr / 4 - (cxx * cyy - cxy * cxy)))
        let l1 = tr / 2 + root, l2 = max(1e-6, tr / 2 - root)
        out.append(Blob(
          x0: c.x0 + c0, y0: c.y0 + r0, x1: c.x1 + c0, y1: c.y1 + r0,
          height: Double(c.h) / sp, width: Double(c.w) / sp,
          angle: abs(0.5 * atan2(-2 * cxy, cxx - cyy) * 180 / .pi), rising: cxy < 0,
          elongation: sqrt(l1 / l2), thickness: 4 * sqrt(l2) / sp,
          centre: (Double(c.y0 + r0) + my - mid) / sp))
      }
      return out
    }
  }
}
