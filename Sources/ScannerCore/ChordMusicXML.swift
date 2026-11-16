import Foundation

struct ChordMeter: Equatable { let beats: Int; let beatType: Int }

enum ChordTiming {
  static func normalized(_ signature: ChordMeter?) -> ChordMeter? {
    guard let signature, signature.beats > 0, signature.beatType > 0 else { return nil }
    if signature.beatType >= 8, signature.beats >= 6, signature.beats % 3 == 0 {
      return [2: ChordMeter(beats: 6, beatType: 8),
              3: ChordMeter(beats: 9, beatType: 8),
              4: ChordMeter(beats: 12, beatType: 8)][signature.beats / 3]
    }
    let numerator = signature.beats * 4
    guard numerator % signature.beatType == 0 else { return nil }
    return [2, 3, 4].contains(numerator / signature.beatType)
      ? ChordMeter(beats: numerator / signature.beatType, beatType: 4) : nil
  }

  static func defaults(meter: ChordMeter, count: Int) -> [Double]? {
    switch (meter.beats, meter.beatType, count) {
    case (2, 4, 1), (3, 4, 1), (4, 4, 1), (6, 8, 1), (9, 8, 1), (12, 8, 1):
      return [1]
    case (2, 4, 2): return [1, 2]
    case (3, 4, 2), (4, 4, 2): return [1, 3]
    case (6, 8, 2): return [1, 4]
    case (9, 8, 2), (12, 8, 2): return [1, 7]
    case (3, 4, 3), (4, 4, 3): return [1, 2, 3]
    case (6, 8, 3): return [1, 3, 5]
    case (9, 8, 3): return [1, 4, 7]
    case (12, 8, 3): return [1, 5, 9]
    case (2, 4, 4): return [1, 1.5, 2, 2.5]
    case (4, 4, 4): return [1, 2, 3, 4]
    case (6, 8, 4): return [1, 2.5, 4, 5.5]
    case (12, 8, 4): return [1, 4, 7, 10]
    default: return nil
    }
  }

  /// `fallback` stands in for a missing time signature. Recognizers without real
  /// symbol positions pass one so beats come from the metre defaults, not from
  /// synthetic x coordinates.
  static func place(bar: inout ChordBar, signature: ChordMeter?, fallback: ChordMeter? = nil) {
    let indices = bar.labels.indices.filter { bar.labels[$0].measureNumber != nil }.sorted {
      bar.labels[$0].x0 < bar.labels[$1].x0
    }
    guard !indices.isEmpty else { return }
    // Beats the chord finder took from the notes under each chord (in quarter notes) are kept as they are, except
    // that two chords never share a beat: the finder snaps a chord with no note of its own to the nearest strong
    // beat (two such chords in one half bar both land on 3), and a bar the note reader merged with the next starts
    // both bars' chords on beat 1. A later chord on an earlier chord's beat takes the whole beat nearest where it
    // stands in the bar instead, after the chord before it (half a beat after it when no whole beat is left).
    if indices.allSatisfy({ bar.labels[$0].timingSource == "finder" && bar.labels[$0].beat != nil }) {
      let meter = signature ?? fallback
      let length = meter.map { Double($0.beats) * 4 / Double($0.beatType) } ?? 4
      let span = max(0.000_001, bar.right - bar.left)
      var previous: Double?
      for index in indices {
        bar.labels[index].beatUnit = 4
        if let p = previous, let beat = bar.labels[index].beat, beat <= p {
          let centre = (bar.labels[index].x0 + bar.labels[index].x1) / 2
          let fraction = min(max((centre - bar.left) / span, 0), 0.999)
          // a chord past the line's last bar line still belongs to its last beat
          var spread = min((1 + fraction * length).rounded(), length)
          if spread <= p { spread = p + 1 <= length ? (p + 1).rounded(.down) : p + 0.5 }
          if spread < length + 1 {
            bar.labels[index].beat = spread
            bar.labels[index].timingStatus = "spread"
          }
        }
        previous = bar.labels[index].beat
      }
      return
    }
    let signature = signature ?? fallback
    let meter = normalized(signature)
    if let meter, let beats = defaults(meter: meter, count: indices.count) {
      for (index, beat) in zip(indices, beats) {
        bar.labels[index].beat = beat
        bar.labels[index].beatUnit = meter.beatType
        bar.labels[index].timingSource = "metre-default"
      }
      return
    }
    let count = meter?.beats ?? signature?.beats ?? 4
    let span = max(0.000_001, bar.right - bar.left)
    var previous: Double?
    for index in indices {
      let centre = (bar.labels[index].x0 + bar.labels[index].x1) / 2
      let fraction = min(max((centre - bar.left) / span, 0), 0.999)
      var beat = ((1 + fraction * Double(count)) * 2).rounded() / 2
      if let previous, beat <= previous { beat = previous + 0.5 }
      beat = min(beat, Double(count) + 0.5)
      previous = beat
      bar.labels[index].beat = beat
      bar.labels[index].beatUnit = meter?.beatType ?? signature?.beatType ?? 4
      bar.labels[index].timingSource = "proximity"
      bar.labels[index].timingStatus = "needs-adjustment"
    }
  }
}

