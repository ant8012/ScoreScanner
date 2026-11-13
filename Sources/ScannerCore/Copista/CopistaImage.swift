import Foundation

// Image work for the copisteria reader (kobimusic/copisteria, Apache-2.0): a port of its page handling
// (vision/page/staves.py, the ink parts of front.py) and of Pillow's Lanczos resize, which sets the detector's input.
// Rounding follows Python: round() is half-to-even, int() truncates.

enum Copista {}

@inline(__always) func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }
/// Python's round(x, digits): the exact binary value rounded to `digits` decimals (printf does the same).
func pyRound(_ x: Double, _ digits: Int) -> Double {
  Double(String(format: "%.\(digits)f", x)) ?? x
}

extension Copista {
  /// An 8-bit grey page, row major.
  struct Gray {
    let width: Int, height: Int
    var pixels: [UInt8]
    subscript(y: Int, x: Int) -> UInt8 { pixels[y * width + x] }
  }

  /// A float page, row major (the cleaned page's levels are not whole numbers).
  struct Levels {
    let width: Int, height: Int
    var values: [Float]
  }

  /// A boolean mask, row major.
  struct Mask {
    let width: Int, height: Int
    var bits: [Bool]
    subscript(y: Int, x: Int) -> Bool { bits[y * width + x] }
  }

  // MARK: numpy-style statistics

  /// np.percentile (linear) of a byte image, from its histogram.
  static func percentile(_ hist: [Int], count: Int, _ q: Double) -> Double {
    let idx = q / 100 * Double(count - 1)
    let lo = Int(idx.rounded(.down)), hi = min(lo + 1, count - 1)
    func kth(_ k: Int) -> Double {
      var seen = 0
      for (v, c) in hist.enumerated() {
        seen += c
        if seen > k { return Double(v) }
      }
      return 255
    }
    let a = kth(lo), b = kth(hi), t = idx - Double(lo)
    return t >= 0.5 ? b - (b - a) * (1 - t) : a + (b - a) * t
  }

  static func histogram(_ g: Gray, rows: Range<Int>? = nil, cols: Range<Int>? = nil) -> ([Int], Int) {
    var h = [Int](repeating: 0, count: 256)
    let rs = rows ?? 0..<g.height, cs = cols ?? 0..<g.width
    g.pixels.withUnsafeBufferPointer { p in
      for y in rs { let o = y * g.width; for x in cs { h[Int(p[o + x])] += 1 } }
    }
    return (h, rs.count * cs.count)
  }

  /// np.percentile (linear) of floats.
  static func percentile(_ values: [Float], _ q: Double) -> Double {
    precondition(!values.isEmpty)
    let s = values.sorted()
    let idx = q / 100 * Double(s.count - 1)
    let lo = Int(idx.rounded(.down)), hi = min(lo + 1, s.count - 1)
    let a = Double(s[lo]), b = Double(s[hi]), t = idx - Double(lo)
    return t >= 0.5 ? b - (b - a) * (1 - t) : a + (b - a) * t
  }

  static func median(_ values: [Double]) -> Double {
    let s = values.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
  }

  // MARK: Pillow's Lanczos resize (Resample.c, 8 bits per channel)

  private static let precisionBits = 32 - 8 - 2

