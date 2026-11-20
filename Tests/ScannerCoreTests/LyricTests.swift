import Foundation
import Testing

@testable import ScannerCore

/// Lyrics read under the staves: which words count, how they are tidied, and how they are written onto notes.
struct LyricTests {
  @Test func sungWordsAndOtherText() {
    #expect(LocalTextReader.lyricWord("love"))
    #expect(LocalTextReader.lyricWord("up"))         // tempo words are lyric words too
    #expect(LocalTextReader.lyricWord("fast,"))
    #expect(LocalTextReader.lyricWord("I"))
    #expect(LocalTextReader.lyricWord("a"))
    #expect(LocalTextReader.lyricWord("e", syllable: true))   // e-nough
    #expect(!LocalTextReader.lyricWord("e"))
    #expect(!LocalTextReader.lyricWord("(solo bass)"))
    #expect(!LocalTextReader.lyricWord("SOLOS"))
    #expect(!LocalTextReader.lyricWord("Fine"))
    #expect(!LocalTextReader.lyricWord("D-7"))
    #expect(!LocalTextReader.lyricWord("F#sus"))
    #expect(!LocalTextReader.lyricWord("Bb"))
    #expect(LocalTextReader.lyricWord("Am"))   // a word as well as a chord
    #expect(LocalTextReader.lyricWord("E", syllable: true))   // E-del-weiss: a syllable, not the chord E
    #expect(!LocalTextReader.lyricWord("Bm7", syllable: true))   // "Bm7 - E7" is a chord line
    #expect(!LocalTextReader.lyricWord("Bb", syllable: true))
  }

  /// A line of five letters from x = 0, with its top at `top`, `height` tall.
  static func line(top: Int, height: Int = 25) -> [LyricFinder.Piece] {
    (0..<5).map { LyricFinder.Piece(x0: 40 * $0, y0: top, x1: 40 * $0 + 20, y1: top + height) }
  }

  @Test func aHymnsVersesAreFollowedPastTheUsualDepth() {
    // three verses 35 px apart; the usual band ends at 360, through the third
    let verses = [Self.line(top: 280), Self.line(top: 315), Self.line(top: 350)]
    #expect(LyricFinder.stackedLines(verses, from: 360)?.count == 3)
    // a fourth verse at the same spacing, wholly below
    #expect(LyricFinder.stackedLines(verses + [Self.line(top: 385)], from: 360)?.count == 4)
    // nothing reaches below: the usual band is kept as it was
    #expect(LyricFinder.stackedLines(verses, from: 400) == nil)
    // a line further off (a footer, the next line's title) or of another size is not a verse
    #expect(LyricFinder.stackedLines(verses.dropLast() + [Self.line(top: 380)], from: 360) == nil)
    #expect(LyricFinder.stackedLines(verses.dropLast() + [Self.line(top: 350, height: 40)], from: 360) == nil)
    // one line alone sets no spacing
    #expect(LyricFinder.stackedLines([Self.line(top: 280), Self.line(top: 350)], from: 300) == nil)
    // the stack stops at the first line off its spacing
    #expect(LyricFinder.stackedLines(verses + [Self.line(top: 430)], from: 360)?.count == 3)
  }

  @Test func readingsAreTidied() {
    #expect(LocalTextReader.lyricText("-light", height: 30, tallest: 32) == "light")
    #expect(LocalTextReader.lyricText("smiles_", height: 30, tallest: 32) == "smiles")
    #expect(LocalTextReader.lyricText("0", height: 22, tallest: 32) == "o")
    // letters alike in both cases, no taller than the small letters: lower case
    #expect(LocalTextReader.lyricText("SO", height: 22, tallest: 32) == "so")
    // in an all-capitals line they stand as tall as the rest and stay capitals
    #expect(LocalTextReader.lyricText("SO", height: 31, tallest: 32) == "SO")
    #expect(LocalTextReader.lyricText("SEE", height: 22, tallest: 32) == "SEE")
  }

  @Test func syllablesGoOnTheirNotes() throws {
    let xml = Data("""
      <score-partwise><part-list><score-part id="P1"><part-name>V</part-name></score-part></part-list>
      <part id="P1"><measure number="1">
      <note id="s1"><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
      <note id="s2"><chord/><pitch><step>E</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type></note>
      <note id="s3"><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><type>quarter</type><play/></note>
      </measure></part></score-partwise>
      """.utf8)
    let lyrics = [
      ScoreLyric(noteID: "s2", verse: 1, text: "hap", syllabic: "begin", extend: false),
      ScoreLyric(noteID: "s3", verse: 1, text: "py", syllabic: "end", extend: true),
      ScoreLyric(noteID: "s3", verse: 2, text: "day", syllabic: "single", extend: false),
      ScoreLyric(noteID: "s9", verse: 1, text: "lost", syllabic: "single", extend: false),
    ]
    let notes = try XMLNode.parse(ScoreLyricsMusicXML.inserting(lyrics, into: xml)).first("part")!.first("measure")!
      .all("note")
    // a syllable on a chord's upper note goes to the chord's first note
    #expect(notes[0].first("lyric")?.first("text")?.text == "hap")
    #expect(notes[1].first("lyric") == nil)
    // verses in order, the extender kept, and before <play>
    #expect(notes[2].all("lyric").map { $0.attributes["number"] ?? "" } == ["1", "2"])
    #expect(notes[2].all("lyric").first?.first("extend") != nil)
    #expect(notes[2].children.last?.tag == "play")
  }
}
