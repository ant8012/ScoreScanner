import Foundation
import Testing

@testable import ScannerCore

/// The staff-grouping rules for photographed and scanned pages: a page edge in the margin, and a staff
/// traced in two where the page curls.
struct CopistaLayoutTests {
  private typealias Front = Copista.Front

  private func staff(_ y0: Double, _ x0: Double = 100, sp: Double = 10) -> Copista.Staff {
    Copista.Staff(bars: [], sp: sp, y0: y0, y1: y0 + 4 * sp, x0: x0, x1: 900)
  }

  private func mask(width: Int = 1000, height: Int = 1000, ink: [(x: Int, y0: Int, y1: Int)]) -> Copista.Mask {
    var bits = [Bool](repeating: false, count: width * height)
    for line in ink { for y in line.y0...line.y1 { bits[y * width + line.x] = true } }
    return Copista.Mask(width: width, height: height, bits: bits)
  }

  @Test func aMarginLineRunningPastTheStavesIsAPageEdge() {
    let staves = [staff(200), staff(300), staff(500), staff(600)]
    // a slanted stroke from the top of the page down past the last staff, left of every staff
    let slanted = (0..<800).map { (x: 40 - $0 / 40, y0: $0, y1: $0) }
    let rules = Front.edgeRules(mask(ink: slanted), staves)
    #expect(rules.count == 1)
    #expect(rules[0].covers([20, 300, 45, 600]))
    #expect(!rules[0].covers([60, 300, 70, 600]))
  }

  @Test func aBracketThatStaysWithItsStavesIsKept() {
    let staves = [staff(200), staff(300), staff(500), staff(600)]
    // a system's opening line: from the top of its first staff to the bottom of its last
    #expect(Front.edgeRules(mask(ink: [(x: 90, y0: 198, y1: 342)]), staves).isEmpty)
    // and a short mark in the margin is not a line at all
    #expect(Front.edgeRules(mask(ink: [(x: 20, y0: 10, y1: 60)]), staves).isEmpty)
  }

  @Test func aStaffTracedInTwoIsJoined() {
    // the bent half sits just below the straight half; the next staff is a normal distance away
    let staves = [staff(200), staff(238), staff(330)]
    let joined = Front.joinSplit(staves, [])
    #expect(joined.count == 2)
    #expect(joined[0].y0 == 200 && joined[0].y1 == 278)
    #expect(joined[1].y0 == 330)
  }

  @Test func closeButSeparateStavesStayApart() {
    let staves = [staff(200), staff(255)]          // 1.5 staff spaces apart
    #expect(Front.joinSplit(staves, []).count == 2)
  }
}
