import Foundation

/// One recognized text item anchored to HOMR's native system/bar geometry.
public struct ScoreTextDirection: Sendable {
  public let voice: Int
  public let system: Int
  public let bar: Int
  public let barCount: Int
  public let text: String
  public let category: String

  public init(
    voice: Int, system: Int, bar: Int, barCount: Int,
    text: String, category: String
  ) {
    self.voice = voice
    self.system = system
    self.bar = bar
    self.barCount = barCount
    self.text = text
    self.category = category
  }
}

/// Tempo recognized in the page-one header.
public struct ScoreHeaderTempo: Sendable {
  public let text: String
  public let beatUnit: String
  public let bpm: Int

  public init(text: String, beatUnit: String, bpm: Int) {
    self.text = text
    self.beatUnit = beatUnit
    self.bpm = bpm
  }
}

/// Adds recognized metadata and staff text with standard MusicXML elements,
/// without modifying notes, rhythms, chord harmonies, or repair decisions.
public enum ScoreMetadataMusicXML {
  private struct SystemKey: Hashable { let voice: Int; let system: Int }
  private struct MeasureKey: Hashable { let part: String; let number: String }
  private struct MappedDirection {
    let part: String
    let measure: String
    let text: String
    let category: String
  }
  private struct Page { let width: Double; let height: Double; let margin: Double }

  /// Uses the detected title only when the score does not already have one, so
  /// an explicit title entered by the user always wins.
  public static func insertingDetectedTitle(
    _ detectedTitle: String?, into result: DocumentScanResult
  ) throws -> DocumentScanResult {
    try insertingRecognizedContent(
      title: detectedTitle, composer: nil, arranger: nil, staffText: [], into: result)
  }

  /// Writes metadata both semantically (`work-title`/`creator`) and as positioned
  /// page-one credits, writes header tempo as a first-measure metronome mark, and
  /// writes staff text as measure-attached directions. Locations are accepted
  /// only when the native system's bar count matches MusicXML.
  /// `partNames`: the instrument names printed beside the first system, in order; used only when there is one
  /// for every part, in place of the reader's unprinted "Part n" placeholders.
  public static func insertingRecognizedContent(
    title: String?, composer: String?, arranger: String?, tempo: ScoreHeaderTempo? = nil,
    partNames: [String] = [], staffText: [ScoreTextDirection], into result: DocumentScanResult
  ) throws -> DocumentScanResult {
    let mapped = try mappedDirections(
      staffText.filter { !repeatsHeaderTempo($0, tempo) }, score: result.xml)
    func write(_ data: Data) throws -> Data {
      try inserting(
        title: title, composer: composer, arranger: arranger, tempo: tempo, partNames: partNames,
        directions: mapped, into: data)
    }
    return DocumentScanResult(
      xml: try write(result.xml), rawXML: try write(result.rawXML),
      seconds: result.seconds, staffCount: result.staffCount,
      repairedMeasures: result.repairedMeasures, pageCount: result.pageCount)
  }

