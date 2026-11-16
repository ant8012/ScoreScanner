import Foundation
import OnnxRuntimeBindings

/// Reads chord symbols on this device, with no network: the chord finder's word boxes (`ChordFinder`), each cut
/// from the page and read by a PP-OCRv6 small text recogniser fine-tuned on chord symbols (round 3 in
/// `tools/chordfind`, exported to ONNX by `export_onnx.py`).
///
/// Crops and the model's input are prepared exactly as `tools/chordfind` prepares them for its benchmark
/// (`export_crops.py`, then PaddleX's recogniser preprocessing), so the benchmark's readings carry over.
public enum LocalChordReader {
  static let modelFile = "chord_rec.onnx"
  /// The standard PP-OCRv6 small recogniser (not fine-tuned), for the page's other text (`LocalTextReader`).
  static let textModelFile = "text_rec.onnx"
  /// Both models use PP-OCRv6's character list.
  static let dictionaryFile = "chord_rec_dict.txt"

  /// Whether `models` holds the chord reading model.
  public static func available(models: URL) -> Bool {
    let files = FileManager.default
    return files.fileExists(atPath: models.appendingPathComponent(modelFile).path)
      && files.fileExists(atPath: models.appendingPathComponent(dictionaryFile).path)
  }

  /// What the model read in one crop, and its mean confidence over the characters it kept.
  public struct Reading: Sendable, Equatable {
    public let text: String
    public let score: Double
  }

  /// Where the finder's words go in the written score, for one layout staff: the scanned staff
  /// (`ScanResult.staffs` index) written from it, whether that is the lower staff of a grand staff, and the measure
  /// (0 the staff's first) each of its bars falls in.
  struct WordStaff: Sendable {
    let staff: Int
    let lowerOfGrandStaff: Bool
    let barMeasures: [Int]
  }

  /// An 8-bit grey image, row major.
  struct Image {
    let width: Int, height: Int
    var pixels: [UInt8]
  }

  // MARK: the model

  /// One loaded model. Confined to the caller's task: ORT objects never cross actor boundaries.
  final class Model {
    private let env: ORTEnv
    private let session: ORTSession
    private let input: String, output: String
    /// Index 0 is the CTC blank and the last entry a space (the model was trained with use_space_char).
    let characters: [String]

    /// `file`: the chord model (default) or `textModelFile`.
    init(models: URL, file: String = LocalChordReader.modelFile) throws {
      guard FileManager.default.fileExists(atPath: models.appendingPathComponent(file).path),
        FileManager.default.fileExists(atPath: models.appendingPathComponent(dictionaryFile).path)
      else {
        throw ScannerError.invalid("The \(file == modelFile ? "chord" : "text") reading model is missing")
      }
      let data = try Data(contentsOf: models.appendingPathComponent(dictionaryFile))
      // One character per line. Split on the byte, not on Swift's grapheme clusters, so a combining mark on a line
      // of its own stays its own entry.
      var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map {
        String(decoding: $0, as: UTF8.self)
      }
      if lines.last == "" { lines.removeLast() }
      characters = [""] + lines + [" "]
      env = try ORTEnv(loggingLevel: .warning)
      session = try ORTSession(
        env: env, modelPath: models.appendingPathComponent(file).path,
        sessionOptions: RuntimePolicy.options())
      input = try session.inputNames().first ?? "x"
      output = try session.outputNames().first ?? "fetch_name_0"
    }

    func read(_ image: Image) throws -> Reading {
      let (data, width) = LocalChordReader.modelInput(image)
      let value = try tensor(data, type: .float, shape: [1, 3, 48, width])
      let out = try session.run(withInputs: [input: value], outputNames: [output], runOptions: nil)
      let result = try require(output, in: out)
      let shape = try result.tensorTypeAndShapeInfo().shape.map(\.intValue)
      guard shape.count == 3, shape[2] == characters.count else {
        throw ScannerError.invalid("The chord reading model returned an unexpected shape \(shape)")
      }
      return LocalChordReader.decode(try result.tensorData() as Data, steps: shape[1], classes: shape[2],
                                     characters: characters)
    }
  }