enum ChordMusicXML {
  private struct SystemKey: Hashable { let voice: Int; let system: Int }
  private struct MeasureKey: Hashable { let part: String; let number: String }
  private struct SystemMeasures {
    let part: String
    let measures: [XMLNode]
    let ambiguous: Bool
  }

  /// Assigns each staff's bars to the measures of its system. When the bars
  /// and measures disagree in a way trimming cannot settle, the staff is left
  /// unmapped, or with `fitUnmatched` its chords are spread across the
  /// system's measures by position so that none is lost.
  static func map(
    _ staffs: inout [ChordStaff], score: Data, fallbackMeter: ChordMeter? = nil,
    fitUnmatched: Bool = false
  ) throws {
    let root = try XMLNode.parse(score)
    var firstMeter: ChordMeter?
    for part in root.all("part") {
      for measure in part.all("measure") {
        if let value = meter(in: measure) { firstMeter = value; break }
      }
      if firstMeter != nil { break }
    }
    var systems: [SystemKey: SystemMeasures] = [:]
    var signatures: [MeasureKey: ChordMeter] = [:]
    for (voice, part) in root.all("part").enumerated() {
      let partID = part.attributes["id"] ?? "P\(voice + 1)"
      var system = 0
      var groups: [Int: [XMLNode]] = [0: []]
      var ambiguous: Set<Int> = []
      var currentMeter = firstMeter
      for measure in part.all("measure") {
        if let value = meter(in: measure) { currentMeter = value }
        if let number = measure.attributes["number"], let currentMeter {
          signatures[MeasureKey(part: partID, number: number)] = currentMeter
        }
        var seenNotes = false
        for child in measure.children {
          if child.tag == "print", child.attributes["new-system"] == "yes" {
            if seenNotes { ambiguous.formUnion([system, system + 1]) }
            system += 1
            groups[system] = groups[system] ?? []
          }
          if child.tag == "note" { seenNotes = true }
        }
        groups[system, default: []].append(measure)
      }
      for (number, measures) in groups {
        systems[SystemKey(voice: voice, system: number)] =
          SystemMeasures(part: partID, measures: measures, ambiguous: ambiguous.contains(number))
      }
    }

    for staffIndex in staffs.indices {
      if fitUnmatched, let voice = staffs[staffIndex].voice,
        let system = staffs[staffIndex].system,
        let match = systems[SystemKey(voice: voice, system: system)], !match.ambiguous,
        !match.measures.isEmpty,
        firstMeasureBar(staffs[staffIndex].bars, measures: match.measures.count) == nil
      {
        fitByPosition(&staffs[staffIndex], measures: match.measures, part: match.part)
        for barIndex in staffs[staffIndex].bars.indices {
          ChordTiming.place(
            bar: &staffs[staffIndex].bars[barIndex],
            signature: staffs[staffIndex].bars[barIndex].measureNumber.flatMap {
              signatures[MeasureKey(part: match.part, number: $0)]
            }, fallback: fallbackMeter)
        }
        continue
      }
      guard let voice = staffs[staffIndex].voice, let system = staffs[staffIndex].system,
        let match = systems[SystemKey(voice: voice, system: system)], !match.ambiguous,
        let first = firstMeasureBar(staffs[staffIndex].bars, measures: match.measures.count)
      else {
        staffs[staffIndex].mappingStatus = "unresolved"
        for barIndex in staffs[staffIndex].bars.indices {
          unmap(&staffs[staffIndex].bars[barIndex])
        }
        continue
      }
      staffs[staffIndex].mappingStatus = first == 0
        && match.measures.count == staffs[staffIndex].bars.count ? "count-matched" : "edge-trimmed"
      for barIndex in staffs[staffIndex].bars.indices {
        guard match.measures.indices.contains(barIndex - first) else {
          unmap(&staffs[staffIndex].bars[barIndex])
          continue
        }
        let number = match.measures[barIndex - first].attributes["number"]
        staffs[staffIndex].bars[barIndex].measureNumber = number
        staffs[staffIndex].bars[barIndex].partID = match.part
        for labelIndex in staffs[staffIndex].bars[barIndex].labels.indices {
          if staffs[staffIndex].bars[barIndex].labels[labelIndex].bar != nil {
            staffs[staffIndex].bars[barIndex].labels[labelIndex].measureNumber = number
            staffs[staffIndex].bars[barIndex].labels[labelIndex].partID = match.part
          }
        }
        let signature = number.flatMap { signatures[MeasureKey(part: match.part, number: $0)] }
        ChordTiming.place(
          bar: &staffs[staffIndex].bars[barIndex], signature: signature, fallback: fallbackMeter)
      }
    }
  }

