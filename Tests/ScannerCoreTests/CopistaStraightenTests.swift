import Foundation
import Testing

@testable import ScannerCore

/// A phone photo of a book page curls toward the spine and fans down the page; a flat scan only sits crooked.
/// The first is straightened strip by strip, the second is left as it is.
struct CopistaStraightenTests {
  /// Six staves of five lines, 12 px apart; each line moved down by `offset(x, y)` at column x.
  func page(_ offset: (Double, Double) -> Double) -> Copista.Gray {
    let W = 1600, H = 2000
    var px = [UInt8](repeating: 235, count: W * H)
    for s in 0..<6 {
      for l in 0..<5 {
        let base = 200.0 + 280 * Double(s) + 12 * Double(l)
        for x in 100..<1500 {
          let y = Int((base + offset(Double(x), base)).rounded())
          // a dark core and a grey edge, as a scan draws it (a page of pure black and white has no threshold)
          if y >= 0 && y < H { px[y * W + x] = 10 }
          if y + 1 >= 0 && y + 1 < H { px[(y + 1) * W + x] = 90 }
        }
      }
    }
    return Copista.Gray(width: W, height: H, pixels: px)
  }

  /// Per column, the first ink row within 60 px of `y`: where a line crosses it.
  func lineRows(_ g: Copista.Gray, near y: Int) -> [Int] {
    stride(from: 200, through: 1400, by: 100).compactMap { x in
      ((y - 60)..<(y + 60)).first { g[$0, x] < 128 }
    }
  }

  @Test func aCurledPhotoComesOutFlat() {
    // a bend toward both edges (slopes up to 3.4 degrees) and a fan from +2 degrees at the top to -2 at the foot
    let curled = page { x, y in
      let dx = x - 800
      let fan = tan((2 - 4 * y / 2000) * .pi / 180)
      return 4.2e-5 * dx * dx + fan * dx
    }
    let before = lineRows(curled, near: 760)
    #expect(before.max()! - before.min()! >= 20)
    let after = lineRows(Copista.straightened(curled), near: 760)
    #expect(after.count == 13)
    #expect(after.max()! - after.min()! <= 4)
  }

  @Test func aFlatScanTiltedEvenlyIsLeftAlone() {
    // 1.5 degrees everywhere: past the plain straightener's limit, but the tilt does not change across the page
    let tilted = page { x, _ in tan(1.5 * .pi / 180) * (x - 800) }
    #expect(Copista.straightened(tilted).pixels == tilted.pixels)
  }
}
