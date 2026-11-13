import Foundation

/// The strip of page a chord symbol occupies, and where the bars fall in it.
///
/// Bar lines are never inferred here. The staff detector already found them
/// while tracing the staff, and a second, independent set would disagree with
/// the score the decoder writes.
struct StaffGeometry: Decodable {
  struct Barline: Decodable { let x: Double }
  let unit: Double
  let minx: Double, miny: Double, maxx: Double, maxy: Double
  let barlines: [Barline]
  let voice: Int?
  let system: Int?

  static func decode(_ data: Data) throws -> StaffGeometry {
    try JSONDecoder().decode(StaffGeometry.self, from: data)
  }

  /// No printed bar is narrower than this many staff spaces, while the thick
  /// and thin strokes of a repeat bracket can sit just over one space apart.
  static let narrowestBar = 2.0

  /// Bar-line positions, with near-duplicates merged. A thick-thin ending or a
  /// repeat is detected as several lines a hair apart but is one boundary.
  var barPositions: [Double] {
    let sorted = barlines.map(\.x).sorted()
    var groups: [[Double]] = []
    for x in sorted {
      if let last = groups.last?.last, x - last < Self.narrowestBar * unit {
        groups[groups.count - 1].append(x)
      } else {
        groups.append([x])
      }
    }
    return groups.map { $0.reduce(0, +) / Double($0.count) }
  }

  /// Staff edges plus the native bar lines between them. A line closer to an
  /// edge than the narrowest bar, such as the thin stroke of an end repeat
  /// just inside its bracket, would only cut an empty sliver.
  var musicalBoundaries: [Double] {
    let margin = Self.narrowestBar * unit
    return [minx] + barPositions.filter { minx + margin < $0 && $0 < maxx - margin } + [maxx]
  }

  /// Vertical extent of the chord strip: above the staff, clear of its top line.
  func band(pageHeight: Int) -> (top: Int, bottom: Int) {
    (max(0, Int(miny - 6 * unit)), Int(miny - 0.5 * unit))
  }

  func bandColumns(pageWidth: Int) -> (left: Int, right: Int) {
    (max(0, Int(minx - unit)), min(pageWidth, Int(maxx + unit)))
  }
}

/// A rectangle of grayscale page, addressed in page coordinates.
struct Band {
  let pixels: [UInt8]
  let width: Int, height: Int

  struct Rectangle: Equatable, Sendable {
    let x: Int, y: Int, width: Int, height: Int
  }

