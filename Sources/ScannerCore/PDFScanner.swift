import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct DocumentScanResult: Sendable {
  public let xml: Data
  public let rawXML: Data
  public let seconds: Double
  public let staffCount: Int
  public let repairedMeasures: Int
  public let pageCount: Int
  public init(_ scan: ScanResult) {
    xml = scan.xml; rawXML = scan.rawXML; seconds = scan.seconds
    staffCount = scan.staffs.count; repairedMeasures = scan.repairedMeasures; pageCount = 1
  }
  public init(xml: Data, rawXML: Data, seconds: Double, staffCount: Int, repairedMeasures: Int, pageCount: Int) {
    self.xml = xml; self.rawXML = rawXML; self.seconds = seconds
    self.staffCount = staffCount; self.repairedMeasures = repairedMeasures; self.pageCount = pageCount
  }
}

public enum PDFScanner {
  public static func pageCount(data: Data) throws -> Int {
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider), !document.isEncrypted || document.isUnlocked,
      document.numberOfPages > 0
    else { throw ScannerError.invalid("Could not open PDF. Use an unlocked PDF containing sheet music.") }
    return document.numberOfPages
  }

  /// The width pages are rendered at: about 300 dpi for A4 and letter, the detail of a print scan.
  public static let renderWidth = 2480

  /// Renders one zero-based page with the same Core Graphics path used by PDF import.
  public static func renderPage(data: Data, pageIndex: Int, width: Int = renderWidth) throws -> Data {
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider), !document.isEncrypted || document.isUnlocked
    else { throw ScannerError.invalid("Could not open PDF. Use an unlocked PDF containing sheet music.") }
    guard pageIndex >= 0, pageIndex < document.numberOfPages,
      let page = document.page(at: pageIndex + 1)
    else { throw ScannerError.invalid("PDF page index \(pageIndex) is out of range") }
    return try render(page, width: width)
  }

  /// Pages read one by one, joined into one score: each part's measures page after page.
  public static func combine(pages: [ScanResult], title: String = "", seconds: Double) throws -> DocumentScanResult {
    let xml = try CopistaMerge.combine(pages.map(\.xml), title: title)
    return DocumentScanResult(xml: xml, rawXML: xml, seconds: seconds,
                              staffCount: pages.reduce(0) { $0 + $1.staffs.count }, repairedMeasures: 0,
                              pageCount: pages.count)
  }

  /// Every page of a PDF read and joined, carrying the meter from page to page.
  public static func scan(data: Data, models: URL = Scanner.bundledModels, title: String = "",
                          progress: @Sendable (String) -> Void = { _ in }) throws -> DocumentScanResult {
    let start = Date()
    guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
      !document.isEncrypted || document.isUnlocked, document.numberOfPages > 0
    else { throw ScannerError.invalid("Could not open PDF. Use an unlocked PDF containing sheet music.") }
    let pageCount = document.numberOfPages
    var pages: [ScanResult] = []
    for number in 1...pageCount {
      try Task.checkCancellation()
      do {
        try autoreleasepool {
          guard let page = document.page(at: number) else { throw ScannerError.invalid("Missing PDF page") }
          let carried = pages.last.flatMap { Scanner.lastMeter(of: $0.xml) }
          let scan = try Scanner.scan(image: render(page, width: renderWidth), models: models, carriedMeter: carried) {
            progress("Page \(number) of \(pageCount): \($0)")
          }
          // the page's pixels are not kept once it is read
          pages.append(ScanResult(xml: scan.xml, rawXML: scan.rawXML, staffs: scan.staffs, page: Data(),
                                  pageWidth: 0, pageHeight: 0, seconds: scan.seconds, repairedMeasures: 0,
                                  chordWords: scan.chordWords))
        }
      } catch is CancellationError { throw CancellationError() }
      catch { throw ScannerError.invalid("Page \(number): \(error.localizedDescription)") }
    }
    progress("Combining \(pageCount) pages")
    return try combine(pages: pages, title: title, seconds: Date().timeIntervalSince(start))
  }

  static func render(_ page: CGPDFPage, width: Int = renderWidth) throws -> Data {
    let box = page.getBoxRect(.cropBox)
    let rotated = abs(page.rotationAngle) % 180 == 90
    let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw ScannerError.invalid("Invalid PDF page dimensions")
    }
    let height = (CGFloat(width) * size.height / size.width).rounded()
    guard height >= 1, height <= 16000 else { throw ScannerError.invalid("Unsupported PDF page proportions") }
    guard let context = CGContext(data: nil, width: width, height: Int(height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw ScannerError.invalid("Could not allocate PDF page image") }
    let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
    // getDrawingTransform only ever shrinks a page to fit; it will not enlarge
    // one. A letter page is 612pt wide, so on its own it would draw at 1:1
    // points -- 72 DPI in the middle of a 1920px canvas, a quarter of the size
    // the scanner needs. Scale the context first and map the page into its own
    // point-sized rect, which that transform handles exactly.
    let scale = rect.width / size.width
    context.scaleBy(x: scale, y: scale)
    context.concatenate(
      page.getDrawingTransform(
        .cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    let output = NSMutableData()
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else { throw ScannerError.invalid("Could not render PDF page") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ScannerError.invalid("Could not encode PDF page") }
    return output as Data
  }
}
