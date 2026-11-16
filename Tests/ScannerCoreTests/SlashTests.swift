import Foundation
import Testing

@testable import ScannerCore

/// Rhythm slashes found in the page: the shape test that tells a slash from noteheads, rests and beams.
struct SlashTests {
  /// A white page with a five-line staff (staff space 20 px, top line at y 100) from x 50 to 950.
  private func page(_ draw: (inout [UInt8], Int) -> Void) -> (Copista.Gray, Copista.Staff) {
    let w = 1000, h = 300
    var px = [UInt8](repeating: 255, count: w * h)
    for k in 0..<5 { for x in 50..<950 { for t in 0..<2 { px[(100 + 20 * k + t) * w + x] = 0 } } }
    draw(&px, w)
    return (Copista.Gray(width: w, height: h, pixels: px), Copista.Staff(bars: [], sp: 20, y0: 100, y1: 180, x0: 50, x1: 950))
  }

  /// A straight stroke of the given thickness from (x0, y0) to (x1, y1).
  private func stroke(_ px: inout [UInt8], _ w: Int, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ t: Double) {
    let len = hypot(x1 - x0, y1 - y0)
    for y in Int(min(y0, y1) - t)...Int(max(y0, y1) + t) {
      for x in Int(min(x0, x1) - t)...Int(max(x0, x1) + t) {
        let u = ((Double(x) - x0) * (x1 - x0) + (Double(y) - y0) * (y1 - y0)) / (len * len)
        guard (0...1).contains(u) else { continue }
        let d = abs((Double(x) - x0) * (y1 - y0) - (Double(y) - y0) * (x1 - x0)) / len
        if d <= t / 2 { px[y * w + x] = 0 }
      }
    }
  }

  private func shapes(_ draw: (inout [UInt8], Int) -> Void) -> [Copista.Slashes.Blob] {
    let (g, st) = page(draw)
    return Copista.Slashes.blobs(g, st).filter { $0.height > 0.8 }
  }

  @Test func aSlashOnTheMiddleLinePasses() {
    // middle line at y 140: a stroke rising to the right, two spaces tall
    let found = shapes { px, w in stroke(&px, w, 200, 160, 230, 120, 8) }
    #expect(found.count == 1 && found[0].isSlash)
  }

  @Test func noteheadsRestsAndBeamsDoNot() {
    // a filled notehead on the middle line: a tilted oval
    let head = shapes { px, w in
      for y in 131...149 { for x in 190...216 {
        let dx = Double(x - 203) / 13, dy = Double(y - 140) / 9
        if dx * dx + dy * dy <= 1 { px[y * w + x] = 0 }
      } }
    }
    #expect(head.allSatisfy { !$0.isSlash })
    // a steep stroke like a quarter rest's
    let steep = shapes { px, w in stroke(&px, w, 300, 165, 309, 115, 9) }
    #expect(steep.allSatisfy { !$0.isSlash })
    // a slash leaning the wrong way
    let back = shapes { px, w in stroke(&px, w, 400, 120, 430, 160, 8) }
    #expect(back.allSatisfy { !$0.isSlash })
    // a flat, thick beam
    let beam = shapes { px, w in stroke(&px, w, 500, 150, 620, 140, 9) }
    #expect(beam.allSatisfy { !$0.isSlash })
    // a slash well above the middle line
    let high = shapes { px, w in stroke(&px, w, 700, 125, 730, 85, 8) }
    #expect(high.allSatisfy { !$0.isSlash })
  }
}
