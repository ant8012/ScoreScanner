import Foundation

/// The exact measure-width image window used as input to the existing chord
/// recognizer, with enough location metadata to restore page reading order.
public struct ChordImageCrop: Sendable {
  public let staff: Int
  public let voice: Int?
  public let system: Int?
  public let bar: Int
  public let pixels: Data
  public let width: Int
  public let height: Int
  public let pageX: Int
  public let pageTop: Int
  public let pageBottom: Int
  public let barLeft: Double
  public let barRight: Double
}

/// Chords returned by an alternate recognizer for one exact scanner crop.
public struct ChordCropRecognition: Sendable {
  public let crop: ChordImageCrop
  public let chords: [String]

  public init(crop: ChordImageCrop, chords: [String]) {
    self.crop = crop
    self.chords = chords
  }
}

public enum ChordImageCrops {
  /// The chord strip above every staff, cut bar by bar.
  /// Rehearsal frames are erased before cropping, exactly as in `ChordPass`.
  public static func from(_ scan: ScanResult) throws -> [ChordImageCrop] {
    try from(
      page: scan.page, pageWidth: scan.pageWidth, pageHeight: scan.pageHeight,
      geometry: scan.staffs.map(\.geometry))
  }

  static func from(
    page: Data, pageWidth: Int, pageHeight: Int, geometry: [Data]
  ) throws -> [ChordImageCrop] {
    var crops: [ChordImageCrop] = []
    for (staffIndex, data) in geometry.enumerated() {
      let g = try StaffGeometry.decode(data)
      let (top, bottom) = g.band(pageHeight: pageHeight)
      let (left, right) = g.bandColumns(pageWidth: pageWidth)
      guard bottom > top, right > left else { continue }
      // The strip runs on to the page edge so a system's last bar can take
      // in a label that hangs past its final bar line.
      let rawBand = Band(
        page: page, pageWidth: pageWidth, top: top, bottom: bottom, left: left, right: pageWidth)
      let pageStrip = Band(
        page: page, pageWidth: pageWidth, top: top, bottom: bottom, left: 0, right: pageWidth)
      let rehearsalFrames = pageStrip.rehearsalFrames(unit: g.unit).filter {
        $0.x + $0.width > left
      }.map {
        Band.Rectangle(x: $0.x - left, y: $0.y, width: $0.width, height: $0.height)
      }
      let band = rawBand.erasing(rehearsalFrames)
      let boundaries = g.musicalBoundaries
      // Bars that meet share one cut, so a chord name across the bar line is read once, in one bar.
      let shared = boundaries.indices.map { i -> Int? in
        i > 0 && i < boundaries.count - 1
          ? band.boundaryCut(at: boundaries[i] - Double(left), unit: g.unit) : nil
      }
      for bar in 0..<max(0, boundaries.count - 1) {
        try Task.checkCancellation()
        let a = Int(boundaries[bar]) - left
        let b = Int(boundaries[bar + 1]) - left
        let cutA = shared[bar] ?? max(0, min(a, band.safeCut(at: Double(a), unit: g.unit)))
        var cutB = shared[bar + 1] ?? min(band.width, max(b, band.safeCut(at: Double(b), unit: g.unit)))
        if bar == boundaries.count - 2 { cutB = band.systemEndCut(from: cutB, unit: g.unit) }
        guard cutB > cutA else { continue }
        let crop = band.crop(from: cutA, to: cutB)
        crops.append(
          ChordImageCrop(
            staff: staffIndex, voice: g.voice, system: g.system, bar: bar,
            pixels: crop.pixels, width: crop.width, height: crop.height,
            pageX: left + cutA, pageTop: top, pageBottom: bottom,
            barLeft: boundaries[bar], barRight: boundaries[bar + 1]))
      }
    }
    return crops
  }

  /// A page with the chords read from its crops written into its measures, placed by the page's system breaks
  /// and measure starts.
  public static func inserting(
    _ recognitions: [ChordCropRecognition], into scan: ScanResult, additionalSeconds: Double = 0,
    keepPage: Bool = true
  ) throws -> ScanResult {
    var chordStaffs = staffs(from: recognitions)
    try ChordMusicXML.map(
      &chordStaffs, score: scan.xml, fallbackMeter: ChordMeter(beats: 4, beatType: 4), fitUnmatched: true)
    let xml = try ChordMusicXML.insertMapped(scan.xml, staffs: chordStaffs).xml
    return ScanResult(
      xml: xml, rawXML: xml, staffs: scan.staffs, page: keepPage ? scan.page : Data(),
      pageWidth: scan.pageWidth, pageHeight: scan.pageHeight, seconds: scan.seconds + additionalSeconds,
      repairedMeasures: 0)
  }

  static func staffs(from recognitions: [ChordCropRecognition]) -> [ChordStaff] {
    var byStaff: [Int: [ChordCropRecognition]] = [:]
    for recognition in recognitions { byStaff[recognition.crop.staff, default: []].append(recognition) }

    var chordStaffs: [ChordStaff] = []
    for staffIndex in byStaff.keys.sorted() {
      guard let items = byStaff[staffIndex]?.sorted(by: { $0.crop.bar < $1.crop.bar }),
        let first = items.first
      else { continue }
      var bars: [ChordBar] = []
      for item in items {
        let crop = item.crop
        let count = item.chords.count
        let span = max(1, crop.barRight - crop.barLeft)
        let labels = item.chords.enumerated().map { index, chord in
          let centre = crop.barLeft + (Double(index) + 0.5) * span / Double(max(1, count))
          return ChordLabel(
            text: chord, chord: chord, confidence: 1, x0: centre - 0.5, x1: centre + 0.5,
            bar: crop.bar, measureNumber: nil, partID: nil, beat: nil, beatUnit: nil,
            timingSource: nil, timingStatus: nil)
        }
        bars.append(
          ChordBar(
            index: crop.bar, left: crop.barLeft, right: crop.barRight,
            text: item.chords.joined(separator: " "), labels: labels,
            measureNumber: nil, partID: nil))
      }
      chordStaffs.append(
        ChordStaff(
          staff: staffIndex, voice: first.crop.voice, system: first.crop.system,
          top: first.crop.pageTop, bottom: first.crop.pageBottom, bars: bars,
          mappingStatus: "unresolved"))
    }

    return chordStaffs
  }
}