  private static func mappedDirections(
    _ directions: [ScoreTextDirection], score: Data
  ) throws -> [MappedDirection] {
    let usable = directions.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isNumberOnly($0.text) && $0.barCount > 0
        && $0.bar >= 0 && $0.bar < $0.barCount
    }
    let groups = Dictionary(grouping: usable) { SystemKey(voice: $0.voice, system: $0.system) }
    var staffs = groups.map { key, values in
      let barCount = values.map(\.barCount).max() ?? 0
      return ChordStaff(
        staff: 0, voice: key.voice, system: key.system, top: 0, bottom: 0,
        bars: (0..<barCount).map {
          ChordBar(index: $0, left: Double($0), right: Double($0 + 1), text: "", labels: [])
        }, mappingStatus: "unresolved")
    }
    try ChordMusicXML.map(&staffs, score: score)
    let mappedSystems = Dictionary(
      uniqueKeysWithValues: staffs.compactMap { staff -> (SystemKey, ChordStaff)? in
        guard let voice = staff.voice, let system = staff.system else { return nil }
        return (SystemKey(voice: voice, system: system), staff)
      })
    return usable.compactMap { value in
      let key = SystemKey(voice: value.voice, system: value.system)
      guard let staff = mappedSystems[key], staff.bars.indices.contains(value.bar),
        let part = staff.bars[value.bar].partID,
        let measure = staff.bars[value.bar].measureNumber
      else { return nil }
      return MappedDirection(
        part: part, measure: measure,
        text: value.text.trimmingCharacters(in: .whitespacesAndNewlines),
        category: value.category)
    }
  }

  private static func inserting(
    title: String?, composer: String?, arranger: String?, tempo: ScoreHeaderTempo?, partNames: [String] = [],
    directions: [MappedDirection], into data: Data
  ) throws -> Data {
    let root = try XMLNode.parse(data)
    guard root.tag == "score-partwise" else {
      throw ScannerError.invalid("Expected a score-partwise MusicXML document")
    }
    let title = cleaned(title), composer = cleaned(composer), arranger = cleaned(arranger)
    if let title { insertTitle(title, into: root) }
    if let composer { insertCreator(composer, type: "composer", into: root) }
    if let arranger { insertCreator(arranger, type: "arranger", into: root) }
    if title != nil || composer != nil || arranger != nil { insertCredits(into: root) }
    insertPartNames(partNames, into: root)
    insertTempo(tempo, into: root)
    insertDirections(directions, into: root)
    insertPlaybackJumps(into: root)
    return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()).utf8)
  }

  private static func insertPartNames(_ names: [String], into root: XMLNode) {
    let names = names.compactMap { cleaned($0) }
    let parts = root.first("part-list")?.all("score-part") ?? []
    guard !names.isEmpty, names.count == parts.count else { return }
    for (part, name) in zip(parts, names) {
      guard let partName = part.first("part-name") else { continue }
      partName.text = name
      partName.attributes["print-object"] = nil
    }
  }

  private static func insertTitle(_ title: String, into root: XMLNode) {
    let work: XMLNode
    if let existing = root.first("work") {
      work = existing
    } else {
      work = XMLNode("work")
      root.children.insert(work, at: 0)
    }
    if let existing = work.first("work-title") {
      guard existing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      existing.text = title
    } else {
      work.children.insert(XMLNode("work-title", text: title), at: 0)
    }
  }

  private static func insertCreator(_ name: String, type: String, into root: XMLNode) {
    let identification: XMLNode
    if let existing = root.first("identification") {
      identification = existing
    } else {
      identification = XMLNode("identification")
      let index = root.children.firstIndex { $0.tag == "defaults" || $0.tag == "part-list" }
        ?? root.children.count
      root.children.insert(identification, at: index)
    }
    let existing = identification.all("creator").first { $0.attributes["type"] == type }
    guard existing?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
      return
    }
    if let existing { existing.text = name }
    else {
      identification.children.insert(
        XMLNode("creator", text: name, attributes: ["type": type]), at: 0)
    }
  }

  /// MuseScore builds its own title frame only when a file has no credits, and
  /// sorts credits into header or footer by `default-y` against the page height.
  /// Unpositioned credits therefore land after the last measure, so every credit
  /// is written from the final title/creators at a real page position.
  private static func insertCredits(into root: XMLNode) {
    guard root.all("credit").isEmpty else { return }
    let title = cleaned(root.first("work")?.first("work-title")?.text)
    let creators = root.first("identification")?.all("creator") ?? []
    let names = ["composer", "arranger"].compactMap { type -> (String, String)? in
      cleaned(creators.first { $0.attributes["type"] == type }?.text).map { (type, $0) }
    }
    guard title != nil || !names.isEmpty else { return }
    let page = pageLayout(in: root)
    let top = page.height - page.margin
    var credits: [XMLNode] = []
    if let title {
      credits.append(
        credit(title, type: "title", x: page.width / 2, y: top, justify: "center", fontSize: 22))
    }
    for (index, (type, name)) in names.enumerated() {
      credits.append(
        credit(
          name, type: type, x: page.width - page.margin, y: top - 90 - Double(index * 30),
          justify: "right", fontSize: 10))
    }
    let index = root.children.firstIndex { $0.tag == "part-list" } ?? root.children.count
    root.children.insert(contentsOf: credits, at: index)
  }

  private static func credit(
    _ text: String, type: String, x: Double, y: Double, justify: String, fontSize: Double
  ) -> XMLNode {
    XMLNode(
      "credit", attributes: ["page": "1"],
      children: [
        XMLNode("credit-type", text: type),
        XMLNode(
          "credit-words", text: text,
          attributes: [
            "default-x": number(x), "default-y": number(y), "justify": justify,
            "valign": "top", "font-size": number(fontSize),
          ]),
      ])
  }

  /// Returns the page size in tenths, adding MuseScore's default US Letter layout
  /// with 15 mm margins when the score (like HOMR output) has none.
  private static func pageLayout(in root: XMLNode) -> Page {
    let defaults: XMLNode
    if let existing = root.first("defaults") {
      defaults = existing
    } else {
      defaults = XMLNode("defaults")
      let index = root.children.firstIndex { $0.tag == "credit" || $0.tag == "part-list" }
        ?? root.children.count
      root.children.insert(defaults, at: index)
    }
    let scaling: XMLNode
    if let existing = defaults.first("scaling") {
      scaling = existing
    } else {
      scaling = XMLNode(
        "scaling",
        children: [XMLNode("millimeters", text: "7.05556"), XMLNode("tenths", text: "40")])
      defaults.children.insert(scaling, at: 0)
    }
    let tenthsPerMillimeter =
      (Double(scaling.first("tenths")?.text ?? "") ?? 40)
      / (Double(scaling.first("millimeters")?.text ?? "") ?? 7.05556)
    let margin = (15 * tenthsPerMillimeter).rounded()
    if let layout = defaults.first("page-layout"),
      let height = Double(layout.first("page-height")?.text ?? ""),
      let width = Double(layout.first("page-width")?.text ?? "")
    {
      return Page(width: width, height: height, margin: margin)
    }
    let width = (215.9 * tenthsPerMillimeter).rounded()
    let height = (279.4 * tenthsPerMillimeter).rounded()
    let margins = XMLNode(
      "page-margins", attributes: ["type": "both"],
      children: ["left", "right", "top", "bottom"].map {
        XMLNode("\($0)-margin", text: number(margin))
      })
    defaults.children.removeAll { $0.tag == "page-layout" }
    let index = (defaults.children.lastIndex { $0.tag == "scaling" || $0.tag == "concert-score" }
      ?? -1) + 1
    defaults.children.insert(
      XMLNode(
        "page-layout",
        children: [
          XMLNode("page-height", text: number(height)),
          XMLNode("page-width", text: number(width)), margins,
        ]), at: index)
    return Page(width: width, height: height, margin: margin)
  }

  private struct BeatUnit {
    let type: String
    let dotted: Bool

    var quarters: Double {
      let bases: [String: Double] = ["whole": 4, "half": 2, "quarter": 1, "eighth": 0.5, "16th": 0.25]
      return (bases[type] ?? 1) * (dotted ? 1.5 : 1)
    }
  }

  private static let metronomePattern = #"\(?\s*\S*\s*=\s*(c(a)?\.?\s*)?\d+(\s*bpm)?\s*\)?"#

  /// Writes header tempo in the first measure: tempo wording as `words`, a
  /// metronome mark as `metronome`, and playback tempo as `sound`.
  private static func insertTempo(_ tempo: ScoreHeaderTempo?, into root: XMLNode) {
    guard let tempo, let measure = root.first("part")?.first("measure") else { return }
    let bpm = resolvedBPM(tempo)
    let words = tempoWords(tempo)
    guard bpm != nil || words != nil else { return }
    var children: [XMLNode] = []
    if let words {
      children.append(XMLNode("direction-type", children: [XMLNode("words", text: words)]))
    }
    if let bpm {
      let unit = beatUnit(tempo)
      var metronome = [XMLNode("beat-unit", text: unit.type)]
      if unit.dotted { metronome.append(XMLNode("beat-unit-dot")) }
      metronome.append(XMLNode("per-minute", text: String(bpm)))
      children.append(
        XMLNode("direction-type", children: [XMLNode("metronome", children: metronome)]))
      children.append(XMLNode("staff", text: "1"))
      children.append(
        XMLNode("sound", attributes: ["tempo": number(Double(bpm) * unit.quarters)]))
    } else {
      children.append(XMLNode("staff", text: "1"))
    }
    measure.children.insert(
      XMLNode("direction", attributes: ["placement": "above"], children: children),
      at: directionIndex(in: measure))
  }

  private static func resolvedBPM(_ tempo: ScoreHeaderTempo) -> Int? {
    if tempo.bpm > 0 { return tempo.bpm }
    guard let range = tempo.text.range(of: metronomePattern, options: .regularExpression),
      let digits = tempo.text[range].split(whereSeparator: { !$0.isNumber }).last,
      let value = Int(digits), value > 0
    else { return nil }
    return value
  }

  /// Keeps header wording only when it reads like a tempo or style marking;
  /// section labels and cues such as "Piano Intro" belong to staff text.
  private static func tempoWords(_ tempo: ScoreHeaderTempo) -> String? {
    guard let words = cleaned(withoutMetronome(tempo.text)) else { return nil }
    let cues: Set<String> = [
      "intro", "outro", "verse", "chorus", "bridge", "interlude", "vamp", "tag", "ending",
      "solo", "solos", "enters", "tacet", "coda", "fine", "segno", "d.c.", "d.s.", "section",
      "piano", "bass", "drums", "guitar", "vocal", "vocals", "voice", "horns", "strings",
      "sax", "trumpet", "trombone",
    ]
    let tokens = words.lowercased().split { !$0.isLetter && $0 != "." }.map(String.init)
    return tokens.contains(where: cues.contains) ? nil : words
  }

  /// Uses the note printed before "=" when the text has one, then the model's
  /// beat-unit reading, and otherwise assumes a quarter note.
  private static func beatUnit(_ tempo: ScoreHeaderTempo) -> BeatUnit {
    printedBeatUnit(tempo.text) ?? namedBeatUnit(tempo.beatUnit)
      ?? BeatUnit(type: "quarter", dotted: false)
  }

  private static func printedBeatUnit(_ text: String) -> BeatUnit? {
    guard let equals = text.firstIndex(of: "=") else { return nil }
    var before = Array(text[..<equals].reversed()).drop(while: \.isWhitespace)
    let dotted = before.first.map { [".", "·", "\u{1D16D}"].contains($0) } ?? false
    if dotted { before = before.dropFirst().drop(while: \.isWhitespace) }
    guard let note = before.first else { return nil }
    let glyphs: [Character: String] = [
      // Precomposed note symbols compare equal to their decomposed forms.
      "\u{1D15D}": "whole", "\u{1D15E}": "half", "♩": "quarter", "\u{1D15F}": "quarter",
      "♪": "eighth", "\u{1D160}": "eighth", "\u{1D161}": "16th",
    ]
    if let type = glyphs[note] { return BeatUnit(type: type, dotted: dotted) }
    // Music-font letters (q = 80) count only when they stand alone.
    let letters: [Character: String] = [
      "w": "whole", "h": "half", "q": "quarter", "e": "eighth", "s": "16th",
    ]
    let standalone = before.dropFirst().first.map { $0.isWhitespace || $0 == "(" } ?? true
    guard standalone, let type = letters[note] else { return nil }
    return BeatUnit(type: type, dotted: dotted)
  }

  private static func namedBeatUnit(_ value: String) -> BeatUnit? {
    let value = value.lowercased()
    let names = [
      ("sixteenth", "16th"), ("16th", "16th"), ("semiquaver", "16th"), ("whole", "whole"),
      ("semibreve", "whole"), ("half", "half"), ("minim", "half"), ("quarter", "quarter"),
      ("crotchet", "quarter"), ("eighth", "eighth"), ("quaver", "eighth"),
    ]
    guard let type = names.first(where: { value.contains($0.0) })?.1 else { return nil }
    return BeatUnit(type: type, dotted: value.contains("dot"))
  }

  /// Removes a printed "♩ = 120" expression from tempo wording; the metronome
  /// element carries it instead.
  private static func withoutMetronome(_ text: String) -> String {
    text.replacingOccurrences(
      of: metronomePattern, with: " ", options: [.regularExpression, .caseInsensitive]
    ).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
  }

  /// The header crop overlaps the first system, whose staff-text pass can read
  /// the same tempo mark again. Only text matching what was written as tempo is
  /// dropped, so a cue the header reader mistook for tempo stays staff text.
  private static func repeatsHeaderTempo(
    _ value: ScoreTextDirection, _ tempo: ScoreHeaderTempo?
  ) -> Bool {
    guard let tempo, value.system == 0, value.bar == 0 else { return false }
    let text = compact(value.text)
    guard !text.isEmpty else { return false }
    let words = tempoWords(tempo).map(compact)
    if value.text.range(of: metronomePattern, options: .regularExpression) != nil {
      let remainder = compact(withoutMetronome(value.text))
      return resolvedBPM(tempo) != nil && (remainder.isEmpty || remainder == words)
    }
    guard let words else { return false }
    return text == words || (value.category == "tempo" && words.contains(text))
  }

  private static func insertDirections(_ values: [MappedDirection], into root: XMLNode) {
    let grouped = Dictionary(grouping: values) { MeasureKey(part: $0.part, number: $0.measure) }
    for part in root.all("part") {
      guard let partID = part.attributes["id"] else { continue }
      for measure in part.all("measure") {
        guard let number = measure.attributes["number"],
          let values = grouped[MeasureKey(part: partID, number: number)]
        else { continue }
        var seen = Set<String>()
        let nodes = values.compactMap { value -> XMLNode? in
          let key = value.category + "\u{0}" + value.text
          guard seen.insert(key).inserted else { return nil }
          let content = value.category == "rehearsal"
            ? XMLNode("rehearsal", text: value.text)
            : XMLNode("words", text: value.text)
          return XMLNode(
            "direction", attributes: ["placement": "above"],
            children: [
              XMLNode("direction-type", children: [content]),
              XMLNode("staff", text: "1"),
            ])
        }
        measure.children.insert(contentsOf: nodes, at: directionIndex(in: measure))
      }
    }
  }

  /// Adds the standard `<sound>` jump and marker attributes to navigation the score prints, so players follow it:
  /// `segno`/`coda` on the signs, `dalsegno`/`dacapo` on D.S./D.C. (their words, "D.S. al Coda", still say how far),
  /// `tocoda` on To Coda and `fine` on Fine. A jump is written only when its target is unambiguous: one segno at or
  /// before a D.S., and for "al Coda" one To Coda after the jump target and one coda after the jump; for "al Fine"
  /// one Fine; a plain D.S. or D.C. only in a score with no coda and no Fine (where it plays to the end). A sign in
  /// the same bar as its own D.S. or To Coda words is part of them, not a second target.
  /// Anything missing or doubled stays words only: a player can read it, and a wrong jump would play wrong music.
  static func insertPlaybackJumps(into root: XMLNode) {
    enum Kind { case segno, coda, toCoda, fine, dalSegno(String), daCapo(String) }
    struct Mark { let measure: Int; let kind: Kind; let direction: XMLNode; let node: XMLNode }
    for part in root.all("part") {
      var marks: [Mark] = []
      for (index, measure) in part.all("measure").enumerated() {
        for direction in measure.all("direction") {
          let types = direction.all("direction-type")
          if types.contains(where: { $0.first("segno") != nil }) {
            marks.append(Mark(measure: index, kind: .segno, direction: direction, node: measure))
          }
          if types.contains(where: { $0.first("coda") != nil }) {
            marks.append(Mark(measure: index, kind: .coda, direction: direction, node: measure))
          }
          let words = types.compactMap { $0.first("words")?.text }.joined(separator: " ")
          guard let jump = LocalTextReader.navigation(words) else { continue }
          let kind: Kind
          switch jump {
          case "Segno": kind = .segno
          case "Coda": kind = .coda
          case "To Coda": kind = .toCoda
          case "Fine": kind = .fine
          default:
            let tail = jump.hasSuffix("al Coda") ? "coda" : jump.hasSuffix("al Fine") ? "fine" : ""
            kind = jump.hasPrefix("D.S.") ? .dalSegno(tail) : .daCapo(tail)
          }
          marks.append(Mark(measure: index, kind: kind, direction: direction, node: measure))
        }
      }
      guard !marks.isEmpty else { continue }
      let words = marks.filter { if case .segno = $0.kind { return false }; if case .coda = $0.kind { return false }; return true }
      func bars(_ match: (Kind) -> Bool) -> [Mark] { marks.filter { match($0.kind) } }
      // a sign beside its own words belongs to them ("To Coda ⊕", "D.S. 𝄋 al Coda"); a sign and its name in one
      // bar ("𝄌 Coda") are one marker
      let toCodaBars = Set(bars { if case .toCoda = $0 { return true }; return false }.map(\.measure))
      let dalSegnoBars = Set(bars { if case .dalSegno = $0 { return true }; return false }.map(\.measure))
      var segnos: [Mark] = [], codas: [Mark] = []
      for mark in marks {
        switch mark.kind {
        case .segno where !dalSegnoBars.contains(mark.measure):
          if !segnos.contains(where: { $0.measure == mark.measure }) { segnos.append(mark) }
        case .coda where !toCodaBars.contains(mark.measure):
          if !codas.contains(where: { $0.measure == mark.measure }) { codas.append(mark) }
        default: break
        }
      }
      let toCodas = bars { if case .toCoda = $0 { return true }; return false }
      let fines = bars { if case .fine = $0 { return true }; return false }
      let segno = segnos.count == 1 ? segnos[0] : nil
      let coda = codas.count == 1 ? codas[0] : nil
      let toCoda = toCodas.count == 1 ? toCodas[0] : nil
      let fine = fines.count == 1 ? fines[0] : nil
      var usesCoda = false, usesFine = false
      func sound(_ mark: Mark, _ attributes: [String: String], atEnd: Bool = false) {
        if let existing = mark.direction.first("sound") {
          existing.attributes.merge(attributes) { a, _ in a }
        } else {
          mark.direction.children.append(XMLNode("sound", attributes: attributes))
        }
        // D.S., D.C., To Coda and Fine act at the end of their bar: written at its start, MuseScore's import moves
        // them to the end of the bar before, and the jump comes a bar early
        if atEnd, let at = mark.node.children.firstIndex(where: { $0 === mark.direction }) {
          mark.node.children.remove(at: at)
          let end = mark.node.children.lastIndex { ["note", "forward", "backup"].contains($0.tag) }
            .map { $0 + 1 } ?? mark.node.children.count
          mark.node.children.insert(mark.direction, at: end)
        }
      }
      func reachable(_ tail: String, from start: Int, jump: Int) -> Bool {
        switch tail {
        case "coda":
          guard let toCoda, let coda, toCoda.measure >= start, toCoda.measure <= jump, coda.measure > toCoda.measure
          else { return false }
          usesCoda = true
          return true
        case "fine":
          guard let fine, fine.measure >= start else { return false }
          usesFine = true
          return true
        default:
          // a plain D.S. or D.C. in a score that prints a coda or a Fine was probably "al Coda" or "al Fine" in a
          // form not read ("D.S. al ⊕", the coda drawn as its sign): playing it to the end would be wrong
          return codas.isEmpty && toCodas.isEmpty && fines.isEmpty
            && !marks.contains { if case .coda = $0.kind { return true }; return false }
        }
      }
      for mark in words {
        switch mark.kind {
        case .dalSegno(let tail):
          if let segno, segno.measure <= mark.measure, reachable(tail, from: segno.measure, jump: mark.measure) {
            sound(mark, ["dalsegno": "segno"], atEnd: true)
          }
        case .daCapo(let tail):
          if reachable(tail, from: 0, jump: mark.measure) { sound(mark, ["dacapo": "yes"], atEnd: true) }
        default: break
        }
      }
      if let segno, marks.contains(where: { if case .dalSegno = $0.kind { return $0.direction.first("sound") != nil }; return false }) {
        sound(segno, ["segno": "segno"])
      }
      if usesCoda, let toCoda, let coda {
        sound(toCoda, ["tocoda": "coda"], atEnd: true)
        sound(coda, ["coda": "coda"])
      }
      if usesFine, let fine { sound(fine, ["fine": "yes"], atEnd: true) }
    }
  }

  private static func directionIndex(in measure: XMLNode) -> Int {
    var insertion = 0
    for (index, child) in measure.children.enumerated() {
      if child.tag == "print" || child.tag == "attributes" || child.tag == "harmony"
        || (child.tag == "barline" && child.attributes["location"] == "left")
      { insertion = index + 1 }
    }
    return insertion
  }

  private static func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
  }

  private static func compact(_ value: String) -> String {
    value.lowercased().filter { !$0.isWhitespace }
  }

  private static func cleaned(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }

  private static func isNumberOnly(_ value: String) -> Bool {
    let meaningful = value.filter { !$0.isWhitespace && !$0.isPunctuation }
    return !meaningful.isEmpty && meaningful.allSatisfy(\.isNumber)
  }
}
