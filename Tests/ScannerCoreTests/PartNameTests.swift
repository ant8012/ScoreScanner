import Foundation
import Testing

@testable import ScannerCore

/// Part names read from the margin beside the first systems, written in place of the hidden "Part n" names.
struct PartNameTests {
  private func score(parts: Int) -> DocumentScanResult {
    let list = (1...parts).map { #"<score-part id="P\#($0)"><part-name print-object="no">Part \#($0)</part-name></score-part>"# }
    let body = (1...parts).map { #"<part id="P\#($0)"><measure number="1"><note><duration>4</duration></note></measure></part>"# }
    let xml = Data("<score-partwise><part-list>\(list.joined())</part-list>\(body.joined())</score-partwise>".utf8)
    return DocumentScanResult(xml: xml, rawXML: xml, seconds: 1, staffCount: parts, repairedMeasures: 0, pageCount: 1)
  }

  /// Parts whose first bars carry these key signatures (in fifths).
  private func score(keys: [Int]) -> DocumentScanResult {
    let list = keys.indices.map { #"<score-part id="P\#($0 + 1)"><part-name print-object="no">Part \#($0 + 1)</part-name></score-part>"# }
    let body = keys.enumerated().map { k, f in
      #"<part id="P\#(k + 1)"><measure number="1"><attributes><key><fifths>\#(f)</fifths></key></attributes><note><duration>4</duration></note></measure></part>"#
    }
    let xml = Data("<score-partwise><part-list>\(list.joined())</part-list>\(body.joined())</score-partwise>".utf8)
    return DocumentScanResult(xml: xml, rawXML: xml, seconds: 1, staffCount: keys.count, repairedMeasures: 0, pageCount: 1)
  }

  private func transposes(_ names: [String], keys: [Int]) throws -> [String?] {
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: nil, composer: nil, arranger: nil, partNames: names, partAbbreviations: [], staffText: [],
      into: score(keys: keys))
    return try XMLNode.parse(result.xml).all("part").map {
      $0.first("measure")?.first("attributes")?.first("transpose")?.first("chromatic")?.text
    }
  }

  private func written(_ result: DocumentScanResult) throws -> [(name: String, shown: Bool, short: String?)] {
    try XMLNode.parse(result.xml).first("part-list")!.all("score-part").map { p in
      let n = p.first("part-name")!
      return (n.text, n.attributes["print-object"] == nil, p.first("part-abbreviation")?.text)
    }
  }

  @Test func namesAndShortNamesReplaceThePlaceholders() throws {
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: nil, composer: nil, arranger: nil, partNames: ["Violin I", "", "Viola"],
      partAbbreviations: ["Vln. I", "Vln. II", "Vla."], staffText: [], into: score(parts: 3))
    let parts = try written(result)
    #expect(parts[0].name == "Violin I" && parts[0].shown && parts[0].short == "Vln. I")
    // a name not read keeps the hidden placeholder, and gets no short name either
    #expect(parts[1].name == "Part 2" && !parts[1].shown && parts[1].short == nil)
    #expect(parts[2].name == "Viola" && parts[2].short == "Vla.")
  }

  @Test func namesThatDoNotMatchThePartsAreNotWritten() throws {
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: nil, composer: nil, arranger: nil, partNames: ["Violin", "Piano"], staffText: [],
      into: score(parts: 3))
    #expect(try written(result).allSatisfy { !$0.shown })
  }

  @Test func transposingKeysAreSpelledWithFlatsAndSharps() {
    #expect(LocalTextReader.instrumentName("Clarinet in Bb") == "Clarinet in B♭")
    #expect(LocalTextReader.instrumentName("Trumpet in C#") == "Trumpet in C♯")
    #expect(LocalTextReader.instrumentName("Cb.") == "Cb.")
    #expect(LocalTextReader.instrumentName("Horn in F") == "Horn in F")
  }

  @Test func trailingPartNumbersAreDropped() {
    #expect(InstrumentSounds.base("Violin II") == "Violin")
    #expect(InstrumentSounds.base("Trumpet 2") == "Trumpet")
    #expect(InstrumentSounds.base("2nd Violin") == "Violin")
    #expect(InstrumentSounds.base("Vln. I") == "Vln.")
    // nothing else is cut, and a lone word is kept
    #expect(InstrumentSounds.base("Clarinet in B♭") == "Clarinet in B♭")
    #expect(InstrumentSounds.base("V.") == "V.")
  }

