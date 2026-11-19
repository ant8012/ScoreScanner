import Foundation

extension Copista {
  static let straightenMinDegrees = 0.1, straightenMaxDegrees = 1.0
  /// Past a degree a page is not tilted but curled (a phone photo of a book): its lines bend along their length,
  /// which shifting whole rows cannot undo, so it is left as it is.
  ///
  /// The least a staff line must drift across the staves (in staff spaces) for the page to be straightened.
  static let straightenMinShiftSp = 1.0

  /// A scanned or photocopied page sits a little crooked, and a copy of a bound book often fans: the top of the page
  /// tilts more than the bottom. On a dense score the staff lines are only nine or ten pixels apart, so a tilt of half
  /// a degree moves a line two staff spaces across the page and the staff finder, which sums whole rows, loses the
  /// staff. The page is measured in overlapping bands down its height, the tilt that lines up each band's ink best,
  /// and every row is shifted back by its own tilt. A page whose staff lines drift less than a staff space across
  /// the staves is returned untouched: the staff finder reads it as it is, and resampling it would only change what
  /// the reader sees (a blank printed staff under a handwritten title turns up once straightened).
  static func straightened(_ g: Gray) -> Gray {
    let W = g.width, H = g.height
    guard W >= 200, H >= 200 else { return g }
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
        let rows = y1 - y0
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
        for k in -15...15 {
          let a = Double(k) * 0.1, v = score(a)
          if v > bv { bv = v; best = a }
        }
        let coarse = best
        for k in -5...5 {
          let a = coarse + Double(k) * 0.02, v = score(a)
          if v > bv { bv = v; best = a }
        }
        centers.append(Double(y0 + y1) / 2)
        angles.append(best)
      }
      if y1 == H { break }
      y0 += step
    }
    guard !angles.isEmpty else { return g }
    // a band of words or a picture can pick a stray angle: take the median of each band and its two nearest
    // (at the top and bottom of the page, the next two in), so a title band alone cannot tilt the page
    let smooth = angles.indices.map { i -> Double in
      let lo = max(0, min(i - 1, angles.count - 3))
      let w = angles[lo...min(angles.count - 1, lo + 2)].sorted()
      return w[w.count / 2]
    }
    let steepest = smooth.map(abs).max() ?? 0
    let drift = 0.8 * Double(W) * tan(steepest * .pi / 180) / staffLineDistance(g, threshold: thr)
    guard steepest >= straightenMinDegrees, steepest <= straightenMaxDegrees, drift >= straightenMinShiftSp else { return g }
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
    return Gray(width: W, height: H, pixels: out)
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
