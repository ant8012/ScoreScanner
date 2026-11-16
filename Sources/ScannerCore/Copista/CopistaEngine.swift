#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
import Foundation

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

  /// An image file's grey levels at its own size (Pillow's convert("L") for grey and RGB images). Binary PGM and PPM
  /// are read everywhere (Android's app decodes photos and draws PDF pages itself and sends them so); JPEG, PNG, HEIC
  /// and the rest with ImageIO where there is one.
  static func decodeGray(_ data: Data) throws -> Gray {
    if let page = try decodePNM(data) { return page }
    #if canImport(CoreGraphics)
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
      px[i] = luma(r, g, b)
    }
    return Gray(width: w, height: h, pixels: px)
    #else
    throw ScannerError.invalid("The image could not be decoded")
    #endif
  }

  /// Pillow's grey level for an RGB pixel.
  @inline(__always) static func luma(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
    UInt8((19595 * r + 38470 * g + 7471 * b + 0x8000) >> 16)
  }

  /// A binary PGM (P5, grey) or PPM (P6, RGB) image with 8-bit samples, or nil when `data` is neither.
  static func decodePNM(_ data: Data) throws -> Gray? {
    let bytes = [UInt8](data.prefix(64))
    guard bytes.count > 2, bytes[0] == UInt8(ascii: "P"), bytes[1] == UInt8(ascii: "5") || bytes[1] == UInt8(ascii: "6")
    else { return nil }
    let channels = bytes[1] == UInt8(ascii: "5") ? 1 : 3
    // the header: magic, width, height, maxval, separated by whitespace (and # comments), then one whitespace byte
    var fields: [Int] = [], i = data.startIndex + 2
    func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
    while fields.count < 3 {
      while i < data.endIndex, isSpace(data[i]) { i += 1 }
      if i < data.endIndex, data[i] == UInt8(ascii: "#") {
        while i < data.endIndex, data[i] != 10 { i += 1 }
        continue
      }
      var value = 0, digits = 0
      while i < data.endIndex, (48...57).contains(data[i]), digits < 9 {
        value = value * 10 + Int(data[i] - 48); i += 1; digits += 1
      }
      guard digits > 0 else { throw ScannerError.invalid("The image could not be decoded") }
      fields.append(value)
    }
    guard i < data.endIndex, isSpace(data[i]) else { throw ScannerError.invalid("The image could not be decoded") }
    i += 1
    let (w, h) = (fields[0], fields[1])
    guard fields[2] == 255, w > 0, h > 0 else { throw ScannerError.invalid("The image could not be decoded") }
    guard w * h <= 80_000_000 else { throw ScannerError.invalid("Image exceeds 80 megapixels") }
    guard data.endIndex - i >= w * h * channels else { throw ScannerError.invalid("The image is truncated") }
    if channels == 1 { return Gray(width: w, height: h, pixels: [UInt8](data[i..<(i + w * h)])) }
    var px = [UInt8](repeating: 0, count: w * h)
    data[i..<(i + w * h * 3)].withUnsafeBytes { b in
      for p in 0..<(w * h) { px[p] = luma(Int(b[p * 3]), Int(b[p * 3 + 1]), Int(b[p * 3 + 2])) }
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
