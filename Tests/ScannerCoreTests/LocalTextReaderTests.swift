import Foundation
import Testing

@testable import ScannerCore

struct LocalTextReaderTests {
  @Test func misreadPedalSignsAreNotStaffText() {
    for t in ["Ped.", "Led.", "Red.", "Ted.", "'Led.", "Pcd."] { #expect(LocalTextReader.pedalSign(t), "\(t)") }
    for t in ["rit.", "Largo", "a tempo", "Lead", "Fine", "Red Rose"] { #expect(!LocalTextReader.pedalSign(t), "\(t)") }
  }
  @Test func navigationIsSpelledAsMuseScoreMatchesIt() {
    #expect(LocalTextReader.navigation("D.S. al Coda") == "D.S. al Coda")
    #expect(LocalTextReader.navigation("D. S. AL CODA") == "D.S. al Coda")
    #expect(LocalTextReader.navigation("DS al Coda") == "D.S. al Coda")
    #expect(LocalTextReader.navigation("D.C. al Fine") == "D.C. al Fine")
    #expect(LocalTextReader.navigation("Da Capo al Fine") == "D.C. al Fine")
    #expect(LocalTextReader.navigation("D.S.") == "D.S.")
    #expect(LocalTextReader.navigation("To Coda") == "To Coda")
    #expect(LocalTextReader.navigation("Fine") == "Fine")
    #expect(LocalTextReader.navigation("FINE") == "Fine")
    // inside a longer instruction
    #expect(LocalTextReader.navigation("after fourth verse, D.S. al fifth verse al Coda") == "D.S. al Coda")
    // a lyric "fine", a chord, an ordinary word
    #expect(LocalTextReader.navigation("fine") == nil)
    #expect(LocalTextReader.navigation("Dsus") == nil)
    #expect(LocalTextReader.navigation("Solo") == nil)
  }

  @Test func metronomeMarksAndRehearsalMarks() {
    #expect(LocalTextReader.metronome("J=120") == 120)
    #expect(LocalTextReader.metronome("Medium Swing J = 100") == 100)
    #expect(LocalTextReader.metronome("= ca. 92") == 92)
    #expect(LocalTextReader.metronome("Swing") == nil)
    #expect(LocalTextReader.metronome("= 7") == nil)
    #expect(LocalTextReader.rehearsalMark("[A]") == "A")
    #expect(LocalTextReader.rehearsalMark("12") == "12")
    #expect(LocalTextReader.rehearsalMark("Intro") == nil)
  }

  private func xml(_ beats: Int, _ type: Int) -> Data {
    Data("<score-partwise><part><measure><attributes><time><beats>\(beats)</beats><beat-type>\(type)</beat-type></time></attributes></measure></part></score-partwise>".utf8)
  }

  @Test func theMeterChoosesTheBeatWhenNoNoteIsPrinted() {
    #expect(LocalTextReader.meterBeatUnit(xml(6, 8)) == "dotted-quarter")
    #expect(LocalTextReader.meterBeatUnit(xml(12, 8)) == "dotted-quarter")
    #expect(LocalTextReader.meterBeatUnit(xml(2, 2)) == "half")
    #expect(LocalTextReader.meterBeatUnit(xml(3, 8)) == "eighth")
    #expect(LocalTextReader.meterBeatUnit(xml(4, 4)) == "quarter")
    #expect(LocalTextReader.meterBeatUnit(Data("<score-partwise/>".utf8)) == "quarter")
    // a note named in words is explicit
    #expect(LocalTextReader.namedNoteValue("dotted quarter = 60") == "dotted-quarter")
    #expect(LocalTextReader.namedNoteValue("Swing = 120") == nil)
  }

  @Test func tempoWordingLeavesTheMarkToTheMetronome() {
    #expect(LocalTextReader.tempoWording("Bright = 120") == "Bright")
    #expect(LocalTextReader.tempoWording("Medium Swing J = 100") == "Medium Swing")
    #expect(LocalTextReader.tempoWording("A Bright = 120") == "Bright")
    #expect(LocalTextReader.tempoWording("AMedium Swing") == "Medium Swing")
    #expect(LocalTextReader.tempoWording("J. = 60") == "")
    #expect(LocalTextReader.isTempoWords("Med. Up Swing"))
    #expect(!LocalTextReader.isTempoWords("Vamp till cue"))
  }

  @Test func lyricsAndNamesAreToldApart() {
    #expect(LocalTextReader.lyricLike("nev-er"))
    #expect(LocalTextReader.lyricLike("I've walked for miles;_"))
    #expect(LocalTextReader.lyricLike("your"))
    #expect(!LocalTextReader.lyricLike("Till cue"))
    #expect(!LocalTextReader.lyricLike("to end"))
    #expect(!LocalTextReader.lyricLike("(play lower notes on repeat only)"))
    #expect(LocalTextReader.nameLike("CHICK COREA"))
    #expect(LocalTextReader.nameLike("Paul Weston"))
    #expect(!LocalTextReader.nameLike("(dr.) break"))
    #expect(!LocalTextReader.nameLike("Engvick"))
  }

  private func line(_ text: String, _ box: (Int, Int, Int, Int)) -> LocalTextReader.Phrase {
    var p = LocalTextReader.Phrase(box: LocalTextReader.Box(x0: box.0, y0: box.1, x1: box.2, y1: box.3))
    p.text = text
    p.score = 0.98
    return p
  }

  @Test func theHeaderIsSortedIntoTitleComposerAndTempo() {
    // a New Real Book header, 1275 px wide, staff space 11.5 px
    let found = LocalTextReader.headerMetadata([
      line("419", (35, 51, 69, 68)),
      line("Music: Alec Wilder", (1006, 92, 1218, 112)),
      line("While We're Young", (392, 112, 934, 176)),
      line("and Morty Palitz", (1032, 123, 1218, 158)),
      line("Lyric: William", (1060, 153, 1217, 179)),
      line("Medium Waltz", (73, 181, 301, 211)),
      line("Engvick", (1129, 183, 1218, 209)),
    ], pageWidth: 1275, sp: 11.5)
    let m = found.metadata
    #expect(m?.title == "While We're Young")
    #expect(m?.composer == "Alec Wilder and Morty Palitz")
    #expect(m?.tempoText == "Medium Waltz")
    #expect(found.used.count == 6)   // all but the page number
    // a page that continues a chart: small text over the first line is no title
    let none = LocalTextReader.headerMetadata([line("(dr.) break", (954, 75, 1218, 104))], pageWidth: 1275, sp: 11.5)
    #expect(none.metadata?.title ?? "" == "")
  }
}