  @Test func namesMatchTheirInstrumentExactly() {
    #expect(InstrumentSounds.match(long: "Violin I", short: "")?.sound == "strings.violin")
    #expect(InstrumentSounds.match(long: "Violoncello", short: "")?.sound == "strings.cello")
    #expect(InstrumentSounds.match(long: "Contrabass", short: "")?.sound == "strings.contrabass")
    // the short name when no long one was read
    #expect(InstrumentSounds.match(long: "", short: "Vla.")?.sound == "strings.viola")
    // not in the table, or only part of a name: no guess
    #expect(InstrumentSounds.match(long: "Violin obbligato", short: "") == nil)
    #expect(InstrumentSounds.match(long: "Melody", short: "") == nil)
  }

  @Test func keysArePrintedBeforeTransposing() {
    let clarinet = InstrumentSounds.match(long: "Clarinet in B♭", short: "")
    #expect(clarinet?.sound == "wind.reed.clarinet.bflat")
    #expect(clarinet?.transpose?.chromatic == -2 && clarinet?.transpose?.diatonic == -1)
    #expect(InstrumentSounds.match(long: "Horn in F", short: "")?.transpose?.chromatic == -7)
    // no key printed: the instrument's sound, played as written
    let plain = InstrumentSounds.match(long: "Clarinet", short: "")
    #expect(plain?.sound == "wind.reed.clarinet" && plain?.transpose == nil)
  }

  @Test func bassFollowsTheParts() {
    #expect(InstrumentSounds.match(long: "Bass", short: "", others: ["Soprano", "Alto", "Tenor"])?.sound == "voice.bass")
    #expect(InstrumentSounds.match(long: "Bass", short: "", others: ["Violin", "Viola"])?.sound == "strings.contrabass")
    #expect(InstrumentSounds.match(long: "Bass", short: "", others: ["Piano"]) == nil)
  }

  @Test func theInstrumentAndItsTranspositionAreWritten() throws {
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: nil, composer: nil, arranger: nil, partNames: ["Violin I", "Clarinet in B♭", "Melody"],
      partAbbreviations: ["Vln. I", "Cl.", ""], staffText: [], into: score(parts: 3))
    let root = try XMLNode.parse(result.xml)
    let parts = root.first("part-list")!.all("score-part")
    #expect(parts[0].children.map(\.tag) == ["part-name", "part-abbreviation", "score-instrument"])
    #expect(parts[0].first("score-instrument")?.first("instrument-sound")?.text == "strings.violin")
    #expect(parts[0].first("score-instrument")?.first("instrument-name")?.text == "Violin")
    #expect(parts[1].first("score-instrument")?.first("instrument-sound")?.text == "wind.reed.clarinet.bflat")
    #expect(parts[2].first("score-instrument") == nil)
    let transposes = root.all("part").map { $0.first("measure")?.first("attributes")?.first("transpose") }
    #expect(transposes[0] == nil && transposes[2] == nil)
    #expect(transposes[1]?.first("chromatic")?.text == "-2")
  }

  @Test func aBigBandScoreTransposesByItsKeySignatures() throws {
    // Ab major at concert pitch: altos and bari in F (E♭ instruments), tenors and trumpets in B♭
    let t = try transposes(["Altsax 1", "Tensax 1", "Bar sax", "Tpt 1", "Tbn 1", "Piano", "Bass", "Drum Kit"],
                           keys: [-1, -2, -1, -2, -4, -4, -4, -4])
    #expect(t == ["-9", "-14", "-21", "-2", nil, nil, nil, nil])
  }

  @Test func aScoreAtConcertPitchIsPlayedAsWritten() throws {
    // every part in the same key: printed at concert pitch, whatever the names say
    let t = try transposes(["Alto Sax", "Clarinet in B♭", "Piano"], keys: [-4, -4, -4])
    #expect(t == [nil, nil, nil])
  }

  @Test func keySignaturesSayNothingWithoutSharpsOrFlats() throws {
    // no key signatures anywhere: a printed key still counts, a saxophone is in its usual key, a plain trumpet stays
    let t = try transposes(["Clarinet in B♭", "Alto Saxophone", "Trumpet", "Violin"], keys: [0, 0, 0, 0])
    #expect(t == ["-2", "-9", nil, nil])
    // a saxophone part on its own
    #expect(try transposes(["Alto Sax"], keys: [2]) == ["-9"])
    // a clarinet a minor third below the strings is in A
    #expect(try transposes(["Clarinet", "Violin"], keys: [-3, 0]) == ["-3", nil])
  }
}
