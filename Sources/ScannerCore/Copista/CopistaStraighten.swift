import Foundation

extension Copista {
  static let straightenMinDegrees = 0.1, straightenMaxDegrees = 1.0
  /// The least a staff line must drift across the staves (in staff spaces) for the page to be straightened.
  static let straightenMinShiftSp = 1.0
  /// A photo of a book tilts and curls more than a scan: up to this many degrees is measured on such a page.
  static let curlMaxDegrees = 6.0
  /// The page's width is measured in this many strips side by side, each with its own tilt.
  static let curlStrips = 6
  /// The least the tilt of a curled photo changes across its bands and strips, in degrees: flat scans change by up
  /// to 2.9 (Real Book pages tilted 1-2 degrees), phone photos of books by 3.2 to 12.
  static let curlMinSpread = 3.0

  /// The tilt that lines up the ink of one band best, within `limit` tenths of a degree: the row profile of the
  /// pixels sheared about `cx` that is most peaked.
  static func bandTilt(_ ys: [Int32], _ xs: [Int32], rows: Int, cx: Double, limit: Int) -> Double {
    var counts = [Double](repeating: 0, count: rows)
    func score(_ deg: Double) -> Double {
      let t = tan(deg * .pi / 180)
      for i in counts.indices { counts[i] = 0 }
      for i in ys.indices {
        let r = Int((Double(ys[i]) - (Double(xs[i]) - cx) * t).rounded())
        if r >= 0 && r < rows { counts[r] += 1 }
      }
      return counts.reduce(0) { $0 + $1 * $1 }
    }
    var best = 0.0, bv = -1.0
    for k in -limit...limit {
      let a = Double(k) * 0.1, v = score(a)
      if v > bv { bv = v; best = a }
    }
    let coarse = best
    for k in -5...5 {
      let a = coarse + Double(k) * 0.02, v = score(a)
      if v > bv { bv = v; best = a }
    }
    return best
  }

  /// Per band, the median of it and its two nearest (at the top and bottom of the page, the next two in): a band of
  /// words or a picture can pick a stray angle, and a title band alone must not tilt the page.
  static func medianOfThree(_ angles: [Double]) -> [Double] {
    angles.indices.map { i -> Double in
      let lo = max(0, min(i - 1, angles.count - 3))
      let w = angles[lo...min(angles.count - 1, lo + 2)].sorted()
      return w[w.count / 2]
    }
  }

  /// A scanned or photocopied page sits a little crooked, and a copy of a bound book often fans: the top of the page
  /// tilts more than the bottom. On a dense score the staff lines are only nine or ten pixels apart, so a tilt of half
  /// a degree moves a line two staff spaces across the page and the staff finder, which sums whole rows, loses the
  /// staff. The page is measured in overlapping bands down its height, the tilt that lines up each band's ink best,
  /// and every row is shifted back by its own tilt. A page whose staff lines drift less than a staff space across
  /// the staves is returned untouched: the staff finder reads it as it is, and resampling it would only change what
  /// the reader sees (a blank printed staff under a handwritten title turns up once straightened).
  ///
  /// Past a degree the page is a phone photo of a book: its lines also bend along their length as the page curls
  /// toward the spine or the edge, which one tilt per band cannot undo. Such a page is measured again in strips
  /// across its width as well (`curled`), and each column is shifted by the slope summed from the middle out.
  static func straightened(_ g: Gray) -> Gray { straightenedWithMap(g).page }

  /// How a straightened page sits on the page it came from. Straightening only moves pixels up or down their own
  /// column, so a point keeps its x, and its y on the original is `y + offset(x, y)`.
  struct StraightenMap {
    let offset: (Double, Double) -> Double
    static var identity: StraightenMap { StraightenMap { _, _ in 0 } }

    /// A point of the straightened page on the original page.
    func original(x: Double, y: Double) -> (x: Double, y: Double) { (x, y + offset(x, y)) }
  }