  /// Greedy CTC decoding: the best class at each step, repeats collapsed, blanks dropped.
  static func decode(_ data: Data, steps: Int, classes: Int, characters: [String]) -> Reading {
    data.withUnsafeBytes { raw -> Reading in
      let probs = raw.bindMemory(to: Float.self)
      var text = "", scores: [Float] = [], last = -1
      for t in 0..<steps {
        let row = t * classes
        var best = 0, top = probs[row]
        for c in 1..<classes where probs[row + c] > top {
          best = c
          top = probs[row + c]
        }
        if best != last && best != 0 {
          text += characters[best]
          scores.append(top)
        }
        last = best
      }
      let mean = scores.isEmpty ? 0 : Double(scores.reduce(0, +)) / Double(scores.count)
      return Reading(text: text, score: mean)
    }
  }

  /// The chords a reading holds, judged as the cloud path judges a reading (`ChordText.modelSymbols`): chords the
  /// grammar knows, and chord-shaped ones it does not (C7sus4); nothing for "■" (the model's "not a chord"), words
  /// or numbers.
  static func judged(_ text: String) -> (chords: [String], verdict: ChordText.Verdict) {
    let text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !text.contains("■") else { return ([], .blocked) }
    let judged = ChordText.modelSymbols(visibleText: text, proposedChord: text)
    return judged.verdict == .blocked ? ([], .blocked) : judged
  }

  static func accepted(_ text: String) -> [String] { judged(text).chords }

  // MARK: reading a page into its score

  /// Reads the chord symbols of one scanned page and writes them into its score, each at the measure and beat the
  /// finder placed it (the beat from the note under the chord, or the nearest strong beat).
  /// One page read for chords, and what the text pass needs from it.
  struct PageChords {
    let scan: ScanResult
    let analysis: AppleChordAnalysis
    /// Finder words that became chords (or a chord's bass), as "x0,y0,x1,y1".
    let chordWords: Set<String>
    /// Single letters left out because they open a line on a chord's beat: unboxed rehearsal letters.
    let lineStartLetters: [(word: String, letter: String)]
  }