  private static func lanczos(_ x: Double) -> Double {
    func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(x * .pi) / (x * .pi) }
    return (-3.0 <= x && x < 3.0) ? sinc(x) * sinc(x / 3) : 0
  }

  private static func coefficients(inSize: Int, outSize: Int) -> (bounds: [(Int, Int)], k: [Int32], ksize: Int) {
    let scale = Double(inSize) / Double(outSize)
    let filterscale = max(scale, 1.0)
    let support = 3.0 * filterscale
    let ksize = Int(support.rounded(.up)) * 2 + 1
    var bounds: [(Int, Int)] = []
    var kk = [Int32](repeating: 0, count: outSize * ksize)
    for xx in 0..<outSize {
      let center = (Double(xx) + 0.5) * scale
      let ss = 1.0 / filterscale
      var xmin = Int(center - support + 0.5)
      if xmin < 0 { xmin = 0 }
      var xmax = Int(center + support + 0.5)
      if xmax > inSize { xmax = inSize }
      xmax -= xmin
      var w = [Double](repeating: 0, count: xmax)
      var ww = 0.0
      for x in 0..<xmax {
        w[x] = lanczos((Double(x + xmin) - center + 0.5) * ss)
        ww += w[x]
      }
      for x in 0..<xmax {
        let v = ww != 0 ? w[x] / ww : w[x]
        let f = Double(1 << precisionBits)
        kk[xx * ksize + x] = Int32(v < 0 ? (-0.5 + v * f) : (0.5 + v * f))
      }
      bounds.append((xmin, xmax))
    }
    return (bounds, kk, ksize)
  }

  @inline(__always) private static func clip8(_ v: Int) -> UInt8 {
    let s = v >> precisionBits
    return UInt8(max(0, min(255, s)))
  }

  /// Image.resize((w, h), Image.LANCZOS) for an "L" image: horizontal pass, then vertical, 8 bits in between.
  static func resizeLanczos(_ g: Gray, width w: Int, height h: Int) -> Gray {
    var cur = g
    if w != g.width {
      let (b, k, ks) = coefficients(inSize: g.width, outSize: w)
      var out = [UInt8](repeating: 0, count: w * g.height)
      g.pixels.withUnsafeBufferPointer { src in
        for y in 0..<g.height {
          let row = y * g.width
          for xx in 0..<w {
            let (xmin, xmax) = b[xx]
            var ss = 1 << (precisionBits - 1)
            for x in 0..<xmax { ss += Int(src[row + xmin + x]) * Int(k[xx * ks + x]) }
            out[y * w + xx] = clip8(ss)
          }
        }
      }
      cur = Gray(width: w, height: g.height, pixels: out)
    }
    if h != cur.height {
      let (b, k, ks) = coefficients(inSize: cur.height, outSize: h)
      var out = [UInt8](repeating: 0, count: cur.width * h)
      let cw = cur.width
      cur.pixels.withUnsafeBufferPointer { src in
        for yy in 0..<h {
          let (ymin, ymax) = b[yy]
          for x in 0..<cw {
            var ss = 1 << (precisionBits - 1)
            for y in 0..<ymax { ss += Int(src[(ymin + y) * cw + x]) * Int(k[yy * ks + y]) }
            out[yy * cw + x] = clip8(ss)
          }
        }
      }
      cur = Gray(width: cw, height: h, pixels: out)
    }
    return cur
  }

  // MARK: staff lines from the ink (vision/page/staves.py)

  struct Line { var y: Double; var x0: Int; var x1: Int; var thickness: Int; var score: Double }

  struct InkStaff {
    var lines: [Line]
    var top: Double { lines[0].y }
    var bottom: Double { lines[lines.count - 1].y }
    var spacing: Double { (bottom - top) / Double(lines.count - 1) }
    var x0: Int { lines.map(\.x0).min()! }
    var x1: Int { lines.map(\.x1).max()! }
  }

  struct StaffMap {
    var staves: [InkStaff]
    var spacing: Double {
      let s = staves.map(\.spacing).sorted()
      return s.isEmpty ? 0 : s[s.count / 2]
    }
  }

  /// The staff finder's threshold: not quite Otsu (see staves.py), 254 on any page with pure white.
  static func otsu(_ hist: [Int]) -> Int {
    let h = hist.map(Double.init)
    let total = h.reduce(0, +)
    var w0 = [Double](repeating: 0, count: 256), m0 = w0, cs = w0, rcs = w0
    var acc = 0.0, accl = 0.0
    for l in 0..<256 { acc += h[l]; accl += h[l] * Double(l); w0[l] = acc; cs[l] = accl }
    var r = 0.0
    for l in stride(from: 255, through: 0, by: -1) { r += h[l] * Double(l); rcs[l] = r }
    var best = 0, bv = -Double.infinity
    for t in 0..<255 {
      m0[t] = cs[t] / max(w0[t], 1)
      let w1t = total - w0[t]
      let m1 = rcs[t + 1] / max(total - w0[t + 1], 1)
      let between = w0[t] * w1t * (m0[t] - m1) * (m0[t] - m1)
      if between > bv { bv = between; best = t }
    }
    return best
  }

  static func findStaves(_ g: Gray, minRunFrac: Double = 0.05, relCover: Double = 0.7, floorCover: Double = 0.05,
                         closePx: Int = 2, paperTol: Double = 0) -> StaffMap {
    let (hist, n) = histogram(g)
    var thr = otsu(hist)
    if paperTol != 0 {
      let paper = percentile(hist, count: n, 50), ink = percentile(hist, count: n, 1)
      thr = min(thr, Int((paper - paperTol * max(1.0, paper - ink)).rounded(.up)))
    }
    let W = g.width, H = g.height
    // ink, then horizontal gaps under closePx bridged (a pixel is ink with ink within k on both sides)
    var ink = [Bool](repeating: false, count: W * H)
    g.pixels.withUnsafeBufferPointer { p in for i in 0..<(W * H) { ink[i] = Int(p[i]) < thr } }
    if closePx > 0 {
      var closed = ink
      for y in 0..<H {
        let o = y * W
        for x in 0..<W where !ink[o + x] {
          var l = false, r = false
          for s in 1...closePx {
            if x - s >= 0 && ink[o + x - s] { l = true }
            if x + s < W && ink[o + x + s] { r = true }
          }
          if l && r { closed[o + x] = true }
        }
      }
      ink = closed
    }
    let minRun = max(8, Int(minRunFrac * Double(W)))
    var coverage = [Double](repeating: 0, count: H)
    var lx0 = [Int](repeating: W, count: H), lx1 = [Int](repeating: 0, count: H)
    for y in 0..<H {
      let o = y * W
      var x = 0, sum = 0
      while x < W {
        if ink[o + x] {
          let s = x
          while x < W && ink[o + x] { x += 1 }
          if x - s >= minRun { sum += x - s; lx0[y] = min(lx0[y], s); lx1[y] = max(lx1[y], x) }
        } else { x += 1 }
      }
      coverage[y] = Double(sum) / Double(W)
    }
    let minCover = max(floorCover, relCover * percentile(coverage.map(Float.init), 95))
    // runs of covered rows are lines
    var lines: [Line] = []
    var y = 0
    while y < H {
      if coverage[y] >= minCover {
        let s = y
        while y < H && coverage[y] >= minCover { y += 1 }
        var wy = 0.0, ws = 0.0, x0 = Int.max, x1 = Int.min, sc = 0.0
        for r in s..<y {
          wy += Double(r) * coverage[r]; ws += coverage[r]
          x0 = min(x0, lx0[r]); x1 = max(x1, lx1[r]); sc = max(sc, coverage[r])
        }
        lines.append(Line(y: wy / ws, x0: x0, x1: x1, thickness: y - s, score: sc))
      } else { y += 1 }
    }
    lines = joinSplitLines(lines)
    return StaffMap(staves: groupStaves(lines))
  }

  private static func joinSplitLines(_ lines: [Line], frac: Double = 0.3) -> [Line] {
    guard lines.count >= 2 else { return lines }
    let typical = median(zip(lines, lines.dropFirst()).map { $1.y - $0.y })
    var out = [lines[0]]
    for line in lines.dropFirst() {
      let prev = out[out.count - 1]
      if line.y - prev.y >= frac * typical { out.append(line); continue }
      let w0 = prev.score * Double(prev.thickness), w1 = line.score * Double(line.thickness)
      out[out.count - 1] = Line(y: (prev.y * w0 + line.y * w1) / (w0 + w1), x0: min(prev.x0, line.x0),
                                x1: max(prev.x1, line.x1), thickness: prev.thickness + line.thickness,
                                score: max(prev.score, line.score))
    }
    return out
  }

  private static func groupStaves(_ lines: [Line], tol: Double = 0.25) -> [InkStaff] {
    let ys = lines.map(\.y)
    guard ys.count >= 5 else { return [] }
    let typical = median(zip(ys, ys.dropFirst()).map { $1 - $0 })
    var found: [(Double, [Int])] = []
    var seen = Set<[Int]>()
    for i in 0..<ys.count {
      for j in (i + 1)..<min(i + 9, ys.count) {
        for k in 1...4 {
          let sp = (ys[j] - ys[i]) / Double(k)
          guard 0.6 * typical <= sp && sp <= 1.5 * typical else { continue }
          // the five lines at this spacing below line i: the nearest within tol spacings of each step
          var members = [i]
          var ok = true
          for step in 1...4 {
            let want = ys[i] + Double(step) * sp
            var m = -1, best = Double.infinity
            for q in (i + 1)..<ys.count where abs(ys[q] - want) < best { best = abs(ys[q] - want); m = q }
            if m < 0 || best > tol * sp { ok = false; break }
            members.append(m)
          }
          guard ok, Set(members).count == 5, !seen.contains(members) else { continue }
          seen.insert(members)
          let run = members.map { lines[$0] }
          if run.map(\.x1).min()! <= run.map(\.x0).max()! { continue }
          found.append((run.reduce(0) { $0 + $1.score }, members))
        }
      }
    }
    var used = Set<Int>(), staves: [InkStaff] = []
    let order = found.indices.sorted { found[$0].0 != found[$1].0 ? found[$0].0 > found[$1].0 : $0 < $1 }
    for idx in order {
      let members = found[idx].1
      if used.isDisjoint(with: members) {
        used.formUnion(members)
        staves.append(InkStaff(lines: members.map { lines[$0] }))
      }
    }
    return staves.sorted { $0.top < $1.top }
  }

  // MARK: the sheet inside a scan's frame, and the ink (front.py)

  static let framePaper = 0.5, frameMax = 0.35, frameSliver = 0.01, frameMargin = 0.005

  /// gray < paper - 0.35 (paper - ink), over float levels.
  static func dark(_ v: [Float], width: Int, height: Int) -> Mask {
    let paper = percentile(v, 50), ink = percentile(v, 1)
    let cut = paper - 0.35 * max(1.0, paper - ink)
    return Mask(width: width, height: height, bits: v.map { Double($0) < cut })
  }

  private static func sheetEdges(_ paper: [Double]) -> (Int, Int) {
    let n = paper.count
    let edge = framePaper * median(Array(paper[(n / 4)..<(3 * n / 4)]))
    let sliver = max(2, Int(frameSliver * Double(n)))
    let margin = max(2, pyRound(frameMargin * Double(n)))
    func inward(_ line: [Double]) -> Int {
      var k = 0
      while k < sliver && k < n && line[k] >= edge { k += 1 }
      if k == n || line[k] >= edge { return 0 }
      while k < n && line[k] < edge { k += 1 }
      return Double(k) <= frameMax * Double(n) ? k + margin : 0
    }
    let a = inward(paper), b = n - inward(paper.reversed())
    return b > a ? (a, b) : (0, n)
  }

  static func frame(_ d: Mask) -> (Int, Int, Int, Int) {
    let H = d.height, W = d.width
    var x0 = 0, y0 = 0, x1 = W, y1 = H
    for _ in 0..<2 {
      var cols = [Double](repeating: 0, count: W), rows = [Double](repeating: 0, count: H)
      for y in y0..<y1 { for x in 0..<W where d.bits[y * W + x] { cols[x] += 1 } }
      for y in 0..<H { for x in x0..<x1 where d.bits[y * W + x] { rows[y] += 1 } }
      cols = cols.map { 1.0 - $0 / Double(y1 - y0) }
      rows = rows.map { 1.0 - $0 / Double(x1 - x0) }
      (x0, x1) = sheetEdges(cols)
      (y0, y1) = sheetEdges(rows)
    }
    return (x0, y0, x1, y1)
  }

  /// The page with a scan's frame painted the paper's tone (front.unframe).
  static func unframe(_ v: [Float], width: Int, height: Int, integral: Bool) -> [Float] {
    let (x0, y0, x1, y1) = frame(dark(v, width: width, height: height))
    if (x0, y0, x1, y1) == (0, 0, width, height) || x1 <= x0 || y1 <= y0 { return v }
    var inner: [Float] = []
    inner.reserveCapacity((x1 - x0) * (y1 - y0))
    for y in y0..<y1 { for x in x0..<x1 { inner.append(v[y * width + x]) } }
    var fill = Float(percentile(inner, 50))
    if integral { fill = fill.rounded(.towardZero) }        // np.full_like on uint8 truncates
    var out = [Float](repeating: fill, count: v.count)
    for y in y0..<y1 { for x in x0..<x1 { out[y * width + x] = v[y * width + x] } }
    return out
  }

  static func inkMask(_ v: [Float], width: Int, height: Int, integral: Bool) -> Mask {
    dark(unframe(v, width: width, height: height, integral: integral), width: width, height: height)
  }

  /// scipy.ndimage 'reflect' index.
  @inline(__always) private static func reflect(_ i: Int, _ n: Int) -> Int {
    var i = i
    while i < 0 || i >= n { i = i < 0 ? -i - 1 : 2 * n - i - 1 }
    return i
  }

  /// A separable max (or min) filter of size m, ndimage conventions: the window starts at i - m/2 - origin.
  private static func extremeFilter(_ a: [Float], w: Int, h: Int, m: Int, origin: Int, max useMax: Bool) -> [Float] {
    var tmp = a, out = a
    let start = -(m / 2) - origin
    for y in 0..<h {
      for x in 0..<w {
        var v = a[y * w + reflect(x + start, w)]
        for k in 1..<m { let c = a[y * w + reflect(x + start + k, w)]; v = useMax ? Swift.max(v, c) : Swift.min(v, c) }
        tmp[y * w + x] = v
      }
    }
    for y in 0..<h {
      for x in 0..<w {
        var v = tmp[reflect(y + start, h) * w + x]
        for k in 1..<m { let c = tmp[reflect(y + start + k, h) * w + x]; v = useMax ? Swift.max(v, c) : Swift.min(v, c) }
        out[y * w + x] = v
      }
    }
    return out
  }

  private static func uniformFilter(_ a: [Float], w: Int, h: Int, m: Int) -> [Float] {
    var tmp = a, out = a
    let start = -(m / 2)
    for y in 0..<h {
      for x in 0..<w {
        var s = 0.0
        for k in 0..<m { s += Double(a[y * w + reflect(x + start + k, w)]) }
        tmp[y * w + x] = Float(s / Double(m))
      }
    }
    for y in 0..<h {
      for x in 0..<w {
        var s = 0.0
        for k in 0..<m { s += Double(tmp[reflect(y + start + k, h) * w + x]) }
        out[y * w + x] = Float(s / Double(m))
      }
    }
    return out
  }

  /// The page as black ink on white for the line finder, its paper's shading divided out (front.clean_page).
  static func cleanPage(_ g: Gray) -> Gray {
    let H = g.height, W = g.width
    let k = max(15, Int(Double(min(H, W)) / 30)) | 1
    let sh = (H + 3) / 4, sw = (W + 3) / 4
    var small = [Float](repeating: 0, count: sh * sw)
    for y in 0..<sh { for x in 0..<sw { small[y * sw + x] = Float(g[y * 4, x * 4]) } }
    let m = max(3, k / 4)
    // grey_closing: dilation (an even size shifts its window one to the right), then erosion
    var bg = extremeFilter(small, w: sw, h: sh, m: m, origin: m % 2 == 0 ? -1 : 0, max: true)
    bg = extremeFilter(bg, w: sw, h: sh, m: m, origin: 0, max: false)
    bg = uniformFilter(bg, w: sw, h: sh, m: m)
    var flat = [Float](repeating: 0, count: H * W)
    for y in 0..<H {
      for x in 0..<W {
        let b = max(bg[(y / 4) * sw + x / 4], 1.0)
        flat[y * W + x] = min(255, max(0, Float(g[y, x]) / b * 255.0))
      }
    }
    let ink = inkMask(flat, width: W, height: H, integral: false)
    return Gray(width: W, height: H, pixels: ink.bits.map { $0 ? 0 : 255 })
  }

  /// Share of the rows between y0 and y1 that hold ink within `reach` px of column x (front._ink_run).
  static func inkRun(_ mask: Mask, x: Double, y0: Double, y1: Double, reach: Int = 2) -> Double {
    let H = mask.height, W = mask.width
    let a = max(0, pyRound(y0)), b = min(H, pyRound(y1))
    let xa = max(0, pyRound(x) - reach), xb = min(W, pyRound(x) + reach + 1)
    if b - a < 2 || xb <= xa { return b - a < 2 ? 1.0 : 0.0 }
    var hit = 0
    for y in a..<b {
      let o = y * W
      for xx in xa..<xb where mask.bits[o + xx] { hit += 1; break }
    }
    return Double(hit) / Double(b - a)
  }
}
