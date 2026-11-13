// Renders PDF pages exactly like PDFScanner.render (2480 px wide, white, RGB) to PNG.
// usage: render.swift PDF OUTDIR MAXPAGES
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let doc = CGPDFDocument(URL(fileURLWithPath: a[1]) as CFURL)!
let maxPages = Int(a[3])!
let name = URL(fileURLWithPath: a[1]).deletingPathExtension().lastPathComponent
for n in 1...min(doc.numberOfPages, maxPages) {
  let page = doc.page(at: n)!
  let box = page.getBoxRect(.cropBox)
  let rotated = abs(page.rotationAngle) % 180 == 90
  let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
  let width = 2480
  let height = (CGFloat(width) * size.height / size.width).rounded()
  let ctx = CGContext(data: nil, width: width, height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: height)
  ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
  let scale = rect.width / size.width
  ctx.scaleBy(x: scale, y: scale)
  ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
  ctx.drawPDFPage(page)
  let url = URL(fileURLWithPath: a[2]).appendingPathComponent(String(format: "%@_p%02d.png", name, n))
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}
