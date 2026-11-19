import Foundation
import Testing
@testable import ScannerCore

struct ScoreValidityMusicXMLTests {
  private func score(_ bars: String) -> Data {
    Data(("<score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>Test</part-name></score-part></part-list><part id=\"P1\">" + bars + "</part></score-partwise>").utf8)
  }
  private let attributes = "<attributes><divisions>12</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>"
  private func note(_ pitch: String = "C", duration: Int = 4, type: String = "eighth", voice: Int = 1,
                    tuplet: Bool = true, mark: String = "", extra: String = "") -> String {
    "<note><pitch><step>\(pitch)</step><octave>4</octave></pitch><duration>\(duration)</duration><voice>\(voice)</voice><type>\(type)</type>" +
      (tuplet ? "<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>" : "") +
      (mark.isEmpty ? "" : "<notations><tuplet type=\"\(mark)\"/></notations>") + extra + "</note>"
  }
  @Test func meterAfterTheNotesStartsAtTheNextBar() throws {
    // a 6/4 written beside an end-of-bar clef change: MuseScore reads this bar as 4/4, so its 6/4 of notes is long
    let late = "<attributes><time><beats>6</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>"
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 72, type: "whole", tuplet: false, extra: "<dot/>"))\(late)</measure>" +
      "<measure number=\"2\">\(note(duration: 72, type: "whole", tuplet: false, extra: "<dot/>"))</measure>")
    let m = try XMLNode.parse(ScoreValidityMusicXML.apply(xml)).first("part")!.first("measure")!
    let opening = m.children.prefix { $0.tag != "note" }.filter { $0.tag == "attributes" }
    #expect(opening.contains { $0.first("time")?.first("beats")?.text == "6" })
  }
  @Test func pageJoinDropsRestatedClefsKeyAndMeter() throws {
    func page(_ clef: String) -> Data {
      Data("""
        <score-partwise><part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
        <part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key>
        <time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>\(clef)</sign><line>2</line></clef></attributes>
        <note><pitch><step>C</step><octave>5</octave></pitch><duration>3</duration><voice>1</voice><type>half</type><dot/></note>
        </measure></part></score-partwise>
        """.utf8)
    }
    let root = try XMLNode.parse(CopistaMerge.combine([page("G"), page("G"), page("C")]))
    let bars = root.first("part")!.all("measure")
    #expect(bars[0].first("attributes")?.first("clef") != nil)
    // page 2 states what is in force: only its divisions stay
    #expect(bars[1].first("attributes")?.children.map(\.tag) == ["divisions"])
    // page 3 changes the clef: the change stays
    #expect(bars[2].first("attributes")?.children.map(\.tag) == ["divisions", "clef"])
  }

  @Test func validFileIsByteIdentical() throws {
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 48, type: "whole", tuplet: false))</measure>")
    #expect(try ScoreValidityMusicXML.apply(xml) == xml)
  }
  @Test func validTypelessMeasureRestStaysByteIdentical() throws {
    let xml = score("<measure number=\"1\">\(attributes)<note print-object=\"no\"><rest/><duration>48</duration><voice>1</voice></note></measure>")
    #expect(try ScoreValidityMusicXML.apply(xml) == xml)
  }
  @Test func graceChordMemberHasNoSoundingDuration() throws {
    let grace = "<note><grace slash=\"yes\"/><chord/><pitch><step>E</step><octave>4</octave></pitch><voice>1</voice><type>eighth</type></note>"
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 48, type: "whole", tuplet: false))\(grace)</measure>")
    #expect(try ScoreValidityMusicXML.apply(xml) == xml)
  }
  @Test func newTupletNotationsPrecedeLyrics() throws {
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 32, type: "whole", extra: "<lyric><text>word</text></lyric>"))<forward><duration>16</duration></forward></measure>")
    let m = try XMLNode.parse(ScoreValidityMusicXML.apply(xml)).first("part")!.first("measure")!
    let n = m.all("note").first { $0.first("lyric") != nil }!
    #expect(n.children.firstIndex { $0.tag == "notations" }! < n.children.firstIndex { $0.tag == "lyric" }!)
  }
  @Test func partialTupletKeepsPitchAndTimeAndBecomesIdempotent() throws {
    let xml = score("<measure number=\"1\">\(attributes)\(note(mark: "start"))<forward><duration>4</duration></forward>\(note("E", mark: "stop"))\(note("G", duration: 36, type: "half", tuplet: false, extra: "<dot/>"))</measure>")
    let fixed = try ScoreValidityMusicXML.apply(xml)
    let root = try XMLNode.parse(fixed)
    #expect(root.first("part")!.first("measure")!.all("note").compactMap { $0.first("pitch")?.first("step")?.text } == ["C", "E", "G"])
    #expect(try ScoreValidityMusicXML.apply(fixed) == fixed)
  }
  @Test func harmonyAfterMidBarClefUsesLegalAbsoluteOffset() throws {
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 24, type: "half", tuplet: false))<attributes><clef><sign>G</sign><line>2</line></clef></attributes><harmony><root><root-step>C</root-step></root><kind>major</kind><offset>36</offset></harmony>\(note(duration: 24, type: "half", tuplet: false))</measure>")
    let fixed = try XMLNode.parse(ScoreValidityMusicXML.apply(xml))
    let m = fixed.first("part")!.first("measure")!
    let div = try m.first("attributes")!.first("divisions")!.integer()
    #expect(try m.first("harmony")!.first("offset")!.integer() == div * 3)
  }
  @Test func annotationCannotExtendShortFinalBar() throws {
    let xml = score("<measure number=\"1\">\(attributes)<harmony><root><root-step>C</root-step></root><kind>major</kind><offset>42</offset></harmony>\(note(duration: 36, type: "half", tuplet: false, extra: "<dot/>"))</measure>")
    let fixed = try XMLNode.parse(ScoreValidityMusicXML.apply(xml)), m = fixed.first("part")!.first("measure")!
    let div = try m.first("attributes")!.first("divisions")!.integer()
    #expect(try m.first("harmony")!.first("offset")!.integer() == 3 * div)
    #expect(m.all("attributes").compactMap { $0.first("time") }.count == 1)
  }
  @Test func fifthSimultaneousVoiceKeepsEveryPitchWithTies() throws {
    var body = attributes
    for i in 0..<5 {
      if i > 0 { body += "<backup><duration>\(12 + (i - 1) * 6)</duration></backup>" }
      body += note(["C", "D", "E", "F", "G"][i], duration: 12 + i * 6, type: "quarter", voice: i + 1, tuplet: false)
    }
    let fixed = try ScoreValidityMusicXML.apply(score("<measure number=\"1\">\(body)</measure>"))
    let m = try XMLNode.parse(fixed).first("part")!.first("measure")!
    #expect(Set(m.all("note").compactMap { $0.first("pitch")?.first("step")?.text }) == Set(["C", "D", "E", "F", "G"]))
    #expect(Set(m.all("note").compactMap { $0.first("voice")?.text }).count <= 4)
    #expect(try ScoreValidityMusicXML.apply(fixed) == fixed)
  }
  @Test func duplicatePageIDsAreUniqueWithoutChangingPitches() throws {
    let n = note(duration: 48, type: "whole", tuplet: false).replacingOccurrences(of: "<note>", with: "<note id=\"same\">")
    let fixed = try XMLNode.parse(ScoreValidityMusicXML.apply(score("<measure number=\"1\">\(attributes)\(n)</measure><measure number=\"2\">\(n)</measure>")))
    let notes = fixed.first("part")!.all("measure").flatMap { $0.all("note") }
    #expect(Set(notes.compactMap { $0.attributes["id"] }).count == 2)
  }
  @Test func restoredDivisionsPrecedeNotesWhenNextClefIsMidBar() throws {
    let bad = "<measure number=\"1\">\(attributes)\(note(mark: "start"))\(note(mark: "stop"))<forward><duration>40</duration></forward></measure>"
    let next = "<measure number=\"2\">\(note(duration: 24, type: "half", tuplet: false))<attributes><clef><sign>F</sign><line>4</line></clef></attributes>\(note(duration: 24, type: "half", tuplet: false))</measure>"
    let root = try XMLNode.parse(ScoreValidityMusicXML.apply(score(bad + next)))
    let m = root.first("part")!.all("measure")[1]
    #expect(m.children[0].tag == "attributes")
    #expect(m.children[0].first("divisions")?.text == "12")
  }
  @Test func tinyBinaryBarIsPaddedToMuseScoreMeasureResolution() throws {
    let xml = score("<measure number=\"1\"><attributes><divisions>256</divisions></attributes>\(note(duration: 1, type: "1024th", tuplet: false))</measure>")
    let fixed = try XMLNode.parse(ScoreValidityMusicXML.apply(xml)).first("part")!.first("measure")!
    let div = try fixed.first("attributes")!.first("divisions")!.integer()
    #expect(Copista.Q(CopistaMerge.measureLength(fixed), div) == Copista.Q(1, 32))
    #expect(fixed.all("note").contains { $0.first("rest") != nil })
  }
  @Test func zeroDurationPitchedNoteFailsClosed() throws {
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 0, type: "quarter", tuplet: false))</measure>")
    #expect(throws: ScannerError.self) { try ScoreValidityMusicXML.apply(xml) }
  }
  @Test func aRepairThatCannotFinishKeepsTheScoreAsWritten() {
    let xml = score("<measure number=\"1\">\(attributes)\(note(duration: 0, type: "quarter", tuplet: false))</measure>")
    #expect(ScoreValidityMusicXML.repaired(xml) == xml)
  }
  @Test func tiedSplitKeepsIncomingAndOutgoingTiesAtTheirEnds() {
    let n = XMLNode("note", children: [XMLNode("pitch"), XMLNode("tie", attributes: ["type": "start"]), XMLNode("tie", attributes: ["type": "stop"])])
    let first = ScoreValidityMusicXML.piece(n, index: 0, count: 3)
    let middle = ScoreValidityMusicXML.piece(n, index: 1, count: 3)
    let last = ScoreValidityMusicXML.piece(n, index: 2, count: 3)
    for p in [first, middle, last] { #expect(Set(p.all("tie").compactMap { $0.attributes["type"] }) == Set(["start", "stop"])) }
  }
}