  init(page: Data, pageWidth: Int, top: Int, bottom: Int, left: Int, right: Int) {
    width = max(0, right - left)
    height = max(0, bottom - top)
    var copied = [UInt8](repeating: 255, count: max(0, width * height))
    if width > 0 && height > 0 {
      let rowWidth = width, rowCount = height
      page.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
        for row in 0..<rowCount {
          let start = (top + row) * pageWidth + left
          for column in 0..<rowWidth { copied[row * rowWidth + column] = source[start + column] }
        }
      }
    }
    self.pixels = copied
  }

  init(pixels: [UInt8], width: Int, height: Int) {
    self.width = width
    self.height = height
    self.pixels = pixels
  }

  /// Small rectangular frames in the chord band, expressed in band coordinates.
  ///
  /// Rehearsal marks must be removed before OCR: the recognizer can otherwise
  /// merge a boxed A with a measure number and neighboring real chords. The
  /// dimensions mirror the held-out Python experiment. Edge coverage replaces
  /// OpenCV's contour rectangularity test in the native implementation.
  func rehearsalFrames(unit: Double) -> [Rectangle] {
    guard width > 0, height > 0 else { return [] }
    var visited = [Bool](repeating: false, count: pixels.count)
    var frames: [Rectangle] = []
    let neighbors = [
      (-1, -1), (0, -1), (1, -1),
      (-1, 0),            (1, 0),
      (-1, 1),  (0, 1),   (1, 1),
    ]

    for start in pixels.indices where pixels[start] < 160 && !visited[start] {
      visited[start] = true
      var queue = [start]
      var cursor = 0
      var minX = start % width, maxX = minX
      var minY = start / width, maxY = minY
      while cursor < queue.count {
        let offset = queue[cursor]
        cursor += 1
        let x = offset % width, y = offset / width
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
        for (dx, dy) in neighbors {
          let nx = x + dx, ny = y + dy
          guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
          let next = ny * width + nx
          guard !visited[next], pixels[next] < 160 else { continue }
          visited[next] = true
          queue.append(next)
        }
      }

      let box = Rectangle(
        x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
      // Connected components include the antialiased outer pixels (and can
      // include a touching character), while OpenCV's approximated contour
      // sat just inside them. The small upper tolerance preserves equivalent
      // physical limits across the two raster implementations.
      guard 2.2 * unit <= Double(box.width), Double(box.width) <= 5.2 * unit,
        2.25 * unit <= Double(box.height), Double(box.height) <= 4.75 * unit
      else { continue }
      let aspect = Double(box.width) / Double(box.height)
      guard 0.6...2.5 ~= aspect, hasRectangularEdges(box, unit: unit) else { continue }
      frames.append(box)
    }
    return frames.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
  }

  private func hasRectangularEdges(_ box: Rectangle, unit: Double) -> Bool {
    let thickness = max(2, Int((0.25 * unit).rounded()))
    func horizontalCoverage(top: Bool) -> Double {
      let y0 = top ? box.y : max(box.y, box.y + box.height - thickness)
      let y1 = top ? min(box.y + box.height, box.y + thickness) : box.y + box.height
      var covered = 0
      for x in box.x..<(box.x + box.width) {
        if (y0..<y1).contains(where: { pixels[$0 * width + x] < 160 }) { covered += 1 }
      }
      return Double(covered) / Double(box.width)
    }
    func verticalCoverage(left: Bool) -> Double {
      let x0 = left ? box.x : max(box.x, box.x + box.width - thickness)
      let x1 = left ? min(box.x + box.width, box.x + thickness) : box.x + box.width
      var covered = 0
      for y in box.y..<(box.y + box.height) {
        if (x0..<x1).contains(where: { pixels[y * width + $0] < 160 }) { covered += 1 }
      }
      return Double(covered) / Double(box.height)
    }
    return horizontalCoverage(top: true) >= 0.9
      && horizontalCoverage(top: false) >= 0.9
      && verticalCoverage(left: true) >= 0.9
      && verticalCoverage(left: false) >= 0.9
  }

  func erasing(_ rectangles: [Rectangle]) -> Band {
    guard !rectangles.isEmpty else { return self }
    var cleaned = pixels
    for box in rectangles {
      let x0 = max(0, box.x - 1), x1 = min(width, box.x + box.width + 1)
      let y0 = max(0, box.y - 1), y1 = min(height, box.y + box.height + 1)
      for y in y0..<y1 {
        for x in x0..<x1 { cleaned[y * width + x] = 255 }
      }
    }
    return Band(pixels: cleaned, width: width, height: height)
  }

  /// Ink per column: how many dark pixels the column holds.
  func inkProfile(from: Int = 0, to: Int? = nil) -> [Int] {
    let end = min(to ?? width, width)
    guard from < end else { return [] }
    var profile = [Int](repeating: 0, count: end - from)
    for row in 0..<height {
      let base = row * width
      for column in from..<end where pixels[base + column] < 160 { profile[column - from] += 1 }
    }
    return profile
  }

  /// Column runs separated by real whitespace -- one chord label per group.
  func inkGroups(unit: Double, from: Int = 0, to: Int? = nil) -> [(Int, Int)] {
    let end = min(to ?? width, width)
    let profile = inkProfile(from: from, to: end)
    guard profile.contains(where: { $0 > 0 }) else { return [(from, end)] }
    let gap = max(2, Int(1.2 * unit))
    var groups: [(Int, Int)] = []
    var start: Int? = nil
    var run = 0
    for (index, value) in profile.enumerated() {
      if value > 0 {
        if start == nil { start = index + from }
        run = 0
      } else if let began = start {
        run += 1
        if run >= gap {
          groups.append((began, index + from - run + 1))
          start = nil
        }
      }
    }
    if let began = start { groups.append((began, end)) }
    return groups.isEmpty ? [(from, end)] : groups
  }

  /// Move a cut to the nearest ink-free column so a label is never split.
  ///
  /// This widens the image window only. The musical boundary itself does not
  /// move, so which bar a chord belongs to is decided by the score, not the cut.
  func safeCut(at x: Double, unit: Double) -> Int {
    let low = max(0, Int(x - 2 * unit))
    let high = min(width, Int(x + 0.5 * unit))
    guard low < high else { return Int(x) }
    let profile = inkProfile(from: low, to: high)
    let free = profile.indices.filter { profile[$0] == 0 }
    if free.isEmpty {
      let least = profile.indices.min { profile[$0] < profile[$1] } ?? 0
      return low + least
    }
    let nearest = free.min { abs(Double($0 + low) - x) < abs(Double($1 + low) - x) } ?? free[0]
    return low + nearest
  }

  /// Letters of one chord name sit closer together than this many staff spaces.
  static let letterGap = 0.6

  /// Where two neighbouring bars' crops meet, the same column for both. A chord name printed across the bar
  /// line (set from its note head, it can start just before the line) goes whole to the bar holding most of
  /// it: cutting at the nearest blank column instead split `Cmaj7` into a `C` read at the end of one bar and
  /// a `Cmaj7` read again at the start of the next.
  func boundaryCut(at x: Double, unit: Double) -> Int {
    let column = Int(x)
    guard column > 0, column < width else { return max(0, min(width, column)) }
    let gap = max(1, Int(Self.letterGap * unit))
    let lowLimit = max(0, column - Int(Self.longestOverhang * unit))
    let highLimit = min(width, column + Int(Self.longestOverhang * unit))
    let profile = inkProfile(from: lowLimit, to: highLimit)
    func ink(_ c: Int) -> Bool { profile[c - lowLimit] > 0 }
    guard ink(column) else { return column }
    var start = column, blank = 0
    var c = column - 1
    while c >= lowLimit {
      if ink(c) { start = c; blank = 0 } else { blank += 1; if blank >= gap { break } }
      c -= 1
    }
    var end = column
    blank = 0; c = column + 1
    while c < highLimit {
      if ink(c) { end = c; blank = 0 } else { blank += 1; if blank >= gap { break } }
      c += 1
    }
    return column - start <= end - column ? start : end + 1
  }

  /// No run of chord text crosses a gap this many staff spaces wide.
  static let textGap = 2.0
  /// A label hanging past a system's final bar line is at most one chord
  /// name wide; further ink is page furniture such as a scanned page edge.
  static let longestOverhang = 8.0

  /// Where a system's last bar ends. Nothing follows its final bar line but
  /// margin, so ink that continues past it, such as `Am7` set wider than
  /// the bar or the `)` closing a turnaround, can only belong to that bar.
  /// The crop follows that ink out to the first gap between words. Ink that
  /// never reaches a gap is a dark page edge, and the cut stays put.
  func systemEndCut(from x: Int, unit: Double) -> Int {
    let gap = max(1, Int(Self.textGap * unit))
    let limit = min(width, x + Int(Self.longestOverhang * unit))
    var end = x, blank = 0
    for (offset, ink) in inkProfile(from: x, to: limit).enumerated() {
      if ink > 0 {
        end = x + offset + 1
        blank = 0
      } else {
        blank += 1
        if blank >= gap { return end }
      }
    }
    return end == limit ? x : end
  }

  /// A sub-rectangle, for reading one bar or one label on its own.
  func subBand(from: Int, to: Int) -> Band {
    let start = max(0, min(from, width)), end = max(start, min(to, width))
    let cropWidth = end - start
    var output = [UInt8](repeating: 255, count: cropWidth * height)
    for row in 0..<height {
      for column in 0..<cropWidth {
        output[row * cropWidth + column] = pixels[row * width + start + column]
      }
    }
    return Band(pixels: output, width: cropWidth, height: height)
  }

  func crop(from: Int, to: Int) -> (pixels: Data, width: Int, height: Int) {
    let band = subBand(from: from, to: to)
    return (Data(band.pixels), band.width, band.height)
  }
}
