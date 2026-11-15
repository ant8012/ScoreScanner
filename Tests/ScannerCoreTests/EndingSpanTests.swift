import Foundation
import Testing

@testable import ScannerCore

/// Where 1st and 2nd endings start and stop, from the marks the detector reads: the printed number, the bracket's
/// opening and closing hooks, and the repeat signs.
struct EndingSpanTests {
  typealias Marks = Copista.Marks
  typealias Span = Copista.EndingSpan

  private func bar(
    _ ending: String? = nil, top: Double = 6, sure: Bool = true, left: String? = nil, right: String? = nil,
    hook: Double? = nil, opens: Double? = nil
  ) -> Marks? {
    var m = Marks()
    if let ending { m.endings = [Copista.EndingGlyph(number: ending, x: 1, top: top, sure: sure)] }
    m.left = left
    m.right = right
    if let hook { m.endingHooks = [hook] }
    if let opens { m.bracketStarts = [opens] }
    return m
  }

  private func spans(_ bars: [Marks?], _ systems: [Int]? = nil) -> [Span] {
    Copista.Writer.endingSpans(bars, systems: systems ?? Array(repeating: 0, count: bars.count))
  }

  @Test func aTwoBarFirstEndingRunsToItsHook() {
    // SMILES: "1." over bars 32 and 33, closed by its hook at the repeat, then "2."
    let bars = [bar(), bar("1"), bar(right: "barLine_repeat_end", hook: 6.2), bar("2"), bar()]
    #expect(spans(bars) == [
      Span(start: 1, stop: 2, number: "1", closed: true), Span(start: 3, stop: 3, number: "2", closed: false),
    ])
  }

  @Test func withoutItsHookAFirstEndingRunsToItsRepeat() {
    let bars = [bar("1"), bar(), bar(), bar(right: "barLine_repeat_end"), bar("2"), bar()]
    #expect(spans(bars).map { [$0.start, $0.stop] } == [[0, 3], [4, 4]])
  }

  @Test func theLastEndingKeepsOneBarUnlessAHookClosesIt() {
    // an open 2nd ending, and a later repeat that belongs to the next section
    let open = [bar("1", right: "barLine_repeat_end"), bar("2"), bar(), bar(left: "repeat_start"), bar(right: "barLine_repeat_end")]
    #expect(spans(open).map { [$0.start, $0.stop] } == [[0, 0], [1, 1]])
    let closed = [bar("1", right: "barLine_repeat_end"), bar("2"), bar(hook: 6)]
    #expect(spans(closed).last == Span(start: 1, stop: 2, number: "2", closed: true))
  }

  @Test func aHookAtAnotherHeightIsNotTheEndingsOwn() {
    // a tuplet or octave bracket closing lower down does not end the 1st ending
    let bars = [bar("1", top: 7), bar(hook: 3), bar(right: "barLine_repeat_end"), bar("2")]
    #expect(spans(bars).first.map { [$0.start, $0.stop] } == [0, 2])
  }

  @Test func anEndingCarriedOverALineBreakIsOne() {
    // ST. LOUIS BLUES: "1." at the end of a line, printed again (no opening hook) at the start of the next
    let bars = [bar(), bar("1", opens: 6.8), bar("1", right: "barLine_repeat_end", hook: 7), bar("2", opens: 6.9)]
    #expect(spans(bars, [0, 0, 1, 1]) == [
      Span(start: 1, stop: 2, number: "1", closed: true), Span(start: 3, stop: 3, number: "2", closed: false),
    ])
  }

  @Test func aSecondBracketReadAsOneIsTheSecondEndingAndImpliesTheRepeat() {
    // cheek (handwritten): both numbers doubtful, "2." read as "1.", and the repeat sign not read
    let bars = [bar(), bar("1", sure: false), bar(), bar("1", sure: false, opens: 7.5), bar(), bar(left: "repeat_start")]
    #expect(spans(bars, [0, 0, 0, 1, 1, 1]) == [
      Span(start: 1, stop: 2, number: "1", closed: true, impliedRepeat: true),
      Span(start: 3, stop: 3, number: "2", closed: false),
    ])
  }

  @Test func aDoubtfulNumberNeedsARepeatSignToCount() {
    // a lone doubtful "1." with no repeat near it is dropped
    #expect(spans([bar(), bar("1", sure: false), bar(), bar()]).isEmpty)
    // closed by a repeat on its line, it counts
    let bars = [bar(), bar("1", sure: false), bar(right: "barLine_repeat_end"), bar()]
    #expect(spans(bars) == [Span(start: 1, stop: 2, number: "1", closed: true)])
  }

  @Test func aMissingFirstEndingIsInferredFromTheSecond() {
    // nrb2-p105: only "2." was read, after the repeat; the 1st ending opens at its hook two bars back
    let bars = [bar(), bar(opens: 6.5), bar(), bar(right: "barLine_repeat_end"), bar("2"), bar()]
    #expect(spans(bars) == [
      Span(start: 1, stop: 3, number: "1", closed: true), Span(start: 4, stop: 4, number: "2", closed: false),
    ])
    // with no hook it is the repeat's own bar
    let bare = [bar(), bar(), bar(right: "barLine_repeat_end"), bar("2")]
    #expect(spans(bare).first == Span(start: 2, stop: 2, number: "1", closed: true))
  }

  @Test func unreadNumbersCountOnFromTheEndingBefore() {
    let bars = [bar("1", right: "barLine_repeat_end"), bar("x", right: "barLine_repeat_end"), bar("x")]
    #expect(spans(bars).map(\.number) == ["1", "2", "3"])
  }
}
