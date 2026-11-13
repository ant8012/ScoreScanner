import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import ScannerCore

struct PDFScannerTests {
  @Test func rendersPagesOnWhiteAtExpectedSize() throws {
    let bytes = NSMutableData()
    let consumer = CGDataConsumer(data: bytes)!
    var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
    let writer = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
    for _ in 0..<2 {
      writer.beginPDFPage(nil)
      writer.setFillColor(CGColor(gray: 0, alpha: 1))
      writer.fill(CGRect(x: 30, y: 40, width: 50, height: 60))
      writer.endPDFPage()
    }
    writer.closePDF()
    let doc = CGPDFDocument(CGDataProvider(data: bytes)!)!
    #expect(doc.numberOfPages == 2)
    for i in 1...2 {
      let png = try PDFScanner.render(doc.page(at: i)!)
      let source = CGImageSourceCreateWithData(png as CFData, nil)!
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
      #expect(image.width == PDFScanner.renderWidth)
      #expect(image.height == PDFScanner.renderWidth * 3 / 2)
    }
    let rendered = try PDFScanner.renderPage(data: bytes as Data, pageIndex: 1)
    #expect(CGImageSourceCreateWithData(rendered as CFData, nil) != nil)
    #expect(throws: (any Error).self) {
      try PDFScanner.renderPage(data: bytes as Data, pageIndex: 2)
    }
  }
  @Test func rejectsInvalidPDFBeforeModelLoading() {
    #expect(throws: (any Error).self) {
      try PDFScanner.scan(data: Data("not a PDF".utf8), models: URL(fileURLWithPath: "/missing"))
    }
  }
}
