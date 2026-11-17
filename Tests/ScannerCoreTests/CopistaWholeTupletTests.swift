import Testing
@testable import ScannerCore

struct CopistaWholeTupletTests {
  typealias E = Copista.Event
  typealias Q = Copista.Q

  private func note(_ step: String, type: String = "quarter", onset: Q, confidence: Double = 0.999,
                    alternative: Q? = nil) -> E {
    let e = E(x: onset.double, kind: "note")
    e.step = step; e.typ = type; e.tup = "3/2"
    e.dur = Copista.Vocab.duration(type, 0, e.tup)
    var beat = [Double](repeating: 0.000001, count: 16)
    var frac = [Double](repeating: 0.000001, count: 48)
    let tick = Int((onset * Q(48)).double)
    beat[tick / 48] = 0.999; frac[tick % 48] = 0.999
    if let alternative {
      let t = Int((alternative * Q(48)).double)
      beat[t / 48] = 0.999; frac[t % 48] = 0.4; frac[tick % 48] = 0.6
    }
    e.dist = (beat, frac, [1 - confidence, confidence, 0, 0, 0, 0, 0, 0])
    return e
  }

  private func gap(_ duration: Q) -> E {
    let e = E(x: 0, kind: "gap"); e.dur = duration; return e
  }

  @Test func missingMiddleMemberKeepsNotesAtTheirOriginalBeats() {
    let a = note("D", onset: Q(0)), b = note("E", onset: Q(4, 3))
    var out = [a, gap(Q(2, 3)), b]
    _ = Copista.Writer.wholeTuplets(&out)
    #expect(out.filter { $0.kind == "note" }.map(\.step) == ["D", "E"])
    #expect(out.count == 3)
    #expect(out[1].hidden && out[1].kind == "rest")
    #expect(out.allSatisfy { $0.tup == "3/2" && $0.dur == Q(2, 3) })
    #expect(out.first?.tupletMark == "start" && out.last?.tupletMark == "stop")
  }

  @Test func isolatedFragmentCanBecomePlainWhenCombinedEvidenceSupportsIt() {
    let a = note("E", type: "eighth", onset: Q(0), confidence: 0.8)
    let b = note("E", type: "eighth", onset: Q(2, 3), confidence: 0.8, alternative: Q(1, 2))
    var out = [a, gap(Q(1, 3)), b]
    _ = Copista.Writer.wholeTuplets(&out)
    #expect(out.count == 2)
    #expect(out.allSatisfy { $0.tup == "none" && $0.dur == Q(1, 2) })
  }

  @Test func completeGroupsProtectAnUncertainFragmentOfTheSameRatio() {
    let a = note("E", type: "eighth", onset: Q(0), confidence: 0.8)
    let b = note("E", type: "eighth", onset: Q(2, 3), confidence: 0.8, alternative: Q(1, 2))
    let plain = E(x: 1, kind: "note")
    var out = [a, gap(Q(1, 3)), b, plain,
               note("F", onset: Q(2)), note("G", onset: Q(8, 3)), note("A", onset: Q(10, 3))]
    _ = Copista.Writer.wholeTuplets(&out)
    #expect(a.tup == "3/2" && b.tup == "3/2")
    #expect(out.contains { $0.hidden && $0.dur == Q(1, 3) })
    #expect(out.filter { $0.kind == "note" }.count == 6)
  }

  @Test func aGapInsideTwoGroupsDoesNotTurnTheirFirstNotesPlain() {
    let notes = [note("D", onset: Q(0)), note("E", onset: Q(4, 3)),
                 note("F", onset: Q(2)), note("E", onset: Q(8, 3)), note("F", onset: Q(10, 3))]
    var out = [notes[0], gap(Q(2, 3))] + Array(notes.dropFirst())
    _ = Copista.Writer.wholeTuplets(&out)
    #expect(out.filter { $0.kind == "note" }.map(\.step) == notes.map(\.step))
    #expect(out.allSatisfy { $0.tup == "3/2" })
    #expect(out.filter { $0.tupletMark == "start" }.count == 2)
    #expect(out.reduce(Q.zero) { $0 + $1.dur } == Q(4))
  }

  @Test func aRunCanUseAnAdjacentGapToCompleteItsLastGroup() {
    let notes = [note("C", type: "eighth", onset: Q(0)),
                 note("D", type: "eighth", onset: Q(2, 3)),
                 note("E", type: "eighth", onset: Q(1)),
                 note("D", type: "eighth", onset: Q(4, 3))]
    var out = [notes[0], gap(Q(1, 3))] + Array(notes.dropFirst()) + [gap(Q(1, 3))]
    _ = Copista.Writer.wholeTuplets(&out)
    #expect(notes.allSatisfy { $0.tup == "3/2" && $0.dur == Q(1, 3) })
    #expect(out.filter { $0.hidden }.count == 2)
    #expect(out.filter { $0.tupletMark == "start" }.count == 2)
    #expect(out.reduce(Q.zero) { $0 + $1.dur } == Q(2))
    #expect(out.filter { $0.kind == "note" }.map(\.step) == notes.map(\.step))
  }

  @Test func missingEvidenceConservativelyKeepsTheTuplet() {
    let a = note("D", onset: Q(0)), b = note("E", onset: Q(4, 3))
    a.dist = nil; b.dist = nil
    var out = [a, gap(Q(2, 3)), b]
    _ = Copista.Writer.wholeTuplets(&out)
    #expect(a.tup == "3/2" && b.tup == "3/2")
    #expect(out.contains { $0.hidden })
  }
}