  /// `straightened`, with where each of its points lies on the original page (to show what was read there).
  static func straightenedWithMap(_ g: Gray) -> (page: Gray, map: StraightenMap) {
    let W = g.width, H = g.height
    guard W >= 200, H >= 200 else { return (g, .identity) }
    let thr = otsu(histogram(g).0, exact: true)
    let cx = Double(W) / 2
    let band = max(100, H / 11), step = band / 2
    let c0 = Int(0.15 * Double(W)), c1 = Int(0.9 * Double(W))
    var centers: [Double] = [], angles: [Double] = []
    var y0 = 0
    while y0 < H {
      let y1 = min(H, y0 + band)
      var ys: [Int32] = [], xs: [Int32] = []
      for y in y0..<y1 {
        let o = y * W
        var x = c0
        while x < c1 {
          if Int(g.pixels[o + x]) < thr { ys.append(Int32(y - y0)); xs.append(Int32(x)) }
          x += 2
        }
      }
      if ys.count >= 1000 {
        centers.append(Double(y0 + y1) / 2)
        angles.append(bandTilt(ys, xs, rows: y1 - y0, cx: cx, limit: 15))
      }
      if y1 == H { break }
      y0 += step
    }
    guard !angles.isEmpty else { return (g, .identity) }
    let smooth = medianOfThree(angles)
    let steepest = smooth.map(abs).max() ?? 0
    let lineDistance = staffLineDistance(g, threshold: thr)
    let drift = 0.8 * Double(W) * tan(steepest * .pi / 180) / lineDistance
    guard steepest >= straightenMinDegrees, drift >= straightenMinShiftSp else { return (g, .identity) }
    if steepest > straightenMaxDegrees { return curled(g, threshold: thr) ?? (g, .identity) }
    func angle(at y: Double) -> Double {
      if y <= centers[0] { return smooth[0] }
      if y >= centers[centers.count - 1] { return smooth[smooth.count - 1] }
      var i = 0
      while centers[i + 1] < y { i += 1 }
      let f = (y - centers[i]) / (centers[i + 1] - centers[i])
      return smooth[i] * (1 - f) + smooth[i + 1] * f
    }
    var out = [UInt8](repeating: 255, count: W * H)
    g.pixels.withUnsafeBufferPointer { src in
      out.withUnsafeMutableBufferPointer { dst in
        for y in 0..<H {
          let t = tan(angle(at: Double(y)) * .pi / 180)
          let o = y * W
          for x in 0..<W {
            let sy = Double(y) + (Double(x) - cx) * t
            if sy < 0 || sy > Double(H - 1) { continue }
            let a = Int(sy), f = sy - Double(a), b = min(H - 1, a + 1)
            let v = Double(src[a * W + x]) * (1 - f) + Double(src[b * W + x]) * f
            dst[o + x] = UInt8(max(0, min(255, v.rounded())))
          }
        }
      }
    }
    // the same shift as each row above
    let map = StraightenMap { x, y in (x - cx) * tan(angle(at: y.rounded()) * .pi / 180) }
    return (Gray(width: W, height: H, pixels: out), map)
  }