  static func wordKey(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> String { "\(x0),\(y0),\(x1),\(y1)" }

  static func read(
    _ scan: ScanResult, model: Model, page number: Int, progress: @Sendable (String) -> Void = { _ in }
  ) throws -> (scan: ScanResult, analysis: AppleChordAnalysis) {
    let page = try readPage(scan, model: model, page: number, progress: progress)
    return (page.scan, page.analysis)
  }

  static func readPage(
    _ scan: ScanResult, model: Model, page number: Int, progress: @Sendable (String) -> Void = { _ in }
  ) throws -> PageChords {
    let start = Date()
    progress("Reading chord symbols")
    let page = Image(width: scan.pageWidth, height: scan.pageHeight, pixels: [UInt8](scan.page))
    let geometries = try scan.staffs.map { try StaffGeometry.decode($0.geometry) }
    // the measures of each scanned staff, from its left edge, measure starts and right edge
    let bounds = geometries.map { g in [g.minx] + g.barlines.map(\.x) + [g.maxx] }
    var labels: [Int: [Int: [Placed]]] = [:]
    var crops: [AppleChordCropAnalysis] = []
    var boxedLetters: [Placed] = []
    var skipped = (lower: 0, unplaced: 0, alternates: 0, basses: 0, strays: 0)
    for word in scan.chordWords where word.kind == .text {
      try Task.checkCancellation()
      // chords stand over the upper staff of a grand staff; text over the lower one is something else
      guard let target = scan.chordWordStaffs[word.staff], geometries.indices.contains(target.staff) else {
        skipped.unplaced += 1
        continue
      }
      if target.lowerOfGrandStaff {
        skipped.lower += 1
        continue
      }
      let g = geometries[target.staff], edges = bounds[target.staff]
      guard edges.count >= 2, let cut = crop(page: page, word: word, sp: g.unit) else { continue }
      let reading = try model.read(cut.image)
      let (chords, verdict) = judged(reading.text)
      let centre = Double(word.x0 + word.x1) / 2
      let measure = target.barMeasures.indices.contains(word.bar)
        ? min(target.barMeasures[word.bar], edges.count - 2)
        : max(0, min(edges.count - 2, (edges.lastIndex { $0 <= centre } ?? 0)))
      let index = crops.count
      let image = ChordImageCrop(
        staff: target.staff, voice: g.voice, system: g.system, bar: measure,
        pixels: Data(cut.image.pixels), width: cut.image.width, height: cut.image.height,
        pageX: cut.box.0, pageTop: cut.box.1, pageBottom: cut.box.3,
        barLeft: edges[measure], barRight: edges[measure + 1])
      crops.append(AppleChordCropAnalysis(
        cropIndex: index, page: number, crop: image,
        chords: chords.isEmpty
          ? [AppleChordReading(visibleText: reading.text, proposedChord: reading.text, acceptedChord: nil,
                               verdict: .blocked)]
          : chords.map {
            AppleChordReading(visibleText: reading.text, proposedChord: $0, acceptedChord: $0, verdict: verdict)
          },
        ignoredShortText: []))
      // a single letter in a box is a rehearsal mark, not a chord: a tall box often stands above the band the finder
      // looks at, so the finder sees the letter without its frame
      if chords.count == 1, chords[0].count == 1, boxed(page, word, sp: g.unit) {
        let label = ChordLabel(
          text: reading.text, chord: chords[0], confidence: Float(reading.score), x0: Double(word.x0),
          x1: Double(word.x1), bar: measure, measureNumber: nil, partID: nil, beat: nil, beatUnit: nil,
          timingSource: nil, timingStatus: nil, word: wordKey(word.x0, word.y0, word.x1, word.y1))
        if ProcessInfo.processInfo.environment["SCANNER_TEXT_DEBUG"] != nil {
          print("BOXED LETTER \"\(chords[0])\" \(word.x0),\(word.y0),\(word.x1),\(word.y1)")
        }
        boxedLetters.append(Placed(label: label, upper: word.upperRow, x0: word.x0, y0: word.y0, x1: word.x1,
                                   y1: word.y1, overNote: false, sp: g.unit))
        skipped.strays += 1
        continue
      }
      // several chords read in one word share its width; only a single one keeps the finder's beat
      let width = Double(word.x1 - word.x0) / Double(max(1, chords.count))
      for (k, chord) in chords.enumerated() {
        let x0 = Double(word.x0) + Double(k) * width
        let label = ChordLabel(
          text: reading.text, chord: chord, confidence: Float(reading.score), x0: x0, x1: x0 + width,
          bar: measure, measureNumber: nil, partID: nil, beat: chords.count == 1 ? word.beat : nil,
          beatUnit: nil, timingSource: chords.count == 1 && word.beat != nil ? "finder" : nil, timingStatus: nil,
          word: wordKey(word.x0, word.y0, word.x1, word.y1))
        labels[target.staff, default: [:]][measure, default: []].append(Placed(
          label: label, upper: word.upperRow, x0: word.x0, y0: word.y0, x1: word.x1, y1: word.y1,
          overNote: word.beatSource == "note", sp: g.unit))
      }
    }
    var letters: [Placed] = boxedLetters
    // a joined bass's own word is part of a chord too
    var joinedBasses: [String] = []
    let before = Set(labels.values.flatMap(\.values).flatMap { $0 }.compactMap(\.label.word))
    for staff in labels.keys {
      let (joined, dropped) = tidy(&labels[staff, default: [:]], letters: &letters)
      skipped.basses += joined
      skipped.strays += dropped
    }
    let after = Set(labels.values.flatMap(\.values).flatMap { $0 }.compactMap(\.label.word))
    let letterWords = Set(letters.map { wordKey($0.x0, $0.y0, $0.x1, $0.y1) })
    joinedBasses = before.subtracting(after).filter { !letterWords.contains($0) }.sorted()
    // A page that prints chord symbols prints many; one chord-like word on a page is something else (a piano
    // score's "E" read from a stray mark), so the page is taken to print none.
    let found = labels.values.flatMap(\.values).map(\.count).reduce(0, +)
    let lone = found == 1
    if lone { labels = [:] }
    var staffs: [ChordStaff] = []
    for staff in labels.keys.sorted() {
      let g = geometries[staff], edges = bounds[staff]
      let bars = (0..<(edges.count - 1)).map { m -> ChordBar in
        let here = labels[staff]?[m] ?? []
        // a chord of a second row over the line (alternate changes) gives way to the main row's chord on its beat
        let kept = here.filter { item in
          !item.upper || !here.contains { !$0.upper && $0.label.beat != nil && $0.label.beat == item.label.beat }
        }.map(\.label).sorted { $0.x0 < $1.x0 }
        skipped.alternates += here.count - kept.count
        return ChordBar(
          index: m, left: edges[m], right: edges[m + 1], text: kept.map(\.chord).joined(separator: " "),
          labels: kept, measureNumber: nil, partID: nil)
      }
      let top = g.band(pageHeight: scan.pageHeight)
      staffs.append(ChordStaff(
        staff: staff, voice: g.voice ?? scan.staffs[staff].voice, system: g.system ?? scan.staffs[staff].system,
        top: top.top, bottom: top.bottom, bars: bars, mappingStatus: "unresolved"))
    }
    try ChordMusicXML.map(
      &staffs, score: scan.xml, fallbackMeter: ChordMeter(beats: 4, beatType: 4), fitUnmatched: true)
    let xml = try ChordMusicXML.insertMapped(scan.xml, staffs: staffs).xml
    let seconds = Date().timeIntervalSince(start)
    let unmapped = staffs.flatMap(\.bars).flatMap(\.labels).filter { $0.measureNumber == nil }.count
    var notes: [String] = []
    if crops.isEmpty { notes.append("No chord symbols were found above the staves.") }
    if lone { notes.append("One chord-like word was found; the page was taken to print no chord symbols.") }
    if unmapped > 0 { notes.append("\(unmapped) chords could not be matched to a measure.") }
    if skipped.alternates > 0 { notes.append("\(skipped.alternates) alternate chords on the main chord's beat were left out.") }
    if skipped.unplaced > 0 { notes.append("\(skipped.unplaced) words over staves the score does not hold were not read.") }
    if skipped.basses > 0 { notes.append("\(skipped.basses) bass notes written below their chord were joined to it.") }
    if skipped.strays > 0 { notes.append("\(skipped.strays) single letters on another chord's beat were left out.") }
    let placed = ScanResult(
      xml: xml, rawXML: xml, staffs: scan.staffs, page: Data(), pageWidth: scan.pageWidth,
      pageHeight: scan.pageHeight, seconds: scan.seconds + seconds, repairedMeasures: 0)
    let analysis = AppleChordAnalysis(
      route: "On-device chord reader (PP-OCRv6 small, round 3)",
      routeNote: notes.isEmpty ? nil : notes.joined(separator: " "),
      crops: crops, seconds: seconds)
    var chordWords = Set<String>()
    for staff in staffs {
      for label in staff.bars.flatMap(\.labels) { if let key = label.word { chordWords.insert(key) } }
    }
    for label in joinedBasses { chordWords.insert(label) }
    return PageChords(
      scan: placed, analysis: analysis, chordWords: chordWords,
      lineStartLetters: letters.map { (wordKey($0.x0, $0.y0, $0.x1, $0.y1), $0.label.chord) })
  }

  /// A chord read on the page, with the word it came from.
  struct Placed {
    var label: ChordLabel
    let upper: Bool
    let x0: Int, y0: Int, x1: Int, y1: Int
    /// The finder took its beat from a note under it (rather than snapping it between notes).
    let overNote: Bool
    let sp: Double
    var bareRoot: Bool { label.chord.range(of: "^[A-G][b#]?$", options: .regularExpression) != nil }
  }

  /// Two readings the finder put on one beat of a measure, when one of them is a bare letter, are usually one chord
  /// and a piece of something else:
  /// - a bass written below and to the right of its chord ("D-7" then a lower "C" past the slash) joins the chord;
  /// - a rehearsal letter whose box the finder missed (the first word of the line), a sliver inside another chord's
  ///   box, or a letter off the chord's baseline (the C of "al Coda") is left out.
  /// Returns how many were joined and how many left out. Two real chords on one beat are spread by `ChordTiming`.
  static func tidy(_ measures: inout [Int: [Placed]]) -> (joined: Int, dropped: Int) {
    var letters: [Placed] = []
    return tidy(&measures, letters: &letters)
  }

  /// Whether a closed rectangle surrounds a word on the page: a line of ink above, below, left and right of it, each
  /// within a little over a staff space and running the word's whole width or height.
  static func boxed(_ page: Image, _ word: ChordFinder.Proposal, sp: Double) -> Bool {
    let reach = Int(1.3 * sp), pad = Int(0.2 * sp)
    func ink(_ x: Int, _ y: Int) -> Bool {
      x >= 0 && y >= 0 && x < page.width && y < page.height && page.pixels[y * page.width + x] < 128
    }
    func row(_ y: Int) -> Bool {
      let xs = (word.x0 - pad)..<(word.x1 + pad)
      return Double(xs.filter { ink($0, y) }.count) >= 0.85 * Double(xs.count)
    }
    func column(_ x: Int) -> Bool {
      let ys = word.y0..<word.y1
      return Double(ys.filter { ink(x, $0) }.count) >= 0.85 * Double(ys.count)
    }
    return ((word.y0 - reach)..<word.y0).contains(where: row)
      && ((word.y1 + 1)...(word.y1 + reach)).contains(where: row)
      && ((word.x0 - reach)..<word.x0).contains(where: column)
      && ((word.x1 + 1)...(word.x1 + reach)).contains(where: column)
  }

  /// `letters` receives the left-out letters that open their line (likely rehearsal letters).
  static func tidy(_ measures: inout [Int: [Placed]], letters: inout [Placed]) -> (joined: Int, dropped: Int) {
    var joined = 0, dropped = 0
    let all = measures.values.flatMap { $0 }
    let lineStart = all.map(\.x0).min()
    // basses, across the whole line: one may sit just past the bar line its chord stands before
    var removed = Set<String>()
    func key(_ p: Placed) -> String { "\(p.x0),\(p.y0),\(p.label.chord)" }
    for b in all where b.bareRoot {
      let bh = Double(b.y1 - b.y0)
      guard bh > 0 else { continue }
      let owner = all.filter { a in
        guard !a.bareRoot, !a.label.chord.contains("/"), !removed.contains(key(a)) else { return false }
        let aw = Double(a.x1 - a.x0), ah = Double(a.y1 - a.y0)
        return Double(b.x0) >= Double(a.x0) + 0.5 * aw && Double(b.x0) <= Double(a.x1) + 1.5 * a.sp && b.x1 > a.x1
          && Double(b.y1) > Double(a.y1) + 0.2 * ah && Double(b.y0) < Double(a.y1) + 0.5 * ah
      }.min { $0.x1 > $1.x1 }
      guard let a = owner else { continue }
      for m in measures.keys {
        for i in measures[m]!.indices where key(measures[m]![i]) == key(a) {
          measures[m]![i].label.chord += "/" + b.label.chord
        }
      }
      removed.insert(key(b))
      joined += 1
    }
    for m in measures.keys {
      measures[m]!.removeAll { removed.contains(key($0)) }
      let here = measures[m]!
      measures[m]!.removeAll { b in
        guard b.bareRoot, !b.overNote, let beat = b.label.beat else { return false }
        let stray = here.contains { a in
          guard !a.bareRoot, a.label.beat == beat else { return false }
          let ah = Double(a.y1 - a.y0)
          return b.x0 == lineStart || (b.x0 >= a.x0 && b.x1 <= a.x1) || abs(Double(b.y1 - a.y1)) > 0.5 * ah
        }
        if stray {
          dropped += 1
          if b.x0 == lineStart { letters.append(b) }
        }
        return stray
      }
    }
    return (joined, dropped)
  }

  // MARK: preparing a crop

  /// PaddleX's recogniser input for one crop: 48 px high keeping its shape, at least 320 px wide (zero padding on
  /// the right), three identical channels scaled to [-1, 1]. Returns the tensor and its width.
  static func modelInput(_ image: Image) -> (Data, Int) {
    let ratio = Double(image.width) / Double(image.height)
    var width = Int(48.0 * max(320.0 / 48.0, ratio))
    let resizedWidth: Int
    if width > 3200 {
      width = 3200
      resizedWidth = 3200
    } else {
      let natural = (48.0 * ratio).rounded(.up)
      resizedWidth = natural > Double(width) ? width : Int(natural)
    }
    let resized = bilinear(image, width: resizedWidth, height: 48)
    var values = [Float](repeating: 0, count: 3 * 48 * width)
    for y in 0..<48 {
      for x in 0..<resizedWidth {
        let v = (Float(resized.pixels[y * resizedWidth + x]) / 255 - 0.5) / 0.5
        for c in 0..<3 { values[(c * 48 + y) * width + x] = v }
      }
    }
    return (values.withUnsafeBufferPointer { Data(buffer: $0) }, width)
  }

  /// OpenCV's `INTER_LINEAR` resize for 8-bit images: pixel-centre mapping, 11-bit fixed-point weights.
  static func bilinear(_ image: Image, width: Int, height: Int) -> Image {
    if width == image.width && height == image.height { return image }
    let one = 2048
    func axis(_ source: Int, _ target: Int) -> (index: [Int], weight: [(Int, Int)]) {
      let scale = 1.0 / (Double(target) / Double(source))
      var index: [Int] = [], weight: [(Int, Int)] = []
      for d in 0..<target {
        var f = Float((Double(d) + 0.5) * scale - 0.5)
        var s = Int(f.rounded(.down))
        f -= Float(s)
        if s < 0 { f = 0; s = 0 }
        if s + 1 >= source { f = 0; s = source - 1 }
        let a0 = Int(((1 - f) * Float(one)).rounded(.toNearestOrEven))
        index.append(s)
        weight.append((a0, one - a0))
      }
      return (index, weight)
    }
    let (xs, xw) = axis(image.width, width)
    let (ys, yw) = axis(image.height, height)
    func row(_ y: Int) -> [Int] {
      (0..<width).map { d in
        let s = xs[d], (a0, a1) = xw[d]
        let base = y * image.width
        let right = s + 1 < image.width ? Int(image.pixels[base + s + 1]) * a1 : 0
        return Int(image.pixels[base + s]) * a0 + right
      }
    }
    var cache: [Int: [Int]] = [:]
    var out = [UInt8](repeating: 0, count: width * height)
    for d in 0..<height {
      let s0 = ys[d], s1 = min(ys[d] + 1, image.height - 1), (b0, b1) = yw[d]
      if cache[s0] == nil { cache[s0] = row(s0) }
      if cache[s1] == nil { cache[s1] = row(s1) }
      let r0 = cache[s0]!, r1 = cache[s1]!
      for x in 0..<width {
        let v = (r0[x] * b0 + r1[x] * b1 + (1 << 21)) >> 22
        out[d * width + x] = UInt8(max(0, min(255, v)))
      }
    }
    return Image(width: width, height: height, pixels: out)
  }

  /// Pillow's `Image.resize(..., Image.LANCZOS)` for 8-bit grey images: separable Lanczos-3, horizontal pass then
  /// vertical, 22-bit fixed-point weights, each pass clipped to 8 bits.
  static func lanczos(_ image: Image, width: Int, height: Int) -> Image {
    let precision = 22
    func filter(_ x: Double) -> Double {
      func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(x * .pi) / (x * .pi) }
      return -3 <= x && x < 3 ? sinc(x) * sinc(x / 3) : 0
    }
    func coefficients(_ inSize: Int, _ outSize: Int) -> (bounds: [(Int, Int)], weights: [[Int]]) {
      let scale = Double(inSize) / Double(outSize)
      let filterScale = max(scale, 1)
      let support = 3.0 * filterScale
      var bounds: [(Int, Int)] = [], weights: [[Int]] = []
      for o in 0..<outSize {
        let centre = (Double(o) + 0.5) * scale
        let ss = 1.0 / filterScale
        let lo = max(Int(centre - support + 0.5), 0)
        let hi = min(Int(centre + support + 0.5), inSize) - lo
        var k = (0..<max(0, hi)).map { filter((Double($0 + lo) - centre + 0.5) * ss) }
        let total = k.reduce(0, +)
        if total != 0 { k = k.map { $0 / total } }
        bounds.append((lo, max(0, hi)))
        weights.append(k.map { w in
          w < 0 ? Int(-0.5 + w * Double(1 << precision)) : Int(0.5 + w * Double(1 << precision))
        })
      }
      return (bounds, weights)
    }
    func clip(_ v: Int) -> UInt8 {
      if v >= (1 << precision) << 8 { return 255 }
      if v <= 0 { return 0 }
      return UInt8(v >> precision)
    }
    let (hb, hw) = coefficients(image.width, width)
    let (vb, vw) = coefficients(image.height, height)
    let needH = width != image.width, needV = height != image.height
    var source = image
    if needH {
      // only the rows the vertical pass will use
      let first = vb.first?.0 ?? 0
      let last = (vb.last.map { $0.0 + $0.1 }) ?? image.height
      let rows = needV ? (first, last) : (0, image.height)
      var out = [UInt8](repeating: 0, count: width * (rows.1 - rows.0))
      for y in rows.0..<rows.1 {
        for x in 0..<width {
          var ss = 1 << (precision - 1)
          let (lo, n) = hb[x]
          for i in 0..<n { ss += Int(image.pixels[y * image.width + lo + i]) * hw[x][i] }
          out[(y - rows.0) * width + x] = clip(ss)
        }
      }
      source = Image(width: width, height: rows.1 - rows.0, pixels: out)
      if needV {
        let shift = rows.0
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
          let (lo, n) = vb[y]
          for x in 0..<width {
            var ss = 1 << (precision - 1)
            for i in 0..<n { ss += Int(source.pixels[(lo - shift + i) * width + x]) * vw[y][i] }
            out[y * width + x] = clip(ss)
          }
        }
        return Image(width: width, height: height, pixels: out)
      }
      return source
    }
    guard needV else { return image }
    var out = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
      let (lo, n) = vb[y]
      for x in 0..<width {
        var ss = 1 << (precision - 1)
        for i in 0..<n { ss += Int(image.pixels[(lo + i) * image.width + x]) * vw[y][i] }
        out[y * width + x] = clip(ss)
      }
    }
    return Image(width: width, height: height, pixels: out)
  }

  /// A finder word cut from the page as `tools/chordfind/export_crops.py` cuts it: padded by 0.35 staff spaces,
  /// then enlarged (Lanczos, up to 4x) to about 96 px high. Specks under 0.6 staff spaces are not read.
  static func crop(page: Image, word: ChordFinder.Proposal, sp: Double) -> (image: Image, box: (Int, Int, Int, Int))? {
    let w = word.x1 - word.x0, h = word.y1 - word.y0
    if Double(max(w, h)) < 0.6 * sp { return nil }
    let pad = 0.35 * sp
    let x0 = Int(max(0, Double(word.x0) - pad)), y0 = Int(max(0, Double(word.y0) - pad))
    let x1 = Int(min(Double(page.width), Double(word.x1) + pad))
    let y1 = Int(min(Double(page.height), Double(word.y1) + pad))
    guard x1 > x0, y1 > y0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0))
    for y in y0..<y1 {
      for x in x0..<x1 { pixels[(y - y0) * (x1 - x0) + x - x0] = page.pixels[y * page.width + x] }
    }
    var image = Image(width: x1 - x0, height: y1 - y0, pixels: pixels)
    let scale = min(4.0, max(1.0, 96.0 / Double(image.height)))
    if scale > 1 {
      image = lanczos(
        image, width: Int((Double(image.width) * scale).rounded(.toNearestOrEven)),
        height: Int((Double(image.height) * scale).rounded(.toNearestOrEven)))
    }
    return (image, (x0, y0, x1, y1))
  }
}
