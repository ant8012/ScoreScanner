import Foundation

public enum ScoreTextCropKind: String, Codable, Sendable {
  case header
  case initialMeter
  case system
}

/// A geometry-derived page region for reading score metadata or staff text.
public struct ScoreTextImageCrop: Sendable {
  public let kind: ScoreTextCropKind
  public let staff: Int?
  public let voice: Int?
  public let system: Int?
  public let pixels: Data
  public let width: Int
  public let height: Int
  public let pageX: Int
  public let pageY: Int
  /// Bar boundaries expressed from zero to one in crop coordinates.
  public let barBoundaryFractions: [Double]

  public var barCount: Int { max(0, barBoundaryFractions.count - 1) }
}

public enum ScoreTextImageCrops {
  /// Share of the page height, from the top, sent to the header reader.
  public static let headerFraction = 0.3

  /// The header is the top 30% of the page, even when that overlaps the first
  /// system, so tempo marks just above the first staff are included. System
  /// strips retain frames because rehearsal marks are meaningful here.
  public static func from(
    _ scan: ScanResult, includeHeader: Bool = true
  ) throws -> [ScoreTextImageCrop] {
    try from(
      page: scan.page, pageWidth: scan.pageWidth, pageHeight: scan.pageHeight,
      geometry: scan.staffs.map(\.geometry), includeHeader: includeHeader)
  }

  /// System strips for deciding whether a page prints chord names, with the
  /// rehearsal boxes blanked out. A boxed letter is shaped exactly like a
  /// chord, and a reader asked about chord names has answered A, B, C, D from
  /// the boxes alone. The chord pass erases the same frames before reading.
  public static func presenceStrips(_ scan: ScanResult) throws -> [ScoreTextImageCrop] {
    try from(
      page: scan.page, pageWidth: scan.pageWidth, pageHeight: scan.pageHeight,
      geometry: scan.staffs.map(\.geometry), includeHeader: false,
      eraseRehearsalFrames: true
    ).filter { $0.kind == .system }
  }

  static func from(
    page: Data, pageWidth: Int, pageHeight: Int, geometry: [Data],
    includeHeader: Bool = true, eraseRehearsalFrames: Bool = false
  ) throws -> [ScoreTextImageCrop] {
    let geometries = try geometry.map(StaffGeometry.decode)
    var output: [ScoreTextImageCrop] = []

    if includeHeader {
      let bottom = min(pageHeight, Int((Double(pageHeight) * headerFraction).rounded()))
      if bottom > 0 {
        let crop = Band(
          page: page, pageWidth: pageWidth, top: 0, bottom: bottom,
          left: 0, right: pageWidth)
        output.append(
          ScoreTextImageCrop(
            kind: .header, staff: nil, voice: nil, system: nil,
            pixels: Data(crop.pixels), width: crop.width, height: crop.height,
            pageX: 0, pageY: 0, barBoundaryFractions: []))
      }
      // Unlike the chord and staff-text bands, this window includes the
      // opening staff lines, clef, key, and left edge of bar 1. A time
      // signature cannot be read reliably from the strips above the staff.
      if let first = geometries.filter({ $0.system == 0 }).min(by: { $0.miny < $1.miny })
        ?? geometries.min(by: { $0.miny < $1.miny })
      {
        let left = max(0, Int(first.minx - 2 * first.unit))
        let right = min(pageWidth, Int(min(first.maxx, first.minx + 16 * first.unit)))
        let top = max(0, Int(first.miny - 2 * first.unit))
        let bottom = min(pageHeight, Int(first.maxy + 2 * first.unit))
        if right > left, bottom > top {
          let crop = Band(
            page: page, pageWidth: pageWidth, top: top, bottom: bottom,
            left: left, right: right)
          output.append(
            ScoreTextImageCrop(
              kind: .initialMeter, staff: nil, voice: first.voice, system: first.system,
              pixels: Data(crop.pixels), width: crop.width, height: crop.height,
              pageX: left, pageY: top, barBoundaryFractions: []))
        }
      }
    }

    for (staffIndex, geometry) in geometries.enumerated() {
      try Task.checkCancellation()
      let (top, bottom) = geometry.band(pageHeight: pageHeight)
      let (left, right) = geometry.bandColumns(pageWidth: pageWidth)
      guard bottom > top, right > left else { continue }
      let band = Band(
        page: page, pageWidth: pageWidth, top: top, bottom: bottom,
        left: left, right: right)
      // Detection uses the complete page-width strip, exactly as the chord
      // pass does: a frame may begin just left of the musical staff.
      let crop: Band
      if eraseRehearsalFrames {
        let pageStrip = Band(
          page: page, pageWidth: pageWidth, top: top, bottom: bottom, left: 0, right: pageWidth)
        crop = band.erasing(
          pageStrip.rehearsalFrames(unit: geometry.unit).filter {
            $0.x + $0.width > left && $0.x < right
          }.map {
            Band.Rectangle(x: $0.x - left, y: $0.y, width: $0.width, height: $0.height)
          })
      } else {
        crop = band
      }
      let width = Double(max(1, crop.width))
      let boundaries = geometry.musicalBoundaries.map {
        min(1, max(0, ($0 - Double(left)) / width))
      }
      output.append(
        ScoreTextImageCrop(
          kind: .system, staff: staffIndex, voice: geometry.voice, system: geometry.system,
          pixels: Data(crop.pixels), width: crop.width, height: crop.height,
          pageX: left, pageY: top, barBoundaryFractions: boundaries))
    }
    return output
  }
}
