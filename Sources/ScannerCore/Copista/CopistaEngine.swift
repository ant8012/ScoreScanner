import CoreGraphics
import Foundation
import ImageIO

// The copisteria reader end to end (pipeline.transcribe): page -> detections -> layout -> readings -> MusicXML.
// copista-2m: the 1.94M-parameter detector and the 2.03M-parameter evidence model, both as ONNX.

extension Copista {
  /// What a page read gives back: the MusicXML and how the page was laid out.
  struct Page {
    let xml: String
    let reading: Reading
    let detections: [Det]
    let imgsz: Int
  }

  /// Files the reader needs beside the other models.
  static let modelFiles = ["copista_detector_a.onnx", "copista_detector_b.onnx", "copista_evidence.onnx", "copista-meta.json"]

  static func available(in models: URL) -> Bool {
    modelFiles.allSatisfy { FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }
  }

  /// An image file's grey levels at its own size (Pillow's convert("L") for grey and RGB images).
  static func decodeGray(_ data: Data) throws -> Gray {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
      throw ScannerError.invalid("The image could not be decoded")
    }
    // a camera photo's EXIF orientation: drawn upright first (the page is read as it is seen)
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    if let o = props?[kCGImagePropertyOrientation] as? Int, o != 1,
       let upright = CGImageSourceCreateThumbnailAtIndex(src, 0, [
         kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height)] as CFDictionary) {
      image = upright
    }
    let w = image.width, h = image.height
    guard w * h <= 80_000_000 else { throw ScannerError.invalid("Image exceeds 80 megapixels") }
    if image.bitsPerPixel == 8, image.colorSpace?.model == .monochrome, let bytes = image.dataProvider?.data as Data? {
      var px = [UInt8](repeating: 0, count: w * h)
      bytes.withUnsafeBytes { b in
        for y in 0..<h { for x in 0..<w { px[y * w + x] = b[y * image.bytesPerRow + x] } }
      }
      return Gray(width: w, height: h, pixels: px)
    }
    // RGB: L = (19595 R + 38470 G + 7471 B + 0x8000) >> 16, over a white page for transparency
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw ScannerError.invalid("The image could not be drawn")
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var px = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
      let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
      px[i] = UInt8((19595 * r + 38470 * g + 7471 * b + 0x8000) >> 16)
    }
    return Gray(width: w, height: h, pixels: px)
  }

  /// Loaded once, reads many pages. Confined to the caller's task (ONNX sessions are not shared).
  final class Engine {
    let meta: Meta
    let detector: Detector
    let evidence: Evidence
    let classId: [String: Int]

    init(models: URL) throws {
      meta = try Meta.load(models)
      detector = try Detector(models: models, meta: meta)
      evidence = try Evidence(models: models, meta: meta)
      classId = Dictionary(uniqueKeysWithValues: meta.classes.enumerated().map { ($1, $0) })
    }

    func read(_ page: Gray, title: String = "", carriedMeter: String? = nil, progress: (String) -> Void = { _ in }) throws -> Page {
      progress("Finding staff lines")
      let ink = findStaves(page).spacing
      try Task.checkCancellation()
      progress("Finding notation on the page")
      let (dets, imgsz) = try detector.detections(page, inkSpacing: ink)
      try Task.checkCancellation()
      progress("Laying out staves, systems and bars")
      var layout = Front.build(dets, width: Double(page.width), height: Double(page.height), page: page, meta: meta,
                               classId: classId)
      progress("Reading the music in context")
      var rd = Reading(layout: layout, tok: try evidence.read(layout), classes: meta.classes)
      try Task.checkCancellation()
      // bar lines the first reading shows were missed: read again with them
      let mask = inkMask(page.pixels.map(Float.init), width: page.width, height: page.height, integral: true)
      let cuts = missedBarLines(rd, mask: mask)
      if !cuts.isEmpty {
        progress("Reading again with the bar lines found")
        layout = Front.build(dets, width: Double(page.width), height: Double(page.height), page: page, meta: meta,
                             classId: classId, cuts: cuts)
        rd = Reading(layout: layout, tok: try evidence.read(layout), classes: meta.classes)
        rd.revised = cuts
      }
      rd.slashBars = Slashes.bars(page, rd)
      progress("Writing the score")
      return Page(xml: Tidy.apply(Writer.write(rd, title: title, carriedMeter: carriedMeter)), reading: rd, detections: dets,
                  imgsz: imgsz)
    }
  }
}
