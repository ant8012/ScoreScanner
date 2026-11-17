import Testing
@testable import ScannerCore

struct CopistaBarFitTests {
  typealias E = Copista.Event
  typealias Q = Copista.Q
  typealias W = Copista.Writer

  /// A plain note the model places on `beat` (quarters from the bar's start), read as `type`, with the model's
  /// weight for each value.
  private func note(_ beat: Int, type: String = "quarter", values: [String: Double] = ["quarter": 0.97]) -> E {
    let e = E(x: Double(beat), kind: "note")
    e.typ = type
    var b = [Double](repeating: 0.000001, count: 16), f = [Double](repeating: 0.000001, count: 48)
    b[beat] = 0.99; f[0] = 0.99
    e.dist = (b, f, [0.999999, 0.000001, 0, 0, 0, 0, 0, 0])
    e.valueP = values; e.dotsP = [0.97, 0.02, 0.01]
    return e
  }

  private func fit(_ order: [E], barLen: Q = Q(4)) {
    let read = order.map { ($0.typ, $0.dots, $0.tup) }
    let score = W.decodeRhythm(order, strict: true, barLen: barLen)!
    W.fitOneValue(order, read: read, strict: true, barLen: barLen, score: score)
  }

  @Test func aQuarterReadAsAHalfFitsTheBarAgain() {
    let order = [note(0), note(1), note(2, type: "half", values: ["half": 0.6, "quarter": 0.38]), note(3)]
    fit(order)
    #expect(order.map(\.typ) == ["quarter", "quarter", "quarter", "quarter"])
    #expect(W.reach(order).end == Q(4))
  }

  @Test func aBarThatFitsIsLeftAlone() {
    let order = [note(0), note(1), note(2, type: "half", values: ["half": 0.6, "quarter": 0.38])]
    fit(order)
    #expect(order.map(\.typ) == ["quarter", "quarter", "half"])
  }

  @Test func noBelievableRunnerUpKeepsTheReading() {
    let order = [note(0), note(1), note(2, type: "half", values: ["half": 0.99, "quarter": 0.01]), note(3)]
    fit(order)
    #expect(order.map(\.typ) == ["quarter", "quarter", "half", "quarter"])
  }

  @Test func anExtraDotTheModelDoubtedGoes() {
    let dotted = note(0, type: "half", values: ["half": 0.97])
    dotted.dots = 1; dotted.dotsP = [0.4, 0.58, 0.02]
    let order = [dotted, note(2), note(3)]
    fit(order)
    // without the fit, the decoder squeezes the bar by making the dotted half a triplet the model ruled out
    #expect(order[0].dots == 0)
    #expect(order.map(\.tup) == ["none", "none", "none"])
    #expect(W.reach(order).end == Q(4))
  }

  /// One staff's bar holding a single note of `quarters` length in 9/8.
  private func staffBar(_ quarters: Q) -> Copista.StaffBar {
    let e = E(x: 0, kind: "note"); e.dur = quarters
    var v = Copista.Voices(); v[1] = [e]
    var state = Copista.BarState(); state.time = "9/8"
    return Copista.StaffBar(staff: 0, bar: 0, voices: v, dirs: [], marks: Copista.Marks(), state: state)
  }

  @Test func aBarIsTakenFittedOnlyWhenEveryStaffFits() {
    // as read, both hands hold a dotted whole (6 quarters) in a 9/8 bar (4.5)
    let plain: [[[Copista.StaffBar?]]] = [[[staffBar(Q(6)), staffBar(Q(6))]]]
    // the fit mends only the left hand: the right hand would be cut away, so the bar stays as read
    let half: [[[Copista.StaffBar?]]] = [[[staffBar(Q(6)), staffBar(Q(4))]]]
    #expect(W.fittedColumns(plain, half)[0][0][1]!.voices[1]![0].dur == Q(6))
    // the fit mends both hands: the bar is taken fitted
    let both: [[[Copista.StaffBar?]]] = [[[staffBar(Q(4)), staffBar(Q(4))]]]
    #expect(W.fittedColumns(plain, both)[0][0].allSatisfy { $0!.voices[1]![0].dur == Q(4) })
  }
}
