import Foundation

/// A simple printed meter supported by the native repair and chord writers.
public struct ScoreTimeSignature: Codable, Sendable, Equatable {
  public let beats: Int
  public let beatType: Int

  public init(beats: Int, beatType: Int) {
    self.beats = beats
    self.beatType = beatType
  }

  public var isSupported: Bool {
    (1...32).contains(beats) && [1, 2, 4, 8, 16, 32].contains(beatType)
  }

  public var label: String { "\(beats)/\(beatType)" }
}

/// Replaces the opening meter in every part of a raw score, before timing
/// repair or chord placement. Later printed meter changes remain untouched.
public enum ScoreTimeSignatureMusicXML {
  public static func replacingInitialMeter(
    _ meter: ScoreTimeSignature, in rawXML: Data
  ) throws -> Data {
    guard meter.isSupported else { return rawXML }
    let root = try XMLNode.parse(rawXML)
    guard root.tag == "score-partwise" else {
      throw ScannerError.invalid("Expected a score-partwise MusicXML document")
    }
    for part in root.all("part") {
      guard let first = part.first("measure") else { continue }
      let attributes = first.all("attributes")
      let target: XMLNode
      if let existing = attributes.first(where: { $0.first("time") != nil }) {
        target = existing
      } else if let existing = attributes.first {
        target = existing
      } else {
        target = XMLNode("attributes")
        let index = first.children.firstIndex { $0.tag != "print" && $0.tag != "barline" }
          ?? first.children.count
        first.children.insert(target, at: index)
      }
      for node in attributes { node.children.removeAll { $0.tag == "time" } }
      let time = XMLNode("time", children: [
        XMLNode("beats", text: String(meter.beats)),
        XMLNode("beat-type", text: String(meter.beatType)),
      ])
      let index = target.children.firstIndex {
        ["staves", "part-symbol", "instruments", "clef", "staff-details", "transpose"]
          .contains($0.tag)
      } ?? target.children.count
      target.children.insert(time, at: index)
    }
    return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()).utf8)
  }
}
