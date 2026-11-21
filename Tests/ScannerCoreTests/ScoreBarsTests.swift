import Foundation
import Testing

@testable import ScannerCore

/// Where each bar is printed: worked out per page from the layout, and joined page after page.
struct ScoreBarsTests {
  /// A one-part score whose measures start new systems at `breaks`.
  func score(measures: Int, breaks: Set<Int> = []) -> String {
    let body = (0..<measures).map { i in
      "<measure number=\"\(i + 1)\">" + (breaks.contains(i) ? "<print new-system=\"yes\"/>" : "")
        + "<note><rest measure=\"yes\"/><duration>4</duration></note></measure>"
    }.joined()
    return "<score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>A</part-name></score-part>"
      + "</part-list><part id=\"P1\">\(body)</part></score-partwise>"
  }

  func staff(system: Int, y0: Double, y1: Double, x0: Double = 100, x1: Double = 900, starts: [Double])
    -> Copista.Writer.PlacedStaff
  {
    Copista.Writer.PlacedStaff(part: 0, system: system, grandStaff: false, sp: 10, x0: x0, x1: x1, y0: y0, y1: y1,
                               measureStarts: starts)
  }

  @Test func systemsStartWhereTheScorePrintsNewSystems() {
    #expect(ScoreBars.systemStarts(score(measures: 7, breaks: [3, 5])) == [0, 3, 5, 7])
    #expect(ScoreBars.systemStarts(score(measures: 2)) == [0, 2])
  }

  @Test func eachBarSpansItsSystemsStaves() {
    // two systems: three bars over a grand staff, then two bars
    let staves = [
      staff(system: 0, y0: 100, y1: 140, starts: [300, 600]),
      staff(system: 0, y0: 180, y1: 220, starts: [300, 600]),
      staff(system: 1, y0: 400, y1: 440, starts: [500]),
    ]
    let bars = ScoreBars.read(staves, xml: score(measures: 5, breaks: [3]), width: 1000, height: 1000, map: .identity)
    #expect(bars.map(\.measure) == [0, 1, 2, 3, 4])
    #expect(bars.map(\.system) == [0, 0, 0, 1, 1])
    // the second bar: x 300-600, from the top staff's top line to the lower staff's bottom line
    #expect(bars[1].corners == [0.3, 0.1, 0.6, 0.1, 0.6, 0.22, 0.3, 0.22])
    #expect(bars[4].corners == [0.5, 0.4, 0.9, 0.4, 0.9, 0.44, 0.5, 0.44])
  }

  @Test func aStraightenedPageMapsItsCornersBack() {
    // the page was straightened by moving the right side up: the original is lower there
    let map = Copista.StraightenMap { x, _ in x / 100 }
    let bars = ScoreBars.read([staff(system: 0, y0: 100, y1: 200, starts: [])], xml: score(measures: 1),
                              width: 1000, height: 1000, map: map)
    #expect(bars.count == 1)
    #expect(bars[0].corners == [0.1, 0.101, 0.9, 0.109, 0.9, 0.209, 0.1, 0.201])
  }

  @Test func aLayoutThatDisagreesWithTheScorePlacesNoBars() {
    // the layout has three bars on the line, the score four
    let staves = [staff(system: 0, y0: 100, y1: 140, starts: [300, 600])]
    #expect(ScoreBars.read(staves, xml: score(measures: 4), width: 1000, height: 1000, map: .identity).isEmpty)
    // one system in the layout, two in the score
    #expect(ScoreBars.read(staves, xml: score(measures: 3, breaks: [2]), width: 1000, height: 1000,
                           map: .identity).isEmpty)
  }

  @Test func joinedPagesFollowOneAnother() {
    let bar = { (m: Int) in ScoreBar(measure: m, page: 0, system: 0, corners: [0, 0, 1, 0, 1, 1, 0, 1]) }
    let first = Data(score(measures: 3).utf8), second = Data(score(measures: 2).utf8)
    let joined = ScoreBars.joined([([bar(0), bar(1), bar(2)], first), ([bar(0), bar(1)], second)],
                                  into: Data(score(measures: 5).utf8))
    #expect(joined.map(\.measure) == [0, 1, 2, 3, 4])
    #expect(joined.map(\.page) == [0, 0, 0, 1, 1])
    // a joined score of another length: the bars are not trusted
    #expect(ScoreBars.joined([([bar(0)], first)], into: Data(score(measures: 4).utf8)).isEmpty)
    #expect(ScoreBars.checked([bar(4)], against: Data(score(measures: 4).utf8)).isEmpty)
    #expect(ScoreBars.checked([bar(3)], against: Data(score(measures: 4).utf8)).count == 1)
  }
}
