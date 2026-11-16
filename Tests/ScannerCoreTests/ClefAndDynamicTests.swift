import Foundation
import Testing

@testable import ScannerCore

/// Two misreads common on lead sheets: an 8 put under a plain treble clef (the line plays an octave low), and
/// chord names in italics read as dynamics ("B°" as "pp").
struct ClefAndDynamicTests {
  typealias Writer = Copista.Writer

  @Test func octaveClefNeedsTheDetector() {
    // the reader adds an 8 the detector did not see: the plain clef stays
    #expect(Writer.seenClef("G2_8b", detected: ["G2"]) == "G2")
    #expect(Writer.seenClef("F4_8a", detected: ["F4"]) == "F4")
    #expect(Writer.seenClef("G2_15b", detected: ["G2"]) == "G2")
    // both see it: a real octave clef
    #expect(Writer.seenClef("G2_8b", detected: ["G2_8b"]) == "G2_8b")
    // nothing detected there: the reader is all there is
    #expect(Writer.seenClef("G2_8b", detected: []) == "G2_8b")
    // plain clefs and changes of clef are left alone
    #expect(Writer.seenClef("G2", detected: ["G2_8b"]) == "G2")
    #expect(Writer.seenClef("F4", detected: ["G2"]) == "F4")
  }

  private func sym(p: Double, top: Double) -> Copista.Sym {
    Copista.Sym(i: 0, cls: "dynam_pp", post: [], p: p, n: 1, box: (100, top, 120, top + 12))
  }

  @Test func unsureDynamicsAboveTheStaffAreDropped() {
    let st = Copista.Staff(bars: [], sp: 8, y0: 200, y1: 232, x0: 50, x1: 900)
    // above the staff, where chord names go
    #expect(!Writer.keptDynamic(sym(p: 0.53, top: 170), st))
    #expect(Writer.keptDynamic(sym(p: 0.9, top: 170), st))
    // below it
    #expect(Writer.keptDynamic(sym(p: 0.4, top: 245), st))
    #expect(!Writer.keptDynamic(sym(p: 0.2, top: 245), st))
  }
}
