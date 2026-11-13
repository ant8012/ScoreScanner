import Foundation
import Testing

@testable import ScannerCore

struct CopistaTidyTests {
  /// One 3/4 measure (24 divisions to the quarter) of `body`.
  private func score(_ body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>\
    <part id="P1"><measure number="1"><attributes><divisions>24</divisions><time><beats>3</beats>\
    <beat-type>4</beat-type></time></attributes>\(body)</measure></part></score-partwise>
    """
  }

  private func note(_ step: String, _ octave: Int, _ duration: Int, voice: Int, chord: Bool = false) -> String {
    "<note>\(chord ? "<chord></chord>" : "")<pitch><step>\(step)</step><octave>\(octave)</octave></pitch>"
      + "<duration>\(duration)</duration><voice>\(voice)</voice><type>quarter</type></note>"
  }

  private func notes(_ xml: String) throws -> [(pitch: String, voice: String, hidden: Bool)] {
    let root = try XMLNode.parse(Data(xml.utf8))
    return root.all("part")[0].all("measure").flatMap { $0.all("note") }.map { n in
      let p = n.first("pitch")
      return ((p.map { ($0.first("step")?.text ?? "") + ($0.first("octave")?.text ?? "") } ?? "rest"),
              n.first("voice")?.text ?? "", n.attributes["print-object"] == "no")
    }
  }

  @Test func aCleanBarIsLeftExactlyAsWritten() {
    let xml = score(note("C", 4, 24, voice: 1) + note("D", 4, 24, voice: 1) + note("E", 4, 24, voice: 1))
    #expect(Copista.Tidy.apply(xml) == xml)
  }

  @Test func aPitchNoPianoReachesIsDroppedAndKeepsItsTime() throws {
    // G0 alone becomes a hidden rest; E8 stacked on a real note just goes
    let xml = score(note("G", 0, 24, voice: 1) + note("D", 4, 24, voice: 1) + note("E", 8, 24, voice: 1, chord: true)
      + note("E", 4, 24, voice: 1))
    let out = try notes(Copista.Tidy.apply(xml))
    #expect(out.map(\.pitch) == ["rest", "D4", "E4"])
    #expect(out[0].hidden)
  }

  @Test func aFifthVoiceMovesWhereAVoiceIsFreeOrGoes() throws {
    // voices 1-4 fill the bar's first two beats; voice 5's note on beat 3 moves into voice 1, its beat-1 note
    // has nowhere to go
    var body = ""
    for v in 1...4 {
      if v > 1 { body += "<backup><duration>48</duration></backup>" }
      body += note("C", 4, 48, voice: v)
    }
    body += "<backup><duration>48</duration></backup>" + note("F", 4, 24, voice: 5)
      + "<forward><duration>24</duration></forward>" + note("G", 4, 24, voice: 5)
    let out = try notes(Copista.Tidy.apply(score(body)))
    #expect(!out.contains { $0.pitch == "F4" })
    #expect(out.first { $0.pitch == "G4" }?.voice == "1")
    #expect(Set(out.map(\.voice)) == ["1", "2", "3", "4"])
  }

  private func eighth(_ step: String, triplet: String? = nil) -> String {
    let tm = triplet != nil
    return "<note><pitch><step>\(step)</step><octave>4</octave></pitch><duration>\(tm ? 8 : 12)</duration>"
      + "<voice>1</voice><type>eighth</type>"
      + (tm ? "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>" : "")
      + (triplet.map { $0.isEmpty ? "" : "<notations><tuplet type=\"\($0)\"></tuplet></notations>" } ?? "") + "</note>"
  }

  @Test func anOverfullBarGetsItsOwnMeterAndTheNextBarReturns() throws {
    // two 4/4 bars; the first holds nine eighths
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>\
      <part id="P1"><measure number="1"><attributes><divisions>24</divisions><time><beats>4</beats>\
      <beat-type>4</beat-type></time></attributes>\(String(repeating: eighth("C"), count: 9))</measure>\
      <measure number="2">\(String(repeating: eighth("D"), count: 8))</measure></part></score-partwise>
      """
    let root = try XMLNode.parse(Data(Copista.Tidy.apply(xml).utf8))
    let measures = root.all("part")[0].all("measure")
    let first = try #require(measures[0].first("attributes")?.first("time"))
    #expect(first.first("beats")?.text == "9" && first.first("beat-type")?.text == "8")
    #expect(first.attributes["id"]?.hasPrefix(Copista.Tidy.overflowID) == true)
    #expect(measures[0].all("direction").contains { $0.first("direction-type")?.first("words")?.text == "check bar" })
    let second = try #require(measures[1].first("attributes")?.first("time"))
    #expect(second.first("beats")?.text == "4" && second.first("beat-type")?.text == "4")
    #expect(measures[0].all("note").count == 9)
  }

  @Test func aTripletGroupThatLostItsStartIsBracketedAgain() throws {
    // a 3/4 bar: two triplet groups, the second missing its start, then two plain eighths
    let body = eighth("C", triplet: "start") + eighth("D", triplet: "") + eighth("E", triplet: "stop")
      + eighth("F", triplet: "") + eighth("G", triplet: "") + eighth("A", triplet: "stop")
      + eighth("B") + eighth("C")
    let out = try XMLNode.parse(Data(Copista.Tidy.apply(score(body)).utf8))
    let marks = out.all("part")[0].all("measure")[0].all("note").map {
      $0.first("notations")?.first("tuplet")?.attributes["type"] ?? ""
    }
    #expect(marks == ["start", "", "stop", "start", "", "stop", "", ""])
  }

  @Test func aMissedTripletNoteBecomesATripletRest() throws {
    // a 3/4 bar: two quarters, then a triplet group with its first note missing (a third of a beat left empty)
    let body = note("C", 4, 24, voice: 1) + note("D", 4, 24, voice: 1) + "<forward><duration>8</duration></forward>"
      + eighth("E", triplet: "") + eighth("F", triplet: "")
    let out = try XMLNode.parse(Data(Copista.Tidy.apply(score(body)).utf8))
    let notes = out.all("part")[0].all("measure")[0].all("note")
    #expect(notes.map { $0.first("pitch")?.first("step")?.text ?? "rest" } == ["C", "D", "rest", "E", "F"])
    #expect(notes[2].first("time-modification") != nil)
    #expect(notes.map { $0.first("notations")?.first("tuplet")?.attributes["type"] ?? "" } == ["", "", "start", "", "stop"])
  }

  @Test func aStrayTripletFragmentInASecondVoiceGoesTheRestStays() throws {
    // voice 2: a quarter on beat 1 (fine), then a note starting a third of a beat later than any plain rest
    // reaches (44 of 72), then one on beat 3 (fine again once the stray note is gone)
    let body = note("C", 5, 24, voice: 1) + note("D", 5, 24, voice: 1) + note("E", 5, 24, voice: 1)
      + "<backup><duration>72</duration></backup>" + note("A", 3, 24, voice: 2)
      + "<forward><duration>20</duration><voice>2</voice></forward>" + note("B", 3, 4, voice: 2)
      + "<forward><duration>0</duration></forward>" + "<backup><duration>0</duration></backup>"
      + note("F", 3, 24, voice: 2)
    let out = try notes(Copista.Tidy.apply(score(body)))
    #expect(out.map(\.pitch) == ["C5", "D5", "E5", "A3", "F3"])
  }
}
