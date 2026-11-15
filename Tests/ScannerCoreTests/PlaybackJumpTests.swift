import Foundation
import Testing

@testable import ScannerCore

/// The `<sound>` jumps written for printed navigation (`ScoreMetadataMusicXML.insertPlaybackJumps`). Aria's engine
/// imports them as jumps and markers (checked with desktop MuseScore playing Aria's saved files: D.S. al Coda plays
/// 1 2 3 4 5 6 2 3 4 7 8).
struct PlaybackJumpTests {
  /// Eight one-note bars with the given directions: "segno" and "coda" are signs, anything else words.
  private func score(_ marks: [Int: [String]]) throws -> ScannerCore.XMLNode {
    var measures = ""
    for i in 1...8 {
      let directions = (marks[i] ?? []).map { m -> String in
        let type = m == "segno" ? "<segno/>" : m == "coda" ? "<coda/>" : "<words>\(m)</words>"
        return "<direction placement=\"above\"><direction-type>\(type)</direction-type><staff>1</staff></direction>"
      }.joined()
      measures += "<measure number=\"\(i)\">\(directions)<note><pitch><step>C</step><octave>4</octave></pitch>"
        + "<duration>4</duration><type>whole</type></note></measure>"
    }
    let root = try ScannerCore.XMLNode.parse(Data("<score-partwise><part id=\"P1\">\(measures)</part></score-partwise>".utf8))
    ScoreMetadataMusicXML.insertPlaybackJumps(into: root)
    return root
  }

  /// "bar: attribute=value" for every sound, in bar order.
  private func sounds(_ root: ScannerCore.XMLNode) -> [String] {
    root.first("part")!.all("measure").enumerated().flatMap { index, measure in
      measure.all("direction").compactMap { d in
        d.first("sound").map { s in "\(index + 1): " + s.attributes.map { "\($0.key)=\($0.value)" }.sorted().joined() }
      }
    }
  }

  @Test func dalSegnoAlCodaGetsItsJumpAndMarkers() throws {
    let root = try score([2: ["segno"], 4: ["To Coda"], 6: ["D.S. al Coda"], 7: ["coda", "Coda"]])
    #expect(sounds(root) == ["2: segno=segno", "4: tocoda=coda", "6: dalsegno=segno", "7: coda=coda"])
    // the jump is written at the end of its bar, after the note
    let bar6 = root.first("part")!.all("measure")[5]
    #expect(bar6.children.map(\.tag) == ["note", "direction"])
  }

  @Test func daCapoAlFineNeedsOnlyItsFine() throws {
    #expect(sounds(try score([4: ["Fine"], 8: ["D.C. al Fine"]])) == ["4: fine=yes", "8: dacapo=yes"])
    // a plain D.C. needs nothing
    #expect(sounds(try score([8: ["D.C."]])) == ["8: dacapo=yes"])
  }

  @Test func missingOrDoubledTargetsStayWordsOnly() throws {
    #expect(sounds(try score([2: ["segno"], 5: ["segno"], 6: ["D.S."]])).isEmpty)
    #expect(sounds(try score([4: ["To Coda"], 6: ["D.S. al Coda"], 7: ["coda"]])).isEmpty)
    // al Coda with no To Coda: the jump would not know where to leave
    #expect(sounds(try score([2: ["segno"], 6: ["D.S. al Coda"], 7: ["coda"]])).isEmpty)
    // D.C. al Fine with no Fine
    #expect(sounds(try score([8: ["D.C. al Fine"]])).isEmpty)
    // "D.S. al ⊕" read as a plain D.S.: the coda sign says it was not meant to play to the end
    #expect(sounds(try score([2: ["segno"], 6: ["D.S.", "coda"]])).isEmpty)
    #expect(sounds(try score([4: ["Fine"], 8: ["D.C."]])).isEmpty)
    // with no coda and no Fine anywhere, a plain D.S. plays to the end
    #expect(sounds(try score([2: ["segno"], 6: ["D.S."]])) == ["2: segno=segno", "6: dalsegno=segno"])
  }

  @Test func aSignBesideItsOwnWordsIsNotASecondTarget() throws {
    // "To Coda ⊕" in bar 4 and the coda itself in bar 7
    let root = try score([2: ["segno"], 4: ["To Coda", "coda"], 6: ["D.S. al Coda"], 7: ["coda"]])
    #expect(sounds(root).contains("6: dalsegno=segno"))
    #expect(sounds(root).contains("7: coda=coda"))
  }
}
