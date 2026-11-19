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