  /// A curled page straightened: the tilt measured per band and per strip across the width, each strip's tilts
  /// taken as the median of three bands, and every pixel moved by the slope summed from the page's middle out to
  /// its column (between strip middles the slope changes linearly). `nil` when too little of the page has ink, or
  /// the tilt hardly changes across it (a flat scan).
  static func curled(_ g: Gray, threshold thr: Int) -> (page: Gray, map: StraightenMap)? {
    let W = g.width, H = g.height
    let band = max(100, H / 11), step = band / 2
    let n = max(1, curlStrips)
    let left = 0.05 * Double(W), width = 0.9 * Double(W) / Double(n)
    let mids = (0..<n).map { left + (Double($0) + 0.5) * width }
    let limit = Int((curlMaxDegrees * 10).rounded())
    var centers: [Double] = [], rows: [[Double]] = []
    var y0 = 0
    while y0 < H {
      let y1 = min(H, y0 + band)
      var tilts = [Double?](repeating: nil, count: n)
      for s in 0..<n {
        let a = Int(left + Double(s) * width), b = Int(left + Double(s + 1) * width)
        var ys: [Int32] = [], xs: [Int32] = []
        for y in y0..<y1 {
          let o = y * W
          var x = a
          while x < b {
            if Int(g.pixels[o + x]) < thr { ys.append(Int32(y - y0)); xs.append(Int32(x)) }
            x += 2
          }
        }
        if ys.count >= 1000 / n { tilts[s] = bandTilt(ys, xs, rows: y1 - y0, cx: mids[s], limit: limit) }
      }
      if tilts.contains(where: { $0 != nil }) {
        // a strip without ink takes the tilt of the nearest strip that has some
        let filled = (0..<n).map { s -> Double in
          if let t = tilts[s] { return t }
          let k = (0..<n).filter { tilts[$0] != nil }.min { abs($0 - s) < abs($1 - s) }!
          return tilts[k]!
        }
        centers.append(Double(y0 + y1) / 2)
        rows.append(filled)
      }
      if y1 == H { break }
      y0 += step
    }
    guard !rows.isEmpty else { return nil }
    let perStrip = (0..<n).map { s in medianOfThree(rows.map { $0[s] }) }
    // a flat scan that sits crooked tilts alike all over (a fanned copy changes by a degree or two down the page);
    // it reads as it is, and resampling it costs detections (a whole-bar rest lost on a Real Book page). Only a
    // page whose tilt changes by several degrees across it is a curled photo.
    let all = perStrip.flatMap { $0 }
    guard let lo = all.min(), let hi = all.max(), hi - lo >= curlMinSpread else { return nil }
    func slopes(at y: Double) -> [Double] {
      (0..<n).map { s -> Double in
        let a = perStrip[s]
        if y <= centers[0] { return tan(a[0] * .pi / 180) }
        if y >= centers[centers.count - 1] { return tan(a[a.count - 1] * .pi / 180) }
        var i = 0
        while centers[i + 1] < y { i += 1 }
        let f = (y - centers[i]) / (centers[i + 1] - centers[i])
        return tan((a[i] * (1 - f) + a[i + 1] * f) * .pi / 180)
      }
    }
    let cx = W / 2
    // each column's shift in one row: the slope summed from the middle out
    func fillShift(row y: Double, into shift: inout [Double]) {
      let t = slopes(at: y)
      func slope(_ x: Double) -> Double {
        if x <= mids[0] { return t[0] }
        if x >= mids[n - 1] { return t[n - 1] }
        let k = min(n - 2, Int((x - mids[0]) / width))
        let f = (x - mids[k]) / width
        return t[k] * (1 - f) + t[k + 1] * f
      }
      shift[cx] = 0
      for x in stride(from: cx + 1, to: W, by: 1) { shift[x] = shift[x - 1] + slope(Double(x) - 0.5) }
      for x in stride(from: cx - 1, through: 0, by: -1) { shift[x] = shift[x + 1] - slope(Double(x) + 0.5) }
    }
    var out = [UInt8](repeating: 255, count: W * H)
    var shift = [Double](repeating: 0, count: W)
    g.pixels.withUnsafeBufferPointer { src in
      out.withUnsafeMutableBufferPointer { dst in
        for y in 0..<H {
          fillShift(row: Double(y), into: &shift)
          let o = y * W
          for x in 0..<W {
            let sy = Double(y) + shift[x]
            if sy < 0 || sy > Double(H - 1) { continue }
            let a = Int(sy), f = sy - Double(a), b = min(H - 1, a + 1)
            let v = Double(src[a * W + x]) * (1 - f) + Double(src[b * W + x]) * f
            dst[o + x] = UInt8(max(0, min(255, v.rounded())))
          }
        }
      }
    }
    let map = StraightenMap { x, y in
      var row = [Double](repeating: 0, count: W)
      fillShift(row: max(0, min(Double(H - 1), y.rounded())), into: &row)
      return row[max(0, min(W - 1, Int(x.rounded())))]
    }
    return (Gray(width: W, height: H, pixels: out), map)
  }

  /// The distance from one staff line to the next, in pixels: the commonest dark run down the page's columns (a line's
  /// thickness) plus the commonest light run (the space between lines). A tilt does not change either.
  static func staffLineDistance(_ g: Gray, threshold thr: Int) -> Double {
    let W = g.width, H = g.height
    var dark = [Int](repeating: 0, count: H + 1), light = [Int](repeating: 0, count: H + 1)
    var x = Int(0.15 * Double(W))
    while x < Int(0.9 * Double(W)) {
      var run = 0, ink = Int(g.pixels[x]) < thr, seenInk = false
      for y in 0..<H {
        let now = Int(g.pixels[y * W + x]) < thr
        if now == ink { run += 1; continue }
        if ink { dark[run] += 1; seenInk = true } else if seenInk && run > 1 { light[run] += 1 }
        ink = now; run = 1
      }
      x += 8
    }
    let line = dark.indices.max { dark[$0] < dark[$1] } ?? 0, space = light.indices.max { light[$0] < light[$1] } ?? 0
    return Double(max(4, line + space))
  }
}
