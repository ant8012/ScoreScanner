import Foundation
import Testing
@testable import ScannerCore

struct ScoreGapRestsMusicXMLTests {
  private func score(_ body: String, beats: Int = 4, unit: Int = 4, implicit: Bool = false) -> String {
    "<score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>Test</part-name></score-part></part-list><part id=\"P1\"><measure number=\"1\"\(implicit ? " implicit=\"yes\"" : "")><attributes><divisions>48</divisions><time><beats>\(beats)</beats><beat-type>\(unit)</beat-type></time></attributes>\(body)</measure></part></score-partwise>"
  }
  private func note(_ step: String = "C", duration: Int = 48, voice: Int = 1, staff: Int = 1) -> String {
    "<note><pitch><step>\(step)</step><octave>4</octave></pitch><duration>\(duration)</duration><voice>\(voice)</voice><type>quarter</type><staff>\(staff)</staff><lyric><text>la</text></lyric></note>"
  }
  private func gap(_ duration: Int, voice: Int? = 1, staff: Int? = nil) -> String {
    "<forward><duration>\(duration)</duration>" + (voice.map { "<voice>\($0)</voice>" } ?? "")
      + (staff.map { "<staff>\($0)</staff>" } ?? "") + "</forward>"
  }
  private func measure(_ xml: String) throws -> ScannerCore.XMLNode { try ScannerCore.XMLNode.parse(Data(xml.utf8)).first("part")!.first("measure")! }
  private func rests(_ xml: String) throws -> [ScannerCore.XMLNode] { try measure(xml).all("note").filter { $0.first("rest") != nil } }
  private func checkTimeAndNotes(_ before: String, _ after: String) throws {
    let a = try measure(before), b = try measure(after)
    #expect(Copista.Tidy.reach(a) == Copista.Tidy.reach(b))
    func pitches(_ m: ScannerCore.XMLNode) -> [String] {
      var cursor = 0, previous = 0, out: [String] = []
      for n in m.children {
        let d = Int(n.first("duration")?.text ?? "") ?? 0
        if n.tag == "backup" { cursor -= d }
        if n.tag == "forward" { cursor += d }
        if n.tag == "note" {
          if n.first("chord") == nil { previous = cursor }
          if n.first("pitch") != nil { out.append("\(previous):\(n.serialized())") }
          if n.first("chord") == nil && n.first("grace") == nil { cursor += d }
        }
      }
      return out
    }
    #expect(pitches(a) == pitches(b))
  }

  @Test func missingBeatIsPrintedWithoutChangingNotesOrLyrics() throws {
    let before = score(note() + gap(48) + note("D", duration: 96))
    let after = ScoreGapRestsMusicXML.apply(before), rs = try rests(after)
    #expect(rs.count == 1 && rs[0].first("type")?.text == "quarter")
    #expect(rs[0].attributes["print-object"] == nil && rs[0].attributes["color"] == nil)
    try checkTimeAndNotes(before, after)
    #expect(ScoreGapRestsMusicXML.apply(after) == after)
  }
  @Test func oneAndAQuarterTailSplitsIntoQuarterAndSixteenthWithoutExtendingShortBar() throws {
    let before = score(note() + gap(60), implicit: true)
    let after = ScoreGapRestsMusicXML.apply(before)
    #expect(try rests(after).map { $0.first("type")?.text } == ["quarter", "16th"])
    try checkTimeAndNotes(before, after)
    #expect(try measure(after).attributes["implicit"] == "yes")
  }
  @Test func tailAtAnOffbeatRespectsTheBeatBoundary() throws {
    let before = score(note(duration: 132) + gap(60))
    let after = ScoreGapRestsMusicXML.apply(before)
    #expect(try rests(after).map { $0.first("type")?.text } == ["16th", "quarter"])
    try checkTimeAndNotes(before, after)
  }
  @Test func dottedQuarterGapDoesNotCrossASimpleBeat() throws {
    let before = score(gap(72) + note(duration: 120))
    #expect(try rests(ScoreGapRestsMusicXML.apply(before)).map { $0.first("type")?.text } == ["quarter", "eighth"])
  }
  @Test func emptyStaffGetsAWholeMeasureRest() throws {
    let before = score(gap(192, voice: nil))
    let after = ScoreGapRestsMusicXML.apply(before), rs = try rests(after)
    #expect(rs.count == 1 && rs[0].first("rest")?.attributes["measure"] == "yes")
    #expect(rs[0].first("duration")?.text == "192" && rs[0].first("voice")?.text == "1")
    try checkTimeAndNotes(before, after)
  }
  @Test func secondVoiceGapStaysInItsVoice() throws {
    let before = score(note(duration: 192) + "<backup><duration>192</duration></backup>" + gap(48, voice: 2) + note("G", duration: 144, voice: 2))
    let after = ScoreGapRestsMusicXML.apply(before)
    #expect(try rests(after).first?.first("voice")?.text == "2")
    try checkTimeAndNotes(before, after)
  }
  @Test func voiceLessLowerStaffGapUsesItsMainVoice() throws {
    let before = score(note(duration: 192) + "<backup><duration>192</duration></backup>" + note("G", voice: 5, staff: 2) + gap(48, voice: nil) + note("A", duration: 96, voice: 5, staff: 2))
    let after = ScoreGapRestsMusicXML.apply(before), r = try #require(rests(after).first)
    #expect(r.first("voice")?.text == "5" && r.first("staff")?.text == "2")
    try checkTimeAndNotes(before, after)
  }
  @Test func tupletFillerStaysHiddenAndByteIdenticalWithoutOtherChanges() {
    let filler = "<note print-object=\"no\"><rest/><duration>16</duration><voice>1</voice><type>eighth</type><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification></note>"
    let before = score(filler)
    #expect(ScoreGapRestsMusicXML.apply(before) == before)
  }
  @Test func impossiblePitchRestBecomesVisibleAfterTidy() throws {
    let before = score(note("G").replacingOccurrences(of: "<octave>4", with: "<octave>0") + note("D", duration: 144))
    let tidied = Copista.Tidy.apply(before)
    #expect(try rests(tidied).first?.attributes["print-object"] == "no")
    let after = ScoreGapRestsMusicXML.apply(tidied)
    #expect(try rests(after).first?.attributes["print-object"] == nil)
    try checkTimeAndNotes(tidied, after)
  }
  @Test func typelessMergedPaddingRestGetsAMeasureRest() throws {
    let before = score("<note print-object=\"no\"><rest/><duration>192</duration><voice>1</voice></note>")
    let after = ScoreGapRestsMusicXML.apply(before)
    #expect(try rests(after).first?.first("rest")?.attributes["measure"] == "yes")
    try checkTimeAndNotes(before, after)
  }
  @Test func nonBinaryGapStaysAForward() {
    let before = score(gap(16) + note(duration: 176))
    #expect(ScoreGapRestsMusicXML.apply(before) == before)
  }
  @Test func structuralForwardOverExistingMusicIsNotPrinted() {
    let before = score(note(duration: 192) + "<backup><duration>192</duration></backup>" + gap(48, voice: nil) + "<attributes><clef><sign>F</sign><line>4</line></clef></attributes><backup><duration>48</duration></backup>")
    #expect(ScoreGapRestsMusicXML.apply(before) == before)
  }
  @Test func compoundBeatCanUseADottedQuarter() throws {
    let before = score(gap(72) + note(duration: 72), beats: 6, unit: 8)
    let after = ScoreGapRestsMusicXML.apply(before), r = try #require(rests(after).first)
    #expect(r.first("type")?.text == "quarter" && r.all("dot").count == 1)
    try checkTimeAndNotes(before, after)
  }
  @Test func existingVisibleRestsAndCleanScoresAreNotRewritten() {
    let before = score("<note><rest/><duration>192</duration><type>whole</type></note>")
    #expect(ScoreGapRestsMusicXML.apply(before) == before)
  }
  @Test func ordinaryGapRestsDoNotTriggerValidityRewrites() throws {
    let before = score(note() + gap(48) + note("D", duration: 96).replacingOccurrences(of: "<type>quarter", with: "<type>half"))
    let printed = Data(ScoreGapRestsMusicXML.apply(before).utf8)
    #expect(try ScoreValidityMusicXML.apply(printed) == printed)
  }

  @Test func finalizationPrintsPaddingCreatedByTheValidityGuard() throws {
    // An invalid written value forces the guard to rebuild the voice and pad its silent tail.
    let before = score(note(duration: 48) + gap(48) + note("D", duration: 96))
    let guardOnly = try ScoreValidityMusicXML.apply(before)
    #expect(try rests(guardOnly).contains { $0.attributes["print-object"] == "no" && $0.first("time-modification") == nil })
    let after = ScoreValidityMusicXML.repaired(before)
    #expect(try rests(after).allSatisfy { $0.attributes["print-object"] != "no" || $0.first("time-modification") != nil })
    try checkTimeAndNotes(guardOnly, after)
    #expect(ScoreValidityMusicXML.repaired(after) == after)
  }

  @Test func emptyStaffOfSeveralHiddenPaddingRestsBecomesOneMeasureRest() throws {
    let hidden = "<note print-object=\"no\"><rest/><duration>48</duration><voice>1</voice><type>quarter</type></note>"
    let before = score(String(repeating: hidden, count: 4)), after = ScoreGapRestsMusicXML.apply(before)
    let rs = try rests(after)
    #expect(rs.count == 1 && rs[0].first("rest")?.attributes["measure"] == "yes")
    #expect(rs[0].first("duration")?.text == "192")
    try checkTimeAndNotes(before, after)
  }
  @Test func longSilentTailUsesAlignedStandardValuesInsteadOfHundredsOfQuarterRests() throws {
    let before = score(note() + gap(64 * 48), beats: 65)
    let after = ScoreGapRestsMusicXML.apply(before)
    #expect(try rests(after).count < 10)
    try checkTimeAndNotes(before, after)
  }
  @Test func recognizedVisibleRestRunsAreNotConsolidated() {
    let visible = "<note><rest/><duration>48</duration><voice>1</voice><type>quarter</type></note>"
    let before = score(String(repeating: visible, count: 4))
    #expect(ScoreGapRestsMusicXML.apply(before) == before)
  }

  @Test func forwardAfterOutgoingTieRemainsACursorMoveToPreserveTheSustain() {
    let tied = note(duration: 144).replacingOccurrences(of: "<voice>", with: "<tie type=\"start\"/><voice>")
    let before = score(tied + gap(48))
    #expect(ScoreGapRestsMusicXML.apply(before) == before)
  }

}