  /// Spreads a staff's chords over its system's measures by where they sit
  /// along the line, for a line whose bars and measures cannot be paired: the
  /// notation read three bars where the page prints four, say. The stretch
  /// from the first bar that matters to the last is divided evenly among the
  /// measures and each chord goes to the measure under its centre, so a chord
  /// may land a bar early or late but is never dropped. Empty narrow pieces at
  /// the ends, such as a clef cut off before a repeat, are left out first.
  static func fitByPosition(
    _ staff: inout ChordStaff, measures: [XMLNode], part: String
  ) {
    var bars = staff.bars
    let widths = bars.map { $0.right - $0.left }.sorted()
    let typical = widths.isEmpty ? 0 : widths[widths.count / 2]
    func extra(_ bar: ChordBar) -> Bool { bar.labels.isEmpty && bar.right - bar.left < typical / 2 }
    while bars.count > 1, let head = bars.first, extra(head) { bars.removeFirst() }
    while bars.count > 1, let tail = bars.last, extra(tail) { bars.removeLast() }
    guard let left = bars.first?.left, let right = bars.last?.right, right > left else {
      staff.mappingStatus = "unresolved"
      for index in staff.bars.indices { unmap(&staff.bars[index]) }
      return
    }
    let width = (right - left) / Double(measures.count)
    var fitted = measures.enumerated().map { index, measure in
      ChordBar(
        index: index, left: left + Double(index) * width, right: left + Double(index + 1) * width,
        text: "", labels: [], measureNumber: measure.attributes["number"], partID: part)
    }
    for label in bars.flatMap(\.labels) {
      let centre = (label.x0 + label.x1) / 2
      let index = min(measures.count - 1, max(0, Int((centre - left) / width)))
      var moved = label
      moved.bar = index
      moved.measureNumber = fitted[index].measureNumber
      moved.partID = part
      fitted[index].labels.append(moved)
    }
    for index in fitted.indices {
      fitted[index].text = fitted[index].labels.map(\.chord).joined(separator: " ")
    }
    staff.bars = fitted
    staff.mappingStatus = "position-fitted"
  }

