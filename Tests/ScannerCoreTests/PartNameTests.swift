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
}
