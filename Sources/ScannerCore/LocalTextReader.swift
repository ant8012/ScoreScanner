import Foundation

/// The page's text other than chord symbols, read on this device with the standard PP-OCRv6 small recogniser
/// (`text_rec.onnx`, not the chord-tuned model): the title, composer and tempo at the top of the first page,
/// rehearsal marks, navigation (D.S. al Coda, To Coda, Fine) and other staff text. The result has the same shape
/// as Apple's text reading, so `ScoreMetadataMusicXML` writes it the same way.
///
/// Navigation is spelled the way MuseScore's MusicXML import recognises jumps and markers ("D.S. al Coda",
/// "To Coda", "Fine"), and written as words like every other direction.
enum LocalTextReader {
  struct Box: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var w: Int { x1 - x0 }
    var h: Int { y1 - y0 }
    var cx: Double { Double(x0 + x1) / 2 }
  }

  /// Words read together as one run of text.
  struct Phrase {
    var box: Box
    /// The finder words it joins (none for a line found in the header or under the last staff).
    var words: [ChordFinder.Proposal] = []
    var text = ""
    var score = 0.0
  }

  // MARK: reading a page

  static func read(
    _ scan: ScanResult, chords: LocalChordReader.PageChords?, model: LocalChordReader.Model, page number: Int,
    header: Bool, progress: @Sendable (String) -> Void = { _ in }
  ) throws -> AppleScoreTextAnalysis {
    let start = Date()
    progress("Reading staff text")
    let page = LocalChordReader.Image(width: scan.pageWidth, height: scan.pageHeight, pixels: [UInt8](scan.page))
    let geometries = try scan.staffs.map { try StaffGeometry.decode($0.geometry) }
    guard !geometries.isEmpty, page.width > 0 else {
      return AppleScoreTextAnalysis(
        route: route, routeNote: "No staves to place text by.", metadata: nil, initialTimeSignature: nil,
        staffText: [], seconds: 0)
    }
    let sp = median(geometries.map(\.unit))
    let firstIndex = geometries.indices.min { geometries[$0].miny < geometries[$1].miny }!
    let lastIndex = geometries.indices.max { geometries[$0].maxy < geometries[$1].maxy }!
    let first = geometries[firstIndex]
    let chordWords = chords?.chordWords ?? []
    let words = scan.chordWords

    // The header is everything above the first system's chord row (above its staff when it has no chords).
    let firstChords = words.filter { w in
      chordWords.contains(LocalChordReader.wordKey(w.x0, w.y0, w.x1, w.y1))
        && scan.chordWordStaffs[w.staff]?.staff == firstIndex
    }
    let headerBottom = firstChords.isEmpty
      ? Int(first.miny - 2.5 * sp) : Int(Double(firstChords.map(\.y0).min()!) - 0.3 * sp)

    var metadata: AppleScoreMetadata?
    var readings: [AppleStaffTextReading] = []
    var headerLines: [Phrase] = []
    var headerUsed: [Box] = []
    var partLabel: String?
    let chordBoxes = firstChords.map { Box(x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1) }
    if header && first.miny > sp {
      // down to the first staff, leaving out the first line's chords
      headerLines = try phrases(page: page, rows: 0..<Int(first.miny - 0.3 * sp), cols: 0..<page.width, sp: sp)
        .filter { b in !chordBoxes.contains { overlaps($0, b) } }
        .map { try readPhrase(Phrase(box: $0), page: page, model: model) }
      if ProcessInfo.processInfo.environment["SCANNER_TEXT_DEBUG"] != nil {
        for l in headerLines { print("HEADER LINE \(l.box) \(String(format: "%.2f", l.score)) \"\(l.text)\"") }
      }
      let found = headerMetadata(headerLines, pageWidth: page.width, sp: sp)
      metadata = found.metadata
      headerUsed = found.used
      // a part printed on its own names its instrument at the top left ("Bass", "Piano"): the part's name, and
      // not staff text
      if let label = headerLines.first(where: { l in
        Double(l.box.x1) < 0.3 * Double(page.width) && l.score >= 0.8 && l.text.count <= 24
          && InstrumentSounds.isInstrument(l.text) && !headerUsed.contains(where: { overlaps($0, l.box) })
      }) {
        partLabel = label.text
        headerUsed.append(label.box)
      }
    }

    // Staff text: the finder's words that are not chords, joined into runs on one line.
    let lineStart = Dictionary(
      (chords?.lineStartLetters ?? []).map { ($0.word, $0.letter) }, uniquingKeysWith: { a, _ in a })
    var candidates: [ChordFinder.Proposal] = []
    for w in words {
      let key = LocalChordReader.wordKey(w.x0, w.y0, w.x1, w.y1)
      guard !chordWords.contains(key), lineStart[key] == nil, w.kind != .sign else { continue }
      let box = Box(x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1)
      // read with the header (a rehearsal box beside a tempo mark is still a rehearsal mark)
      if w.kind != .rehearsal && headerUsed.contains(where: { overlaps($0, box) }) { continue }
      candidates.append(w)
    }
    func place(_ phrase: Phrase, category: String, text: String) {
      guard let anchor = phrase.words.min(by: { $0.x0 < $1.x0 }),
        let target = scan.chordWordStaffs[anchor.staff], geometries.indices.contains(target.staff)
      else { return }
      let g = geometries[target.staff]
      let barCount = g.barlines.count + 1
      let edges = [g.minx] + g.barlines.map(\.x) + [g.maxx]
      let bar = target.barMeasures.indices.contains(anchor.bar)
        ? min(target.barMeasures[anchor.bar], barCount - 1)
        : max(0, min(barCount - 1, edges.lastIndex { $0 <= Double(anchor.x0) } ?? 0))
      readings.append(AppleStaffTextReading(
        id: UUID(), page: number, staff: target.staff, voice: g.voice ?? scan.staffs[target.staff].voice,
        system: g.system ?? scan.staffs[target.staff].system, bar: bar, barCount: barCount, text: text,
        category: category))
    }
    var headerTempo: (text: String, bpm: Int, box: Box)?
    var read = try wordPhrases(candidates).map { try readPhrase($0, page: page, model: model) }
    // an instruction that breaks after "D.S. al" goes on in the line below it
    for i in read.indices where navigation(read[i].text) == nil
      && read[i].text.range(of: #"\b(D\.\s?[SC]\.?|Dal\s+Segno|Da\s+Capo)\b.*\bal\s*$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
    {
      if let j = read.indices.first(where: { j in
        j != i && read[j].box.y0 > read[i].box.y0 && read[j].box.y0 - read[i].box.y1 <= read[i].box.h
          && min(read[j].box.x1, read[i].box.x1) > max(read[j].box.x0, read[i].box.x0)
      }) {
        read[i].text += " " + read[j].text
        read[j].text = ""
      }
    }
    for read in read where !read.text.isEmpty {
      try Task.checkCancellation()
      let kinds = Set(read.words.map(\.kind))
      if kinds == [.rehearsal] {
        if let mark = rehearsalMark(read.text) { place(read, category: "rehearsal", text: mark) }
        continue
      }
      if let jump = navigation(read.text) {
        place(read, category: "navigation", text: jump)
        continue
      }
      // under a staff, only navigation: the rest is lyrics
      if kinds.contains(.lineAbove) { continue }
      if let bpm = metronome(read.text) {
        let onFirst = read.words.contains { scan.chordWordStaffs[$0.staff]?.staff == firstIndex }
        if header && onFirst && headerTempo == nil && (metadata?.bpm ?? 0) == 0 {
          headerTempo = (read.text, bpm, read.box)
        } else {
          place(read, category: "tempo", text: read.text)
        }
        continue
      }
      guard let text = staffText(read) else { continue }
      if isTempoWords(text) {
        let onFirst = read.words.contains { scan.chordWordStaffs[$0.staff]?.staff == firstIndex }
        if header && onFirst && (metadata?.tempoText ?? "").isEmpty && headerTempo == nil {
          headerTempo = (text, 0, read.box)
        } else {
          place(read, category: "tempo", text: text)
        }
        continue
      }
      place(read, category: sectionWords(text) ? "section" : "instruction", text: text)
    }
    // Letters the chord pass found opening a line on a chord's beat: rehearsal letters whose box was missed.
    for w in words where lineStart[LocalChordReader.wordKey(w.x0, w.y0, w.x1, w.y1)] != nil {
      if let letter = lineStart[LocalChordReader.wordKey(w.x0, w.y0, w.x1, w.y1)] {
        place(Phrase(box: Box(x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1), words: [w]), category: "rehearsal",
              text: letter)
      }
    }
    // Navigation printed under the last staff, where the finder does not look ("Fine", "D.S. al Coda").
    let last = geometries[lastIndex]
    let below = Int(last.maxy + 0.5 * sp)..<min(page.height, Int(last.maxy + 6 * sp))
    for box in phrases(page: page, rows: below, cols: 0..<page.width, sp: sp) {
      let read = try readPhrase(Phrase(box: box), page: page, model: model)
      guard let jump = navigation(read.text) else { continue }
      let barCount = last.barlines.count + 1
      let edges = [last.minx] + last.barlines.map(\.x) + [last.maxx]
      let bar = max(0, min(barCount - 1, edges.lastIndex { $0 <= Double(box.x0) } ?? 0))
      readings.append(AppleStaffTextReading(
        id: UUID(), page: number, staff: lastIndex, voice: last.voice ?? scan.staffs[lastIndex].voice,
        system: last.system ?? scan.staffs[lastIndex].system, bar: bar, barCount: barCount, text: jump,
        category: "navigation"))
    }

    // Tempo: the printed note before "=" when there is one, the note named in words, else the meter's beat.
    if let found = headerTempo {
      let unit = found.bpm > 0
        ? (printedNoteValue(page: page, box: found.box, sp: sp, text: found.text) ?? namedNoteValue(found.text)
          ?? meterBeatUnit(scan.xml))
        : ""
      let base = metadata ?? AppleScoreMetadata(
        title: "", subtitle: "", composer: "", arranger: "", partName: "", tempoText: "", beatUnit: "", bpm: 0,
        copyright: "")
      metadata = AppleScoreMetadata(
        title: base.title, subtitle: base.subtitle, composer: base.composer, arranger: base.arranger,
        partName: base.partName,
        tempoText: found.bpm > 0 ? (base.tempoText.isEmpty ? tempoWording(found.text) : base.tempoText) : found.text,
        beatUnit: found.bpm > 0 ? unit : base.beatUnit, bpm: found.bpm > 0 ? found.bpm : base.bpm,
        copyright: base.copyright)
    } else if let m = metadata, m.bpm > 0, m.beatUnit.isEmpty {
      let line = headerLines.first { metronome($0.text) == m.bpm } ?? headerLines.first { $0.text == m.tempoText }
      let unit = line.flatMap { printedNoteValue(page: page, box: $0.box, sp: sp, text: $0.text) }
        ?? namedNoteValue(m.tempoText)
        ?? meterBeatUnit(scan.xml)
      metadata = AppleScoreMetadata(
        title: m.title, subtitle: m.subtitle, composer: m.composer, arranger: m.arranger, partName: m.partName,
        tempoText: m.tempoText, beatUnit: unit, bpm: m.bpm, copyright: m.copyright)
    }
    progress("Reading lyrics")
    // the chords the chord reader accepted: a lyric word on one of them is the chord band of the line below
    let acceptedChords = words.filter { chordWords.contains(LocalChordReader.wordKey($0.x0, $0.y0, $0.x1, $0.y1)) }
      .map { Box(x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1) }
    let lyrics = try readLyrics(scan.lyricWords, page: page, model: model, chords: acceptedChords)
    var names: (long: [String], short: [String])?
    if header {
      progress("Reading part names")
      names = try partNames(page: page, staffs: geometries, model: model)
      // one part with no name beside its staff: the label at the top left names it
      if let label = partLabel, names?.long.count == 1, names?.long.first?.isEmpty ?? true {
        names?.long = [label.capitalized]
      }
    }
    return AppleScoreTextAnalysis(
      route: route, routeNote: nil, metadata: metadata?.isEmpty == true ? nil : metadata,
      initialTimeSignature: nil, staffText: readings, seconds: Date().timeIntervalSince(start),
      partNames: names?.long, partAbbreviations: names?.short, lyrics: lyrics)
  }

  // MARK: lyrics

  /// Words that are not sung: performance notes and instrument cues ("SOLOS", "(bass)", "Piano"), and chord
  /// names ("D-7", "Bb", "F#sus"; "A" and "I" stay, being words too).
  static let notSung: Set<String> = [
    "solo", "solos", "head", "repeat", "ending", "fine", "coda", "tacet", "vamp", "intro", "outro",
    "guitar", "gtr", "piano", "drums", "synth", "organ", "sax", "trumpet", "horns",
    "tutti", "simile", "sim", "rit", "accel", "cresc", "dim", "segno",
  ]

  /// `syllable`: the word is joined by a hyphen to the one before or after it, so a single letter ("e-nough",
  /// "bod-y") is a syllable.
  static func lyricWord(_ text: String, syllable: Bool = false) -> Bool {
    if text.hasPrefix("(") || text.hasSuffix(")") || text.hasPrefix("[") { return false }
    let bare = text.trimmingCharacters(in: .punctuationCharacters).lowercased()
    if notSung.contains(bare) || navigation(text) != nil { return false }
    let letters = text.filter(\.isLetter)
    // a single letter on its own is a word only as a, I or O
    if letters.count == 1 && !syllable && !["a", "i", "o"].contains(letters.lowercased()) { return false }
    // a chord name, unless it is also a word
    if letters.count >= 1, !["a", "i", "am", "be", "do", "go", "ad"].contains(bare),
      ChordText.normalizedSymbol(text.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))) != nil {
      return false
    }
    return true
  }

  /// A lyric word as read, tidied: hyphens and extender ink at its ends dropped, a lone "0" read as the letter o,
  /// and a word of letters that look alike in both cases ("so", "us", "we") read in capitals made lower case when
  /// it stands no taller than the line's small letters.
  static func lyricText(_ read: String, height: Int, tallest: Int) -> String {
    var text = read.trimmingCharacters(in: CharacterSet(charactersIn: "-_–—‐ "))
    if text.trimmingCharacters(in: .punctuationCharacters) == "0" { text = text.replacingOccurrences(of: "0", with: "o") }
    let alike = Set("COSUVWXZ")
    let letters = text.filter(\.isLetter)
    if !letters.isEmpty, letters.allSatisfy({ alike.contains($0) }), Double(height) <= 0.8 * Double(tallest) {
      text = text.lowercased()
    }
    return text
  }

  /// Readings below this are not lyrics: a stray mark, the tail of a note the detector missed.
  static let lyricScoreMin = 0.5
  /// The fewest words a line under a staff must read as to be lyrics.
  static let lyricLineWords = 3

  /// The lyric words `LyricFinder` found, read: each becomes a syllable on its note, single, begin, middle or end by
  /// the hyphens around it (a hyphen ending a line carries over to the next line of the same verse). A word that
  /// reads as no word, or as navigation, is dropped.
  static func readLyrics(
    _ words: [LyricFinder.Word], page: LocalChordReader.Image, model: LocalChordReader.Model, chords: [Box] = []
  ) throws -> [ScoreLyric] {
    // line by line, top to bottom, each line left to right
    let lines = Dictionary(grouping: words) { "\($0.staff) \($0.verse)" }.values
      .map { $0.sorted { $0.x0 < $1.x0 } }
      .sorted { ($0[0].y0, $0[0].x0) < ($1[0].y0, $1[0].x0) }
    // read every word; a word that reads as no word is nil
    var readLines: [(staff: Int, words: [(word: LyricFinder.Word, text: String?)])] = []
    for line in lines {
      let tallest = line.map { $0.y1 - $0.y0 }.max() ?? 0
      var read: [(LyricFinder.Word, String?)] = []
      for w in line {
        let r = try readPhrase(Phrase(box: Box(x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1)), page: page, model: model)
        let text = lyricText(r.text.trimmingCharacters(in: .whitespaces), height: w.y1 - w.y0, tallest: tallest)
        let box = Box(x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1)
        let ok = r.score >= lyricScoreMin && text.contains(where: \.isLetter) && text.count <= 24
          && !chords.contains(where: { overlaps($0, box) })
          && lyricWord(text, syllable: w.hyphenAfter || (read.last.map { $0.0.hyphenAfter } ?? false))
        read.append((w, ok ? text : nil))
      }
      // small print, a copyright line, or a line most of whose words are not lyric words: not lyrics
      let all = read.compactMap { $0.1 }.joined(separator: " ").lowercased()
      let small = ["copyright", "©", "rights reserved", "music group", "publishing", "selling agent", "used by permission"]
      let kept = read.filter { $0.1 != nil }.count
      if small.contains(where: { all.contains($0) }) || kept * 2 < read.count {
        read = read.map { ($0.0, nil) }
      }
      readLines.append((line[0].staff, read))
    }
    // Verses are numbered
    // among those lines only, so a stray line of marks above them does not push verse 1 down.
    var verseOf: [Int: Int] = [:]   // staff -> lyric lines so far
    var out: [ScoreLyric] = []
    var carried: [Int: Bool] = [:]   // verse -> the last line ended in a hyphen
    for line in readLines {
      // three or more words, two of them of two letters or more: a credit ("by Berlin"), a cue ("Hi drums enter")
      // or a stray reading is shorter
      let good = line.words.compactMap(\.text)
      guard good.count >= lyricLineWords, good.filter({ $0.filter(\.isLetter).count >= 2 }).count >= 2 else { continue }
      let verse = verseOf[line.staff, default: 0]
      verseOf[line.staff] = verse + 1
      var hyphenBefore = carried[verse] ?? false
      var lastHyphen = false
      for (w, text) in line.words {
        guard let text else {
          hyphenBefore = false
          continue
        }
        // a word read with a hyphen inside, over as many notes: one syllable each
        var parts = [text]
        let pieces = text.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        if pieces.count > 1, pieces.count - 1 <= w.moreNoteIDs.count { parts = pieces }
        let ids = [w.noteID] + w.moreNoteIDs
        for (i, part) in parts.enumerated() {
          let before = i > 0 || hyphenBefore, after = i < parts.count - 1 || w.hyphenAfter
          let syllabic = before ? (after ? "middle" : "end") : (after ? "begin" : "single")
          out.append(ScoreLyric(noteID: ids[i], verse: verse + 1, text: part, syllabic: syllabic,
                                extend: i == parts.count - 1 && w.extendAfter))
        }
        hyphenBefore = w.hyphenAfter
        lastHyphen = w.hyphenAfter
      }
      carried[verse] = lastHyphen
    }
    return out
  }

  // MARK: part names

  /// A name as read, with the key of a transposing instrument spelled as printed: "Clarinet in Bb" reads the
  /// flat sign as a "b". Only after "in": "Cb." is a contrabass.
  static func instrumentName(_ text: String) -> String {
    text.replacingOccurrences(of: #"\b(in|In) ([A-G])b\b"#, with: "$1 $2♭", options: .regularExpression)
      .replacingOccurrences(of: #"\b(in|In) ([A-G])#"#, with: "$1 $2♯", options: .regularExpression)
  }

  /// The tallest letter of a part name, in staff spaces: taller pieces in the margin are brackets and braces.
  static let nameLetterMax = 2.5
  /// Readings below this are smudges, bracket ends or stray marks.
  static let nameScoreMin = 0.6

  /// Instrument names printed in the margin left of each part's staves: long names beside the first system,
  /// short ones beside the second. One entry per part ("" where none was read); a name printed on two lines
  /// ("Clarinet in" / "B♭") is read as one.
  static func partNames(page: LocalChordReader.Image, staffs: [StaffGeometry], model: LocalChordReader.Model)
    throws -> (long: [String], short: [String])
  {
    let parts = (staffs.compactMap(\.voice).max() ?? -1) + 1
    let systems = Array(Set(staffs.compactMap(\.system))).sorted()
    guard parts > 0, !systems.isEmpty else { return ([], []) }
    func names(on system: Int) throws -> [String] {
      var out = [String](repeating: "", count: parts)
      let staves = staffs.filter { $0.system == system && $0.voice != nil }
      // each part's band of the page: its staves, a little above and below, split halfway to its neighbours
      var bands: [(part: Int, top: Double, bottom: Double, left: Double, sp: Double)] = []
      for p in Set(staves.map { $0.voice! }) {
        let own = staves.filter { $0.voice == p }
        bands.append((p, own.map(\.miny).min()!, own.map(\.maxy).max()!, own.map(\.minx).min()!,
                      median(own.map(\.unit))))
      }
      bands.sort { $0.top < $1.top }
      for (k, b) in bands.enumerated() {
        let above = k > 0 ? (bands[k - 1].bottom + b.top) / 2 : b.top - 3 * b.sp
        let below = k + 1 < bands.count ? (b.bottom + bands[k + 1].top) / 2 : b.bottom + 3 * b.sp
        let rows = Int(max(above, b.top - 1.5 * b.sp))..<Int(min(below, b.bottom + 1.5 * b.sp))
        let cols = 0..<max(0, Int(b.left - 0.3 * b.sp))
        var lines: [String] = []
        for box in phrases(page: page, rows: rows, cols: cols, sp: b.sp, tallest: nameLetterMax) {
          let read = try readPhrase(Phrase(box: box), page: page, model: model)
          let text = read.text.trimmingCharacters(in: .whitespaces)
          if ProcessInfo.processInfo.environment["SCANNER_TEXT_DEBUG"] != nil {
            print("PART NAME system \(system) part \(b.part) \(box) \(String(format: "%.2f", read.score)) \"\(text)\"")
          }
          guard read.score >= nameScoreMin, text.contains(where: \.isLetter) else { continue }
          lines.append(text)
        }
        out[b.part] = instrumentName(lines.joined(separator: " "))
      }
      return out
    }
    let long = try names(on: systems[0])
    // short names: the next systems, each part from the first that has one (a system the layout split in two
    // still gives every part its name)
    var short: [String] = []
    for system in systems.dropFirst().prefix(3) {
      let found = try names(on: system)
      short = short.isEmpty ? found : zip(short, found).map { $0.isEmpty ? $1 : $0 }
      if !short.contains(where: \.isEmpty) { break }
    }
    return (long, short)
  }

  static let route = "On-device text reader (PP-OCRv6 small)"

  static func overlaps(_ a: Box, _ b: Box) -> Bool {
    min(a.x1, b.x1) > max(a.x0, b.x0) && min(a.y1, b.y1) > max(a.y0, b.y0)
  }

  /// Reads a phrase: its box padded a little, as one line of text.
  static func readPhrase(_ phrase: Phrase, page: LocalChordReader.Image, model: LocalChordReader.Model) throws
    -> Phrase
  {
    let pad = max(2, Int(0.25 * Double(phrase.box.h)))
    let x0 = max(0, phrase.box.x0 - pad), y0 = max(0, phrase.box.y0 - pad)
    let x1 = min(page.width, phrase.box.x1 + pad), y1 = min(page.height, phrase.box.y1 + pad)
    guard x1 > x0, y1 > y0 else { return phrase }
    var pixels = [UInt8](repeating: 255, count: (x1 - x0) * (y1 - y0))
    for y in y0..<y1 { for x in x0..<x1 { pixels[(y - y0) * (x1 - x0) + x - x0] = page.pixels[y * page.width + x] } }
    let reading = try model.read(LocalChordReader.Image(width: x1 - x0, height: y1 - y0, pixels: pixels))
    var out = phrase
    out.text = reading.text.trimmingCharacters(in: .whitespaces)
    out.score = reading.score
    return out
  }

  // MARK: finding text

  /// Lines of text in a region of the page (the header, the space under the last staff), split into phrases at
  /// gaps wider than a letter and a bit: a title and a composer printed on one line come apart.
  static func phrases(
    page: LocalChordReader.Image, rows: Range<Int>, cols: Range<Int>, sp: Double, tallest: Double = 8
  ) -> [Box] {
    let rows = max(0, rows.lowerBound)..<min(page.height, rows.upperBound)
    guard rows.count > 2, cols.count > 2 else { return [] }
    let w = cols.count, h = rows.count
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
      let row = (rows.lowerBound + y) * page.width + cols.lowerBound
      for x in 0..<w where page.pixels[row + x] < 160 { mask[y * w + x] = true }
      // a horizontal run longer than any letter stroke is a rule, an underline or a staff line: an underline
      // touching a title would make the title one unreadable piece
      var x = 0
      while x < w {
        guard mask[y * w + x] else { x += 1; continue }
        var end = x
        while end < w && mask[y * w + end] { end += 1 }
        if Double(end - x) >= 5 * sp { for i in x..<end { mask[y * w + i] = false } }
        x = end
      }
    }
    let comps = ChordFinder.label8(mask, width: w, height: h).map(\.0).filter { c in
      let ch = Double(c.h), cw = Double(c.w)
      return Double(c.area) >= 0.05 * sp * sp && ch <= tallest * sp && cw <= 0.6 * Double(page.width)
        && !(ch <= 0.35 * sp && cw >= 3 * sp)   // a rule or a staff line, not a letter
    }
    // lines: a piece joins the line whose typical letter (its pieces' median top and bottom) it overlaps by half;
    // measured against the whole line instead, two lines set close together grow into one
    var lines: [[ChordFinder.Component]] = []
    func core(_ line: [ChordFinder.Component]) -> (Int, Int) {
      let tops = line.map(\.y0).sorted(), bottoms = line.map(\.y1).sorted()
      return (tops[tops.count / 2], bottoms[bottoms.count / 2])
    }
    for c in comps.sorted(by: { $0.y0 + $0.y1 < $1.y0 + $1.y1 }) {
      if let i = lines.lastIndex(where: { line in
        let (y0, y1) = core(line)
        return Double(min(y1, c.y1) - max(y0, c.y0)) >= 0.5 * Double(max(1, min(c.h, y1 - y0)))
      }) {
        lines[i].append(c)
      } else {
        lines.append([c])
      }
    }
    // one line started twice (a stray mark began a second line at its height): lines whose typical letters
    // overlap by half are one
    var merged = true
    while merged {
      merged = false
      outer: for i in lines.indices {
        for j in lines.indices where j > i {
          let (a0, a1) = core(lines[i]), (b0, b1) = core(lines[j])
          if Double(min(a1, b1) - max(a0, b0)) >= 0.5 * Double(max(1, min(a1 - a0, b1 - b0))) {
            lines[i] += lines[j]
            lines.remove(at: j)
            merged = true
            break outer
          }
        }
      }
    }
    var out: [Box] = []
    for line in lines {
      let pieces = line.sorted { $0.x0 < $1.x0 }
      let tall = pieces.map(\.h).max() ?? 0
      let letter = median(pieces.map { Double($0.h) }.filter { $0 >= 0.4 * Double(tall) })
      var current: Box?
      var count = 0
      func flush() {
        if let b = current, Double(b.h) >= 0.6 * sp, count >= 2 || b.w >= b.h {
          out.append(Box(
            x0: b.x0 + cols.lowerBound, y0: b.y0 + rows.lowerBound, x1: b.x1 + cols.lowerBound,
            y1: b.y1 + rows.lowerBound))
        }
        current = nil
        count = 0
      }
      for c in pieces {
        if let b = current, Double(c.x0 - b.x1) > 1.3 * letter { flush() }
        if let b = current {
          current = Box(x0: min(b.x0, c.x0), y0: min(b.y0, c.y0), x1: max(b.x1, c.x1), y1: max(b.y1, c.y1))
        } else {
          current = Box(x0: c.x0, y0: c.y0, x1: c.x1, y1: c.y1)
        }
        count += 1
      }
      flush()
    }
    return out.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
  }

  /// The finder's words joined into runs: same staff and line (half their height overlapping), at most a letter
  /// and a bit apart. A boxed rehearsal mark stays on its own.
  static func wordPhrases(_ words: [ChordFinder.Proposal]) -> [Phrase] {
    var out: [Phrase] = []
    for w in words.sorted(by: { ($0.order, $0.x0) < ($1.order, $1.x0) }) {
      let box = Box(x0: w.x0, y0: w.y0, x1: w.x1, y1: w.y1)
      if w.kind != .rehearsal, let i = out.lastIndex(where: { p in
        guard let first = p.words.first, first.staff == w.staff, first.kind != .rehearsal,
          (first.kind == .lineAbove) == (w.kind == .lineAbove)
        else { return false }
        let overlap = min(p.box.y1, box.y1) - max(p.box.y0, box.y0)
        let letter = Double(max(p.words.map { $0.y1 - $0.y0 }.max() ?? 0, box.h))
        return Double(overlap) >= 0.4 * Double(min(p.box.h, box.h)) && Double(box.x0 - p.box.x1) <= 1.3 * letter
          && box.x0 >= p.box.x0
      }) {
        out[i].words.append(w)
        out[i].box = Box(
          x0: min(out[i].box.x0, box.x0), y0: min(out[i].box.y0, box.y0), x1: max(out[i].box.x1, box.x1),
          y1: max(out[i].box.y1, box.y1))
      } else {
        out.append(Phrase(box: box, words: [w]))
      }
    }
    return out
  }

  // MARK: what a phrase says

  /// Navigation spelled as MuseScore's MusicXML import matches jumps and markers, or nil.
  static func navigation(_ text: String) -> String? {
    // D.S. or D.C. inside a longer instruction ("after fourth verse, D.S. al fifth verse al Coda")
    if let range = text.range(of: #"\b(D\.\s?[SC]\.?|Dal\s+Segno|Da\s+Capo)"#, options: [.regularExpression, .caseInsensitive]),
      range.lowerBound != text.startIndex
    {
      return navigation(String(text[range.lowerBound...]))
    }
    let letters = String(text.lowercased().filter(\.isLetter))
    guard !letters.isEmpty else { return nil }
    let ds = letters.hasPrefix("dalsegno") || letters.hasPrefix("ds")
    let dc = letters.hasPrefix("dacapo") || letters.hasPrefix("dc")
    if ds || dc {
      let base = ds ? "D.S." : "D.C."
      let rest = letters.dropFirst(letters.hasPrefix("dalsegno") ? 8 : letters.hasPrefix("dacapo") ? 6 : 2)
      if rest.isEmpty { return base }
      if rest.hasPrefix("al") || rest.hasPrefix("to") {
        if rest.hasSuffix("coda") { return base + " al Coda" }
        if rest.hasSuffix("fine") { return base + " al Fine" }
      }
      return nil
    }
    switch letters {
    case "tocoda": return "To Coda"
    case "coda": return text.contains("C") ? "Coda" : nil
    case "fine": return text.contains("F") ? "Fine" : nil
    case "segno": return "Segno"
    default: return nil
    }
  }

  /// A rehearsal mark's text: one to three letters or digits.
  static func rehearsalMark(_ text: String) -> String? {
    let mark = String(text.filter { $0.isLetter || $0.isNumber }).uppercased()
    guard (1...3).contains(mark.count), mark.allSatisfy({ ("A"..."Z").contains($0) || $0.isNumber }) else {
      return nil
    }
    return mark
  }

  /// A metronome number: "= 120" (whatever the reader made of the note before it), 30 to 320.
  static func metronome(_ text: String) -> Int? {
    guard let range = text.range(of: #"=\s*(c(a)?\.?\s*)?\d{2,3}"#, options: .regularExpression) else { return nil }
    let digits = text[range].filter(\.isNumber)
    guard let bpm = Int(digits), (30...320).contains(bpm) else { return nil }
    return bpm
  }

  private static let tempoVocabulary: Set<String> = [
    "swing", "ballad", "medium", "bossa", "nova", "latin", "funk", "rock", "waltz", "slow", "slowly", "fast", "bright",
    "up", "moderato", "allegro", "allegretto", "andante", "adagio", "largo", "lento", "presto", "vivace", "rubato",
    "freely", "tempo", "shuffle", "samba", "even", "8ths", "eighths", "straight", "groove", "jazz", "blues",
    "calypso", "mambo", "cha", "bolero", "march", "moderate", "moderately", "brisk", "lively", "gently",
    "med", "easy", "relaxed", "medium-up", "uptempo", "reggae", "ska", "afro", "cuban", "gospel", "boogaloo",
  ]

  /// Tempo or style wording ("Medium Swing", "Bossa Nova", "Moderato").
  static func isTempoWords(_ text: String) -> Bool {
    let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    return !tokens.isEmpty && tokens.contains(where: tempoVocabulary.contains)
      && tokens.filter(tempoVocabulary.contains).count * 2 >= tokens.count
  }

  /// Lyrics the finder kept as text over a staff: syllables joined by hyphens ("nev-er"), a melisma line ("miles;_"),
  /// or words all in lowercase that are not a performance instruction ("your", "beast.").
  static func lyricLike(_ text: String) -> Bool {
    if text.range(of: #"[a-z]-[a-z]|_"#, options: .regularExpression) != nil { return true }
    let tokens = text.split { !$0.isLetter }.map(String.init)
    guard !tokens.isEmpty, tokens.allSatisfy({ $0 == $0.lowercased() }) else { return false }
    if text.contains("(") { return false }
    let instructions: Set<String> = [
      "cue", "till", "until", "end", "solo", "solos", "tacet", "repeat", "repeats", "play", "only", "last", "time",
      "simile", "fine", "coda", "vamp", "fade", "out", "rit", "rall", "accel", "tempo", "ad", "lib", "fill", "break",
      "segue", "attacca", "open", "drums", "bass", "piano", "tutti", "unison", "octave", "higher", "lower", "x",
    ]
    return !tokens.contains(where: { instructions.contains($0) })
  }

  static func sectionWords(_ text: String) -> Bool {
    let first = text.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
    return ["intro", "verse", "chorus", "bridge", "interlude", "outro", "tag", "solo", "solos", "vamp", "ending",
            "head", "refrain"].contains(first)
  }

  /// Staff text worth writing: read with confidence, words rather than marks, and not a chord or a dynamic.
  static func staffText(_ phrase: Phrase) -> String? {
    let text = phrase.text.replacingOccurrences(of: "■", with: "").trimmingCharacters(in: .whitespaces)
    let letters = text.filter(\.isLetter)
    guard phrase.score >= 0.8, letters.count >= 3,
      letters.lowercased().contains(where: { "aeiouy".contains($0) })
    else { return nil }
    if ChordText.modelSymbols(visibleText: text, proposedChord: text).verdict != .blocked { return nil }
    if chordShaped(text) {
      if ProcessInfo.processInfo.environment["SCANNER_TEXT_DEBUG"] != nil { print("DROPPED CHORD-SHAPED \"\(text)\"") }
      return nil
    }
    let dynamics: Set<String> = ["ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "sfz", "fp", "cresc", "dim"]
    if dynamics.contains(letters.lowercased()) { return nil }
    if lyricLike(text) { return nil }
    return text
  }

  /// A chord the reader could not make out ("Dba7(#11)Ba9"): a root letter, then no space, a number or bracket
  /// within it. Better left out than printed over the staff as words.
  static func chordShaped(_ text: String) -> Bool {
    let tokens = text.split(whereSeparator: \.isWhitespace)
    return !tokens.isEmpty && tokens.allSatisfy { t in
      t.count >= 4 && "ABCDEFG".contains(t.first!) && t.contains(where: { $0.isNumber || $0 == "(" })
        && t.dropFirst().filter(\.isLetter).allSatisfy { !"eiou".contains($0) || t.contains("sus") }
    }
  }

  // MARK: the header

  /// Title, composer, arranger and tempo from the lines above the first system: the tallest centred line is the
  /// title; a line set right, or opening with "by", "music by" or a dash, names the composer; a line opening with
  /// "arr" the arranger; a metronome mark or tempo wording set left the tempo. Page numbers and copyright lines
  /// are left out.
  /// `sp`: a title is at least 1.6 staff spaces tall.
  static func headerMetadata(_ lines: [Phrase], pageWidth: Int, sp: Double = 0)
    -> (metadata: AppleScoreMetadata?, used: [Box])
  {
    var title: [Phrase] = []
    var composer = "", arranger = "", tempoText = "", copyright = ""
    var bpm = 0
    var used: [Box] = []
    let width = Double(pageWidth)
    let readable = lines.filter { $0.score >= 0.5 && $0.text.contains(where: \.isLetter) || metronome($0.text) != nil }
      .sorted { ($0.box.y0, $0.box.x0) < ($1.box.y0, $1.box.x0) }
    var composerBlock: Box?, lyricBlock: Box?
    for var line in readable {
      // a page number printed on the title's line ("429 Med. Funk")
      if let number = line.text.range(of: #"^\s*\d{1,4}\s+(?=\D)"#, options: .regularExpression) {
        line.text = String(line.text[number.upperBound...])
      }
      let text = line.text.trimmingCharacters(in: .whitespaces)
      let lower = text.lowercased()
      let right = line.box.cx > 0.62 * width && Double(line.box.x1) > 0.8 * width
      // navigation over the first system is staff text, read there
      if navigation(text) != nil { continue }
      // a metronome mark whose "=" a segno or the note drew over ("A  92"), set left at the top
      if bpm == 0, line.box.cx < 0.45 * width,
        let match = text.range(of: #"^\S?\.?\s*=?\s*(\d{2,3})$"#, options: .regularExpression),
        let value = Int(text[match].filter(\.isNumber).suffix(3)), (40...240).contains(value)
      {
        bpm = value
        tempoText = ""   // the number alone: what else was read there is the drawn-over mark
        used.append(line.box)
        continue
      }
      if let block = lyricBlock, right, line.box.y0 - block.y1 <= line.box.h {
        // the lyricist's name running on ("Lyric: William / Engvick")
        lyricBlock = Box(x0: block.x0, y0: block.y0, x1: block.x1, y1: line.box.y1)
        used.append(line.box)
        continue
      }
      if lower.hasPrefix("lyric") || lower.hasPrefix("words") && !lower.contains("music"),
        let block = composerBlock, line.box.y0 - block.y1 <= 2 * line.box.h
      {
        lyricBlock = line.box
        // the lyricist's credit under the composer's, and its continuation lines
        composerBlock = Box(x0: block.x0, y0: block.y0, x1: block.x1, y1: line.box.y1)
        used.append(line.box)
        continue
      }
      // a credit set right runs on over several lines ("Music: Alec Wilder / and Morty Palitz", or one name a line)
      if let block = composerBlock, right, line.box.y0 - block.y1 <= line.box.h,
        lower.hasPrefix("and ") || lower.hasPrefix("& ") || nameLike(text)
      {
        composer += composer.isEmpty ? text : lower.hasPrefix("and ") || lower.hasPrefix("& ") ? " " + text : ", " + text
        composerBlock = Box(x0: min(block.x0, line.box.x0), y0: block.y0, x1: max(block.x1, line.box.x1), y1: line.box.y1)
        used.append(line.box)
        continue
      }
      if lower.contains("©") || lower.contains("copyright") {
        copyright = text
      } else if let value = metronome(text) {
        bpm = value
        tempoText = text   // the words around the mark are kept below, in tempoWording
      } else if lower.hasPrefix("arr") {
        arranger = strip(text, ["arranged by", "arr.", "arr:", "arr"])
      } else if lower.hasPrefix("lyric") || lower.hasPrefix("words") && !lower.contains("music") {
        // a lyricist's credit is not the composer, and never the title (nor staff text)
        lyricBlock = line.box
      } else if isTempoWords(text) && line.box.cx < 0.45 * width {
        tempoText = tempoText.isEmpty ? text : tempoText
      } else if lower.hasPrefix("music") || lower.hasPrefix("words and music") || lower.hasPrefix("by ")
        || lower.hasPrefix("composed by") || text.hasPrefix("-") || text.hasPrefix("–")
        || (right && nameLike(text))
      {
        if composer.isEmpty || lower.contains("music") {
          composer = strip(text, ["words and music by", "music by", "music:", "music", "composed by", "by", "-", "–"])
          composerBlock = line.box
        }
      } else if text.filter(\.isLetter).count >= 3 && Double(line.box.h) >= 2.2 * sp && line.box.cx < 0.72 * width {
        title.append(line)
        continue
      } else {
        continue
      }
      used.append(line.box)
    }
    // the title: the tallest line, with any line of the same height beside it
    var titleText = ""
    if let tallest = title.max(by: { $0.box.h < $1.box.h }) {
      let row = title.filter {
        abs($0.box.h - tallest.box.h) <= tallest.box.h / 4
          && min($0.box.y1, tallest.box.y1) - max($0.box.y0, tallest.box.y0) > tallest.box.h / 2
          && ($0.box == tallest.box || $0.text.filter(\.isLetter).count >= 3)
      }.sorted { $0.box.x0 < $1.box.x0 }
      // a title set over two lines: a line of nearly the same size just under it, overlapping it across
      let below = title.filter { t in
        !row.contains { $0.box == t.box } && t.box.y0 > tallest.box.y1 - tallest.box.h / 4
          && Double(t.box.y0 - tallest.box.y1) <= Double(tallest.box.h)
          && Double(t.box.h) >= 0.75 * Double(tallest.box.h)
          && min(t.box.x1, tallest.box.x1) > max(t.box.x0, tallest.box.x0)
          && t.score >= 0.8 && t.text.first?.isUppercase == true
      }.sorted { $0.box.x0 < $1.box.x0 }
      titleText = (row + below).map(\.text).joined(separator: " ")
      used += (row + below).map(\.box)
    }
    let meta = AppleScoreMetadata(
      title: titleText, subtitle: "", composer: composer, arranger: arranger, partName: "",
      tempoText: tempoWording(tempoText),
      beatUnit: "", bpm: bpm, copyright: copyright)
    return (meta.isEmpty ? nil : meta, used)
  }

  /// Tempo wording without a rehearsal letter read into its start ("A Bright = 120", "AMedium Swing = 100").
  static func tempoWording(_ text: String) -> String {
    var text = text
    // the metronome mark goes as a number of its own: keep the words before it, without the note the reader
    // made a letter of ("Bright = 120" -> "Bright", "Medium Swing J = 100" -> "Medium Swing", "J. = 60" -> "")
    if let eq = text.firstIndex(of: "=") {
      var before = text[..<eq].split(separator: " ").map(String.init)
      if let last = before.last, last.filter({ $0 != "." }).count <= 1 { before.removeLast() }
      text = before.joined(separator: " ")
    }
    var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = tokens.first else { return text }
    let lower = first.lowercased().filter(\.isLetter)
    if first.count == 1 && first.first!.isUppercase && tokens.count > 1 && tokens[1].first?.isLetter == true {
      tokens.removeFirst()
    } else if first.count > 2, first.first!.isUppercase, first.dropFirst().first!.isUppercase,
      tempoVocabulary.contains(String(lower.dropFirst()))
    {
      tokens[0] = String(first.dropFirst())
    }
    let out = tokens.joined(separator: " ")
    return out.filter(\.isLetter).count <= 1 ? "" : out
  }

  /// A person's name as a credit prints it: two or more words, mostly capitalised, no brackets or digits
  /// ("CHICK COREA", "Paul Weston", "-JOHN COLTRANE").
  static func nameLike(_ text: String) -> Bool {
    guard !text.contains(where: { "()[]".contains($0) || $0.isNumber }) else { return false }
    let words = text.split { !$0.isLetter && $0 != "'" && $0 != "." }.filter { $0.count >= 2 }
    guard words.count >= 2 else { return false }
    return words.filter { $0.first!.isUppercase }.count * 3 >= words.count * 2
  }

  private static func strip(_ text: String, _ prefixes: [String]) -> String {
    var out = text.trimmingCharacters(in: .whitespaces)
    for prefix in prefixes where out.lowercased().hasPrefix(prefix) {
      out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
      break
    }
    return out
  }

  // MARK: tempo

  /// The beat a metronome number counts when no note is printed: a dotted quarter in 6/8, 9/8 and 12/8, a half
  /// in x/2, an eighth in other x/8, otherwise a quarter. From the score's first time signature.
  static func meterBeatUnit(_ xml: Data) -> String {
    guard let text = String(data: xml, encoding: .utf8),
      let beats = firstNumber(in: text, tag: "beats"), let type = firstNumber(in: text, tag: "beat-type")
    else { return "quarter" }
    switch type {
    case 8 where beats >= 6 && beats % 3 == 0: return "dotted-quarter"
    case 16 where beats >= 6 && beats % 3 == 0: return "dotted-eighth"
    case 2: return "half"
    case 8: return "eighth"
    case 1: return "whole"
    default: return "quarter"
    }
  }

  private static func firstNumber(in text: String, tag: String) -> Int? {
    guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
    else { return nil }
    return Int(text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces))
  }

  /// A note value named in words ("dotted quarter = 60", "half note = 80").
  static func namedNoteValue(_ text: String) -> String? {
    let lower = text.lowercased()
    let names = [("half", "half"), ("minim", "half"), ("quarter", "quarter"), ("crotchet", "quarter"),
                 ("eighth", "eighth"), ("quaver", "eighth"), ("whole", "whole")]
    guard let name = names.first(where: { lower.contains($0.0) })?.1 else { return nil }
    return lower.contains("dot") ? "dotted-" + name : name
  }

  /// The note printed before "=" in a metronome mark, from its ink: a hollow head is a half note, a filled one a
  /// quarter (an eighth with a flag), a small dot after it makes it dotted. Nil when no note and "=" are found.
  static func printedNoteValue(page: LocalChordReader.Image, box: Box, sp: Double, text: String? = nil) -> String? {
    // the reader makes a printed note one character ("J", "d", "J."); a word before "=", or no "=" read at all,
    // means none is printed to go by
    if let text {
      guard let eq = text.firstIndex(of: "=") else { return nil }
      let before = text[..<eq].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
      if before.filter({ $0 != "." }).count > 1 { return nil }
    }
    let pad = Int(0.3 * Double(box.h))
    let x0 = max(0, box.x0 - pad), y0 = max(0, box.y0 - pad)
    let x1 = min(page.width, box.x1 + pad), y1 = min(page.height, box.y1 + pad)
    let w = x1 - x0, h = y1 - y0
    guard w > 4, h > 4 else { return nil }
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w where page.pixels[(y0 + y) * page.width + x0 + x] < 160 { mask[y * w + x] = true } }
    let pieces = ChordFinder.label8(mask, width: w, height: h).filter { $0.0.area >= 4 }
    let comps = pieces.map(\.0)
    // "=": two flat strokes, one above the other
    var equals: Int?
    for a in comps where a.w >= 2 * a.h {
      for b in comps where b.y0 > a.y1 && b.w >= 2 * b.h
        && Double(min(a.x1, b.x1) - max(a.x0, b.x0)) >= 0.6 * Double(min(a.w, b.w))
        && Double(b.y0 - a.y1) <= 2.5 * Double(max(a.h, b.h)) + 2
      {
        equals = min(equals ?? Int.max, min(a.x0, b.x0))
      }
    }
    guard let eq = equals else { return nil }
    // the note: the tallest piece just left of "="
    let left = pieces.filter { $0.0.x1 <= eq }
    guard let note = left.filter({ Double($0.0.h) >= 0.5 * Double(box.h) }).max(by: { $0.0.x1 < $1.0.x1 }) else {
      return nil
    }
    let n = note.0
    let hollow = ChordFinder.holes(note.1, w: n.w, h: n.h) >= 1
    let stem = Double(n.h) >= 1.6 * Double(n.w) || Double(n.h) >= 2.2 * sp
    var value: String
    if !stem {
      guard hollow else { return nil }
      value = "whole"
    } else if hollow {
      value = "half"
    } else {
      value = Double(n.w) >= 0.62 * Double(n.h) ? "eighth" : "quarter"
    }
    // a dot: a small round piece after the note, in its lower half
    let dotted = left.contains { p in
      let c = p.0
      return c.x0 >= n.x1 - 1 && c.x1 <= eq && Double(c.h) <= 0.3 * Double(n.h) && Double(c.w) <= 0.3 * Double(n.h)
        && c.w > 0 && c.h > 0 && Double(c.w) / Double(c.h) < 2 && Double(c.h) / Double(c.w) < 2
        && Double(c.y0 + c.y1) / 2 > Double(n.y0) + 0.5 * Double(n.h)
    }
    if dotted { value = "dotted-" + value }
    return value
  }

  private static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
  }
}
