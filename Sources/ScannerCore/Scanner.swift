import Foundation

/// One staff of a scanned page and where it sits: its part (`voice`, the MusicXML part index), its system, and its
/// geometry (staff box, staff space and measure starts, as JSON) for cropping the chord and text strips above it.
public struct ScannedStaff: Sendable {
  public let voice: Int, system: Int
  public let grandStaff: Bool
  public let geometry: Data
}

public struct ScanResult: Sendable {
  public let xml: Data
  public let rawXML: Data
  public let staffs: [ScannedStaff]
  /// The page as read, 8-bit grey, row by row.
  public let page: Data
  public let pageWidth: Int, pageHeight: Int
  public let seconds: Double
  public let repairedMeasures: Int
}

/// Reads a page with copisteria (copista-2m): its detector and evidence models as ONNX, and its front end,
/// reader and MusicXML writer ported to Swift (`Copista`).
public enum Scanner {
  /// The copisteria models that ship inside this package.
  public static var bundledModels: URL {
    Bundle.module.url(forResource: "Models", withExtension: nil)
      ?? Bundle.module.bundleURL.appendingPathComponent("Models")
  }

  /// Whether the bundle carries the copisteria models.
  public static func available(models: URL) -> Bool { Copista.available(in: models) }

  /// Fully local scan of one page image (any size; a camera photo's orientation is applied).
  /// `carriedMeter`: the meter the previous page of the same score ended in, from `lastMeter(of:)`, so a page
  /// that prints no time signature keeps it.
  public static func scan(
    image: Data, models: URL = bundledModels, title: String = "", carriedMeter: String? = nil,
    progress: @Sendable (String) -> Void = { _ in }
  ) throws -> ScanResult {
    guard available(models: models) else { throw ScannerError.invalid("The recognition models are missing") }
    let start = Date()
    progress("Loading recognition models")
    let engine = try Copista.Engine(models: models)
    progress("Preparing the original image")
    let page = try Copista.decodeGray(image)
    let read = try engine.read(page, title: title, carriedMeter: carriedMeter, progress: progress)
    guard read.xml.contains("<pitch>") else { throw ScannerError.invalid("No readable music was found") }
    let xml = Data(read.xml.utf8)
    // Where each staff and its measures sit, so the chord and text passes can crop the page and place what
    // they read.
    let staffs = Copista.Writer.placedStaves(read.reading).map { s -> ScannedStaff in
      let geometry: [String: Any] = [
        "unit": s.sp, "minx": s.x0, "miny": s.y0, "maxx": s.x1, "maxy": s.y1,
        "barlines": s.measureStarts.map { ["x": $0] }, "voice": s.part, "system": s.system,
      ]
      return ScannedStaff(
        voice: s.part, system: s.system, grandStaff: s.grandStaff,
        geometry: (try? JSONSerialization.data(withJSONObject: geometry)) ?? Data("{}".utf8))
    }
    return ScanResult(
      xml: xml, rawXML: xml, staffs: staffs, page: Data(page.pixels), pageWidth: page.width,
      pageHeight: page.height, seconds: Date().timeIntervalSince(start), repairedMeasures: 0)
  }

  /// The meter a page's score ends in, for `scan(carriedMeter:)` on the next page.
  public static func lastMeter(of xml: Data) -> String? { CopistaMerge.lastMeter(xml) }
}