  /// The bar that holds a system's first exported measure. The staff detector
  /// can cut the clef and time signature before an opening repeat into a piece
  /// the note reader never writes as a measure. Extra pieces are trimmed from
  /// the ends only while they hold no chord and are under half a typical bar
  /// wide, so a chord can never move to a different measure.
  static func firstMeasureBar(_ bars: [ChordBar], measures: Int) -> Int? {
    guard measures > 0, bars.count >= measures else { return nil }
    let widths = bars.map { $0.right - $0.left }.sorted()
    let typical = widths[widths.count / 2]
    func extra(_ bar: ChordBar) -> Bool { bar.labels.isEmpty && bar.right - bar.left < typical / 2 }
    var first = 0, end = bars.count
    while end - first > measures {
      let head = bars[first], tail = bars[end - 1]
      if extra(head), !extra(tail) || head.right - head.left <= tail.right - tail.left {
        first += 1
      } else if extra(tail) {
        end -= 1
      } else {
        return nil
      }
    }
    return first
  }

  private static func unmap(_ bar: inout ChordBar) {
    bar.measureNumber = nil
    bar.partID = nil
    for index in bar.labels.indices {
      bar.labels[index].measureNumber = nil
      bar.labels[index].partID = nil
    }
  }

  static func insertMapped(_ score: Data, staffs: [ChordStaff]) throws -> (xml: Data, written: Int) {
    let root = try XMLNode.parse(score)
    var labels: [MeasureKey: [ChordLabel]] = [:]
    for staff in staffs {
      for bar in staff.bars {
        for label in bar.labels {
          if let part = label.partID, let number = label.measureNumber {
            labels[MeasureKey(part: part, number: number), default: []].append(label)
          }
        }
      }
    }
    var written = 0
    for part in root.all("part") {
      guard let partID = part.attributes["id"] else { continue }
      let divisions = part.all("measure").compactMap {
        $0.first("attributes")?.first("divisions").flatMap { try? $0.integer() }
      }.first ?? 1
      for measure in part.all("measure") {
        guard let number = measure.attributes["number"],
          let here = labels[MeasureKey(part: partID, number: number)] else { continue }
        let nodes = here.sorted { ($0.beat ?? 1) < ($1.beat ?? 1) }.compactMap { label -> XMLNode? in
          let unit = label.beatUnit ?? 4
          let offset = Int(round(((label.beat ?? 1) - 1) * Double(divisions * 4) / Double(unit)))
          return harmony(label.chord, offset: offset) ?? looseHarmony(label.chord, offset: offset)
        }
        var insertion = 0
        for (index, child) in measure.children.enumerated() {
          if child.tag == "print" || child.tag == "attributes"
            || (child.tag == "barline" && child.attributes["location"] == "left")
          { insertion = index + 1 }
        }
        measure.children.insert(contentsOf: nodes, at: insertion)
        written += nodes.count
      }
    }
    return (Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root.serialized()).utf8), written)
  }

  private static func meter(in measure: XMLNode) -> ChordMeter? {
    for attributes in measure.all("attributes") {
      guard let time = attributes.first("time"),
        let beats = time.first("beats"), let beatType = time.first("beat-type"),
        let count = Int(beats.text), let unit = Int(beatType.text) else { continue }
      return ChordMeter(beats: count, beatType: unit)
    }
    return nil
  }

  private static let chordPattern = try! NSRegularExpression(pattern:
    #"^([A-G])([b#♭♯]?)(maj|min|dim|aug|sus|MA|Ma|ma|MI|Mi|mi|[+\-omø])?(6/9|69|13|11|[5679])?(sus[24]?)?((?:\((?:(?:no|omit|add)\d{1,2}|(?:maj7|[b#+]?\d{1,2}){1,2})\)|[b#+]\d{1,2}){0,2})(?:/([A-G])([b#♭♯]?))?$"#)
  private static let degreePattern = try! NSRegularExpression(
    pattern: #"(no|omit|add)?([b#+]?)(\d{1,2})"#)

  static func harmony(_ chord: String, offset: Int) -> XMLNode? {
    let nsrange = NSRange(chord.startIndex..., in: chord)
    guard let match = chordPattern.firstMatch(in: chord, range: nsrange) else { return nil }
    func group(_ number: Int) -> String {
      guard match.range(at: number).location != NSNotFound,
        let range = Range(match.range(at: number), in: chord) else { return "" }
      return String(chord[range])
    }
    let step = group(1), accidental = group(2), rawQuality = group(3)
    let extensionValue = group(4), trailing = group(5)
    var alterations = group(6)
    let bassStep = group(7), bassAccidental = group(8)
    var quality = trailing.isEmpty ? rawQuality : rawQuality.isEmpty ? "sus" : rawQuality
    quality = ["-": "min", "m": "min", "mi": "min", "MI": "min", "Mi": "min",
               "ma": "maj", "MA": "maj", "Ma": "maj", "o": "dim", "+": "aug"][quality]
      ?? quality
    var kind: String
    if quality == "ø" || (quality == "min" && extensionValue == "7" && alterations.contains("b5")) {
      kind = "half-diminished"
      alterations = alterations.replacingOccurrences(of: "(b5)", with: "")
        .replacingOccurrences(of: "b5", with: "")
    } else if quality == "min" && alterations.contains("maj7") {
      kind = "major-minor"
      alterations = alterations.replacingOccurrences(of: "(maj7)", with: "")
    } else {
      let key = "\(quality)|\(extensionValue)"
      kind = kinds[key] ?? kinds["\(quality)|"] ?? "major"
    }
    let root = XMLNode("root", children: [XMLNode("root-step", text: step)])
    if let alter = accidentalValue(accidental), alter != 0 {
      root.children.append(XMLNode("root-alter", text: "\(alter)"))
    }
    // kind@text is the text drawn *after* the root, so it must carry only the
    // suffix: writing the whole symbol makes renderers print the root twice
    // ("Ab" becomes "A♭Ab").
    var suffix = String(chord.dropFirst(step.count + accidental.count))
    if !bassStep.isEmpty, let slash = suffix.lastIndex(of: "/") {
      suffix = String(suffix[suffix.startIndex..<slash])
    }
    let node = XMLNode("harmony", children: [
      root, XMLNode("kind", text: kind, attributes: ["text": suffix, "use-symbols": "no"]),
    ])
    if !bassStep.isEmpty {
      let bass = XMLNode("bass", children: [XMLNode("bass-step", text: bassStep)])
      if let alter = accidentalValue(bassAccidental), alter != 0 {
        bass.children.append(XMLNode("bass-alter", text: "\(alter)"))
      }
      node.children.append(bass)
    }
    func degree(_ value: String, _ alter: Int, _ type: String) -> XMLNode {
      XMLNode("degree", children: [
        XMLNode("degree-value", text: value), XMLNode("degree-alter", text: "\(alter)"),
        XMLNode("degree-type", text: type),
      ])
    }
    // A sus chord with a seventh or more is spelled as MuseScore's chord list spells it (chords.xml): the fourth
    // suspended, then add7, then the extension (9sus: add7 add9; 13sus: add7 add13), then its alterations as added
    // degrees. MuseScore matches kind and degrees in that order and names the chord from the match, ignoring the
    // printed text, so writing only the extension turned Bb9sus4 into Bbsus4add9 and Bb13sus into Bbsus4.
    let susSeventh = quality == "sus" && ["7", "9", "11", "13"].contains(extensionValue)
    if susSeventh {
      node.children.append(degree("7", 0, "add"))
      if extensionValue == "9" || extensionValue == "11" { node.children.append(degree("9", 0, "add")) }
      if extensionValue == "11" { node.children.append(degree("11", 0, "add")) }
      if extensionValue == "13" { node.children.append(degree("13", 0, "add")) }
    }
    for match in degreePattern.matches(
      in: alterations, range: NSRange(alterations.startIndex..., in: alterations))
    {
      func text(_ group: Int) -> String {
        Range(match.range(at: group), in: alterations).map { String(alterations[$0]) } ?? ""
      }
      let word = text(1), sign = text(2), value = text(3)
      guard !value.isEmpty else { continue }
      let alter = sign == "#" || sign == "+" ? 1 : sign == "b" ? -1 : 0
      let type = word == "no" || word == "omit" ? "subtract"
        : alter == 0 || (susSeventh && value != "5") ? "add" : "alter"
      node.children.append(XMLNode("degree", children: [
        XMLNode("degree-value", text: value), XMLNode("degree-alter", text: "\(alter)"),
        XMLNode("degree-type", text: type),
      ]))
    }
    if extensionValue == "6/9" || extensionValue == "69" {
      node.children.append(XMLNode("degree", children: [
        XMLNode("degree-value", text: "9"), XMLNode("degree-alter", text: "0"),
        XMLNode("degree-type", text: "add"),
      ]))
    }
    if offset != 0 { node.children.append(XMLNode("offset", text: "\(offset)")) }
    node.children.append(XMLNode("staff", text: "1"))
    return node
  }

  /// A chord whose suffix the pattern above does not know, which the cloud
  /// model was trusted to have read. The root and bass are exact, the suffix is
  /// drawn exactly as printed, and the kind is the nearest standard one so that
  /// playback sounds close: `C7sus4(b9)` plays as a sus chord with a seventh and
  /// a flat ninth, `C7alt` as a dominant seventh.
  static func looseHarmony(_ chord: String, offset: Int) -> XMLNode? {
    let pattern = try! NSRegularExpression(pattern: #"^([A-G])([b#]?)(.*?)(?:/([A-G])([b#]?))?$"#)
    guard
      let match = pattern.firstMatch(in: chord, range: NSRange(chord.startIndex..., in: chord))
    else { return nil }
    func group(_ number: Int) -> String {
      Range(match.range(at: number), in: chord).map { String(chord[$0]) } ?? ""
    }
    let step = group(1), accidental = group(2), suffix = group(3)
    let bassStep = group(4), bassAccidental = group(5)
    let (kind, degrees) = nearestKind(suffix)
    let root = XMLNode("root", children: [XMLNode("root-step", text: step)])
    if let alter = accidentalValue(accidental), alter != 0 {
      root.children.append(XMLNode("root-alter", text: "\(alter)"))
    }
    let node = XMLNode("harmony", children: [
      root, XMLNode("kind", text: kind, attributes: ["text": suffix, "use-symbols": "no"]),
    ])
    if !bassStep.isEmpty {
      let bass = XMLNode("bass", children: [XMLNode("bass-step", text: bassStep)])
      if let alter = accidentalValue(bassAccidental), alter != 0 {
        bass.children.append(XMLNode("bass-alter", text: "\(alter)"))
      }
      node.children.append(bass)
    }
    for (value, alter, type) in degrees {
      node.children.append(XMLNode("degree", children: [
        XMLNode("degree-value", text: "\(value)"), XMLNode("degree-alter", text: "\(alter)"),
        XMLNode("degree-type", text: type),
      ]))
    }
    if offset != 0 { node.children.append(XMLNode("offset", text: "\(offset)")) }
    node.children.append(XMLNode("staff", text: "1"))
    return node
  }

  /// The standard kind nearest to a free-form suffix, and the degrees it adds
  /// or alters: the quality from how the suffix opens, the size from its first
  /// number, and every flat, sharp or added degree written after that.
  static func nearestKind(_ suffix: String) -> (kind: String, degrees: [(Int, Int, String)]) {
    func opens(_ prefixes: String...) -> Bool { prefixes.contains { suffix.hasPrefix($0) } }
    let marks = try! NSRegularExpression(pattern: #"(add|no|omit|[b#+])(\d{1,2})"#)
    let whole = NSRange(suffix.startIndex..., in: suffix)
    // The chord's size is its first number that is not itself an alteration or
    // an added degree: 7 in `7sus4(b9)`, none in `add9`.
    let core = marks.stringByReplacingMatches(in: suffix, range: whole, withTemplate: "")
    let numbers = core.split { !$0.isNumber }.compactMap { Int($0) }
    let size = numbers.first { [5, 6, 7, 9, 11, 13].contains($0) } ?? 0
    func sized(_ base: String, _ sizes: [Int: String]) -> String { sizes[size] ?? base }
    let minor = opens("min", "mi", "-", "MI", "Mi") || (opens("m") && !opens("maj", "ma"))
    let major = opens("maj", "Maj", "MAJ", "ma", "MA", "Ma", "Δ", "∆", "^", "M")
    var degrees: [(Int, Int, String)] = []
    let kind: String
    if suffix.contains("ø") || suffix.contains("Ø") {
      kind = "half-diminished"
    } else if minor && (suffix.contains("maj7") || suffix.contains("Δ") || suffix.contains("∆")) {
      kind = "major-minor"
    } else if minor {
      kind = suffix.contains("7b5") ? "half-diminished"
        : sized("minor", [6: "minor-sixth", 7: "minor-seventh", 9: "minor-ninth",
                          11: "minor-11th", 13: "minor-13th"])
    } else if opens("dim", "o") {
      kind = size == 7 ? "diminished-seventh" : "diminished"
    } else if opens("aug", "+") {
      kind = size == 7 ? "augmented-seventh" : "augmented"
    } else if major {
      // "M", "maj" and "MA" with no number are the major triad and "M6" its sixth (DM is D major, not Dmaj7);
      // the triangle alone means the seventh
      if size == 6 {
        kind = "major-sixth"
      } else if size == 0 && !opens("Δ", "∆", "^") {
        kind = "major"
      } else {
        kind = sized("major-seventh", [9: "major-ninth", 11: "major-11th", 13: "major-13th"])
      }
    } else if suffix.contains("sus") {
      kind = suffix.contains("sus2") ? "suspended-second" : "suspended-fourth"
      // as in `harmony`: add7, then the extension, as MuseScore's chord list spells a sus chord
      if [7, 9, 11, 13].contains(size) { degrees.append((7, 0, "add")) }
      if size == 9 || size == 11 { degrees.append((9, 0, "add")) }
      if size == 11 { degrees.append((11, 0, "add")) }
      if size == 13 { degrees.append((13, 0, "add")) }
    } else {
      kind = sized(
        "major",
        [5: "power", 6: "major-sixth", 7: "dominant", 9: "dominant-ninth",
         11: "dominant-11th", 13: "dominant-13th"])
      if numbers.first == 2 { degrees.append((2, 0, "add")) }
    }
    let susSeventh = kind == "suspended-fourth" && [7, 9, 11, 13].contains(size)
    for match in marks.matches(in: suffix, range: whole) {
      // An opening + is the augmented quality, not a raised degree.
      if match.range.location == 0 && suffix.hasPrefix("+") { continue }
      guard let markRange = Range(match.range(at: 1), in: suffix),
        let valueRange = Range(match.range(at: 2), in: suffix), let value = Int(suffix[valueRange])
      else { continue }
      switch suffix[markRange] {
      case "add": degrees.append((value, 0, "add"))
      case "no", "omit": degrees.append((value, 0, "subtract"))
      case "b": degrees.append((value, -1, susSeventh && value != 5 ? "add" : "alter"))
      default: degrees.append((value, 1, susSeventh && value != 5 ? "add" : "alter"))
      }
    }
    return (kind, degrees)
  }

  private static func accidentalValue(_ value: String) -> Int? {
    ["": 0, "#": 1, "♯": 1, "b": -1, "♭": -1][value]
  }

  private static let kinds: [String: String] = [
    "|": "major", "|5": "power", "|6": "major-sixth", "|7": "dominant",
    "|6/9": "major-sixth", "|69": "major-sixth",
    "|9": "dominant-ninth", "|11": "dominant-11th", "|13": "dominant-13th",
    "maj|": "major", "maj|6": "major-sixth", "maj|7": "major-seventh",
    "maj|9": "major-ninth", "maj|11": "major-11th", "maj|13": "major-13th",
    "min|": "minor", "min|6": "minor-sixth", "min|7": "minor-seventh",
    "min|6/9": "minor-sixth", "min|69": "minor-sixth",
    "min|9": "minor-ninth", "min|11": "minor-11th", "min|13": "minor-13th",
    "dim|": "diminished", "dim|7": "diminished-seventh",
    "aug|": "augmented", "aug|7": "augmented-seventh",
    "sus|": "suspended-fourth", "sus|2": "suspended-second",
    "sus|4": "suspended-fourth", "sus|7": "suspended-fourth", "sus|9": "suspended-fourth",
  ]
}
