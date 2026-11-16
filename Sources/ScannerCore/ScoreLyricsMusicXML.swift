import Foundation

/// Writes read lyrics into a page's MusicXML: each syllable as a `<lyric>` on the note the scanner gave its id.
/// A syllable placed on a chord's upper note goes to the chord's first note, where MusicXML keeps lyrics; a note
/// keeps the first syllable of each verse it is given.
enum ScoreLyricsMusicXML {
  static func inserting(_ lyrics: [ScoreLyric], into xml: Data) throws -> Data {
    guard !lyrics.isEmpty else { return xml }
    let root = try XMLNode.parse(xml)
    var notes: [String: (note: XMLNode, measure: XMLNode)] = [:]
    for part in root.all("part") {
      for m in part.all("measure") {
        for n in m.all("note") { if let id = n.attributes["id"] { notes[id] = (n, m) } }
      }
    }
    for l in lyrics {
      guard let found = notes[l.noteID] else { continue }
      var note = found.note
      let measure = found.measure
      if note.first("chord") != nil, let at = measure.children.firstIndex(where: { $0 === note }) {
        // back to the chord's first note
        if let head = measure.children[..<at].last(where: { $0.tag == "note" && $0.first("chord") == nil }) {
          note = head
        }
      }
      guard !note.all("lyric").contains(where: { $0.attributes["number"] == "\(l.verse)" }) else { continue }
      var children = [XMLNode("syllabic", text: l.syllabic), XMLNode("text", text: l.text)]
      if l.extend { children.append(XMLNode("extend")) }
      let lyric = XMLNode("lyric", attributes: ["number": "\(l.verse)"], children: children)
      // MusicXML order: ... notations, lyric, play, listen
      let later: Set<String> = ["play", "listen"]
      let at = note.children.firstIndex { later.contains($0.tag) } ?? note.children.count
      note.children.insert(lyric, at: at)
    }
    return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()).utf8)
  }
}
