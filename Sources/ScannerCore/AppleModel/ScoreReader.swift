import Foundation

/// Which reader names the chord symbols.
public enum ChordReader: String, Sendable, CaseIterable {
  /// The chord finder and a chord recogniser that run on this device (`LocalChordReader`). No network.
  case onDevice
  /// Apple's model, on Private Cloud Compute (bar strips).
  case appleModel
}

/// Which reader reads the title, composer, tempo and staff text.
public enum TextReader: String, Sendable, CaseIterable {
  /// The standard PP-OCRv6 small recogniser on this device (`LocalTextReader`). No network.
  case onDevice
  /// Apple's model, on Private Cloud Compute.
  case appleModel
}

/// How a score is read. The notes are always read on this device; chord names and page text on this device too by
/// default, or by Apple's model.
public struct ScoreReadOptions: Sendable {
  /// Read the chord names above each staff.
  public var readChordNames = true
  /// Read rehearsal letters, D.S./Fine and section names with Apple's model. Only on pages that print chord names
  /// (lead sheets): on other pages the model has invented them. With chord reading off, this switch alone decides.
  /// It also decides whether the title, composer and tempo are read.
  public var readStaffText = true
  /// Which reader names the chords.
  public var chordReader = ChordReader.onDevice
  /// Which reader reads the title, composer, tempo and staff text.
  public var textReader = TextReader.onDevice
  /// Send the model's requests to Private Cloud Compute. The on-device model is not accurate enough for scores.
  public var preferPrivateCloud = true
  /// Let a reading that prefers Private Cloud Compute finish on the on-device model when PCC is unavailable or a
  /// request fails. Off: the reading stops with `AppleModelRouteError` instead.
  public var allowOnDeviceFallback = false
  /// How many Private Cloud Compute requests are kept in flight.
  public var cloudRequests = ScoreReadOptions.defaultCloudRequests

  public static let defaultCloudRequests = 4
  public static let cloudRequestRange = 1...8

  public init(
    readChordNames: Bool = true, readStaffText: Bool = true, preferPrivateCloud: Bool = true,
    allowOnDeviceFallback: Bool = false, cloudRequests: Int = ScoreReadOptions.defaultCloudRequests,
    chordReader: ChordReader = .onDevice, textReader: TextReader = .onDevice
  ) {
    self.chordReader = chordReader
    self.textReader = textReader
    self.readChordNames = readChordNames
    self.readStaffText = readStaffText
    self.preferPrivateCloud = preferPrivateCloud
    self.allowOnDeviceFallback = allowOnDeviceFallback
    self.cloudRequests = min(max(cloudRequests, Self.cloudRequestRange.lowerBound), Self.cloudRequestRange.upperBound)
  }

  /// Whether a reading with these options asks Apple's model anything. Off, it runs entirely on this device.
  public var usesAppleModel: Bool {
    switch chordReader {
    case .appleModel: readChordNames || readStaffText
    case .onDevice: readStaffText && textReader == .appleModel
    }
  }
}

/// A chord crop as the model saw it, named by page, system and bar, for inspecting a reading.
public struct ChordCropImage: Sendable {
  public let name: String
  public let png: Data
}

/// A finished reading: the score, and what Apple's model read from the page.
public struct ScoreReading: Sendable {
  /// The MusicXML with chords, title, composer, tempo, part names and staff text written in; `rawXML` is the same.
  public let score: DocumentScanResult
  /// Title, composer, arranger, tempo and instrument names from the top of the first page.
  public let metadata: AppleScoreMetadata?
  public let chords: AppleChordAnalysis
  public let text: AppleScoreTextAnalysis
  public let chordCrops: [ChordCropImage]

  /// The title printed on the first page, if one was read.
  public var title: String? {
    guard let title = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
    else { return nil }
    return title
  }
  /// Chord symbols that reached the score.
  public var chordCount: Int { ScoreReader.chordCount(in: score.xml) }
}

/// Reads a page image or a PDF into MusicXML: the notes on this device with copisteria, then the chord names,
/// title, composer and staff text with Apple's model, written into the score.
///
/// One reading at a time: the request limits and the fallback setting are shared by the whole process.
public enum ScoreReader {
  /// Reads one page image (JPEG, PNG, HEIC; a camera photo's orientation is applied).
  /// `title`: the title written when none is read from the page.
  public static func read(
    image: Data, title: String = "", models: URL = Scanner.bundledModels,
    options: ScoreReadOptions = ScoreReadOptions(),
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> ScoreReading {
    await configure(options)
    let local = try localModel(models: models, options: options)
    let localText = try localTextModel(models: models, options: options)
    let detached = Task.detached(priority: .userInitiated) {
      try Scanner.scan(image: image, models: models, title: title, progress: progress)
    }
    // The model loads while the notes are read, so the first batch is not also paying for the load.
    if options.usesAppleModel { AppleChordReader.prewarm(preferPrivateCloud: options.preferPrivateCloud) }
    let scan = try await withTaskCancellationHandler {
      try await detached.value
    } onCancel: {
      detached.cancel()
    }
    try Task.checkCancellation()
    let page = try await readPage(
      scan, number: 1, header: true, options: options, local: local, localText: localText, prefix: "",
      progress: progress)
    try Task.checkCancellation()
    let metadata = page.text.metadata
    let score = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: metadata?.title, composer: metadata?.composer, arranger: metadata?.arranger,
      tempo: metadata?.headerTempo, partNames: page.text.partNames ?? partNames(metadata?.partName),
      partAbbreviations: page.text.partAbbreviations ?? [],
      staffText: scoreTextDirections(from: page.text), into: DocumentScanResult(page.scan))
    return finished(score: score, metadata: metadata, chords: page.chords, text: page.text, crops: page.cropImages)
  }

  /// Reads every page of a PDF and joins them into one score, carrying the meter from page to page.
  /// `title`: the title written when none is read from the first page.
  public static func read(
    pdf data: Data, title: String = "", models: URL = Scanner.bundledModels,
    options: ScoreReadOptions = ScoreReadOptions(),
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> ScoreReading {
    await configure(options)
    let local = try localModel(models: models, options: options)
    let localText = try localTextModel(models: models, options: options)
    let count = try PDFScanner.pageCount(data: data)
    var pages: [ScanResult] = []
    var chordAnalyses: [AppleChordAnalysis] = []
    var textAnalyses: [AppleScoreTextAnalysis] = []
    var cropImages: [ChordCropImage] = []
    var textDirections: [ScoreTextDirection] = []
    var textSystemOffsets: [Int: Int] = [:]
    // Reading notes is processor work while the text readers wait on the model, and the two overlap almost
    // completely, so the next page is read while this one's text is. One page of lookahead bounds memory. Each
    // page starts in the meter the page before it ended in.
    func scanPage(_ index: Int, carriedMeter: String?) -> Task<ScanResult, Error> {
      let prefix = "Page \(index + 1) of \(count): "
      return Task.detached(priority: .userInitiated) {
        let image = try PDFScanner.renderPage(data: data, pageIndex: index)
        return try Scanner.scan(image: image, models: models, carriedMeter: carriedMeter) { progress(prefix + $0) }
      }
    }
    if options.usesAppleModel { AppleChordReader.prewarm(preferPrivateCloud: options.preferPrivateCloud) }
    var pending: Task<ScanResult, Error>? = scanPage(0, carriedMeter: nil)
    for index in 0..<count {
      try Task.checkCancellation()
      let number = index + 1
      let prefix = "Page \(number) of \(count): "
      progress(prefix + "reading the notes")
      guard let current = pending else { break }
      let page: PageReading
      do {
        let scan = try await withTaskCancellationHandler {
          try await current.value
        } onCancel: {
          current.cancel()
        }
        pending = number < count ? scanPage(number, carriedMeter: Scanner.lastMeter(of: scan.xml)) : nil
        page = try await readPage(
          scan, number: number, header: index == 0, options: options, local: local, localText: localText,
          prefix: prefix, progress: progress)
      } catch {
        pending?.cancel()
        throw error
      }
      pages.append(page.scan)
      chordAnalyses.append(page.chords)
      textAnalyses.append(page.text)
      cropImages += page.cropImages
      textDirections += scoreTextDirections(from: page.text, systemOffsets: textSystemOffsets)
      for voice in Set(page.scan.staffs.map(\.voice)) {
        let systems = page.scan.staffs.filter { $0.voice == voice }.map(\.system).max().map { $0 + 1 } ?? 0
        textSystemOffsets[voice, default: 0] += systems
      }
    }
    try Task.checkCancellation()
    progress("Combining \(pages.count) pages")
    let combined = try PDFScanner.combine(pages: pages, title: title, seconds: pages.reduce(0) { $0 + $1.seconds })
    let metadata = textAnalyses.compactMap(\.metadata).first
    let score = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: metadata?.title, composer: metadata?.composer, arranger: metadata?.arranger,
      tempo: metadata?.headerTempo, partNames: textAnalyses.first?.partNames ?? partNames(metadata?.partName),
      partAbbreviations: textAnalyses.first?.partAbbreviations ?? [],
      staffText: textDirections, into: combined)
    let chordNotes = chordAnalyses.compactMap(\.routeNote)
    let chords = AppleChordAnalysis(
      route: Array(Set(chordAnalyses.map(\.route))).sorted().joined(separator: " + "),
      routeNote: chordNotes.isEmpty ? nil : chordNotes.joined(separator: "\n"),
      crops: chordAnalyses.flatMap(\.crops), seconds: chordAnalyses.reduce(0) { $0 + $1.seconds })
    let textNotes = textAnalyses.compactMap(\.routeNote)
    let text = AppleScoreTextAnalysis(
      route: Array(Set(textAnalyses.map(\.route))).sorted().joined(separator: " + "),
      routeNote: textNotes.isEmpty ? nil : textNotes.joined(separator: "\n"),
      metadata: metadata, initialTimeSignature: nil, staffText: textAnalyses.flatMap(\.staffText),
      seconds: textAnalyses.reduce(0) { $0 + $1.seconds })
    return finished(score: score, metadata: metadata, chords: chords, text: text, crops: cropImages)
  }

  /// Whether Apple's model can read chords and text here: built with the iOS 27 SDK, running on iOS 27, and
  /// Private Cloud Compute available. Without it a reading stops (unless on-device fallback is on), so a caller
  /// can turn chord and text reading off and still read the notes.
  public static var cloudReadingAvailable: Bool { AppleModelRoute.cloudAvailable }

  /// Whether the on-device chord reader's model ships in `models` (it does in this package), so chords can be read
  /// with no network and on any supported device.
  public static func localChordReadingAvailable(models: URL = Scanner.bundledModels) -> Bool {
    LocalChordReader.available(models: models)
  }

  /// One line on what this build can read with Apple's model, for a settings screen.
  public static var modelSupportDescription: String { AppleChordReader.buildSupportDescription }

  // MARK: - Internals

  /// The on-device chord model, loaded once per reading when the options read chords with it.
  private static func localModel(models: URL, options: ScoreReadOptions) throws -> LocalChordReader.Model? {
    guard options.readChordNames, options.chordReader == .onDevice else { return nil }
    return try LocalChordReader.Model(models: models)
  }

  /// The on-device text model (standard PP-OCRv6 small), when the options read text with it.
  private static func localTextModel(models: URL, options: ScoreReadOptions) throws -> LocalChordReader.Model? {
    guard options.readStaffText, options.chordReader == .onDevice, options.textReader == .onDevice else {
      return nil
    }
    return try LocalChordReader.Model(models: models, file: LocalChordReader.textModelFile)
  }

  private static func configure(_ options: ScoreReadOptions) async {
    AppleModelRoute.setFallbackAllowed(options.allowOnDeviceFallback)
    await AppleModelGates.cloud.setLimit(options.cloudRequests)
  }

  /// One page read: its score with the chords written in, and what Apple's model read from it.
  private struct PageReading: Sendable {
    let scan: ScanResult
    let chords: AppleChordAnalysis
    let text: AppleScoreTextAnalysis
    let cropImages: [ChordCropImage]
  }

  /// The chord names and the text of one read page. `header`: also read the title and composer at the top.
  ///
  /// The title, composer and tempo at the top are read alongside the chord names. Staff text (rehearsal letters,
  /// D.S. and Fine, section names) is read only on a page that prints chord names, a lead sheet: on pages without
  /// them the model has invented rehearsal letters and instrument names, and their headers are still read. With
  /// chord reading off there is no chord check, so staff text follows its own switch.
  private static func readPage(
    _ scan: ScanResult, number: Int, header: Bool, options: ScoreReadOptions, local: LocalChordReader.Model?,
    localText: LocalChordReader.Model?, prefix: String, progress: @escaping @Sendable (String) -> Void
  ) async throws -> PageReading {
    if options.chordReader == .onDevice {
      return try await readPageOnDevice(
        scan, number: number, header: header, options: options, local: local, localText: localText, prefix: prefix,
        progress: progress)
    }
    let crops = options.readChordNames ? try ChordImageCrops.from(scan) : []
    // the reader states the meters it reads, so the opening time signature is not asked for
    let textCrops = try ScoreTextImageCrops.from(scan, includeHeader: header).filter { $0.kind != .initialMeter }
    let headerCrops = textCrops.filter { $0.kind == .header }
    let systemCrops = textCrops.filter { $0.kind == .system }
    let report: @Sendable (String) -> Void = { progress(prefix + $0) }
    let cloud = options.preferPrivateCloud
    async let chordReading = AppleChordReader.analyze(
      crops: crops, preferPrivateCloud: cloud, page: number, checking: scan, progress: report)
    async let headerReading: AppleScoreTextAnalysis? = headerCrops.isEmpty
      ? nil
      : AppleScoreTextReader.analyze(
        crops: headerCrops, preferPrivateCloud: cloud, page: number, readStaffText: false, progress: report)
    let chords = try await chordReading
    let headerText = try await headerReading
    let printsChords = options.readChordNames ? !chords.crops.isEmpty : true
    let staffText: AppleScoreTextAnalysis? = options.readStaffText && printsChords && !systemCrops.isEmpty
      ? try await AppleScoreTextReader.analyze(
        crops: systemCrops, preferPrivateCloud: cloud, page: number, readStaffText: true, progress: report)
      : nil
    let parts = [headerText, staffText].compactMap { $0 }
    var notes = parts.compactMap(\.routeNote)
    if options.readStaffText && !printsChords && !systemCrops.isEmpty {
      notes.append("Staff text was not read: the page shows no chord symbols.")
    }
    let text = AppleScoreTextAnalysis(
      route: parts.isEmpty ? "not read" : Array(Set(parts.map(\.route))).sorted().joined(separator: " + "),
      routeNote: notes.isEmpty ? nil : notes.joined(separator: "\n"),
      metadata: headerText?.metadata, initialTimeSignature: nil,
      staffText: parts.flatMap(\.staffText), seconds: parts.reduce(0) { $0 + $1.seconds })
    let rejoined = AppleChordReader.rejoinedChords(chords)
    let recognitions = chords.crops.compactMap { result -> ChordCropRecognition? in
      guard crops.indices.contains(result.cropIndex) else { return nil }
      return ChordCropRecognition(crop: crops[result.cropIndex], chords: rejoined[result.cropIndex] ?? [])
    }
    let placed = try ChordImageCrops.inserting(
      recognitions, into: scan, additionalSeconds: chords.seconds + text.seconds, keepPage: false)
    // a page the chord check passed over had no crops read, so none are kept
    let images = chords.crops.isEmpty
      ? []
      : crops.enumerated().compactMap { item -> ChordCropImage? in
        AppleChordReader.exported(item.element, index: item.offset, page: number)
          .map { ChordCropImage(name: $0.name, png: $0.png) }
      }
    return PageReading(scan: placed, chords: chords, text: text, cropImages: images)
  }

  /// One page with the chords read on this device. Title, composer and staff text are read by Apple's model only
  /// when `readStaffText` is on; otherwise nothing leaves the device.
  private static func readPageOnDevice(
    _ scan: ScanResult, number: Int, header: Bool, options: ScoreReadOptions, local: LocalChordReader.Model?,
    localText: LocalChordReader.Model?, prefix: String, progress: @escaping @Sendable (String) -> Void
  ) async throws -> PageReading {
    let report: @Sendable (String) -> Void = { progress(prefix + $0) }
    var placed = scan
    var chords = AppleChordAnalysis(route: "not read", routeNote: nil, crops: [], seconds: 0)
    var pageChords: LocalChordReader.PageChords?
    if let local {
      let result = try LocalChordReader.readPage(scan, model: local, page: number, progress: report)
      (placed, chords, pageChords) = (result.scan, result.analysis, result)
    }
    var text = AppleScoreTextAnalysis(
      route: "not read", routeNote: nil, metadata: nil, initialTimeSignature: nil, staffText: [], seconds: 0)
    if options.readStaffText, let localText {
      text = try LocalTextReader.read(
        scan, chords: pageChords, model: localText, page: number, header: header, progress: report)
    } else if options.readStaffText {
      let textCrops = try ScoreTextImageCrops.from(scan, includeHeader: header).filter { $0.kind != .initialMeter }
      let headerCrops = textCrops.filter { $0.kind == .header }
      let systemCrops = textCrops.filter { $0.kind == .system }
      let cloud = options.preferPrivateCloud
      let headerText: AppleScoreTextAnalysis? = headerCrops.isEmpty
        ? nil
        : try await AppleScoreTextReader.analyze(
          crops: headerCrops, preferPrivateCloud: cloud, page: number, readStaffText: false, progress: report)
      let printsChords = options.readChordNames ? chords.chords.contains { $0.acceptedChord != nil } : true
      let staffText: AppleScoreTextAnalysis? = printsChords && !systemCrops.isEmpty
        ? try await AppleScoreTextReader.analyze(
          crops: systemCrops, preferPrivateCloud: cloud, page: number, readStaffText: true, progress: report)
        : nil
      let parts = [headerText, staffText].compactMap { $0 }
      var notes = parts.compactMap(\.routeNote)
      if !printsChords && !systemCrops.isEmpty {
        notes.append("Staff text was not read: the page shows no chord symbols.")
      }
      text = AppleScoreTextAnalysis(
        route: parts.isEmpty ? "not read" : Array(Set(parts.map(\.route))).sorted().joined(separator: " + "),
        routeNote: notes.isEmpty ? nil : notes.joined(separator: "\n"),
        metadata: headerText?.metadata, initialTimeSignature: nil,
        staffText: parts.flatMap(\.staffText), seconds: parts.reduce(0) { $0 + $1.seconds })
    }
    if local == nil {
      // no chords read: the page as scanned, without its pixels
      placed = ScanResult(
        xml: scan.xml, rawXML: scan.rawXML, staffs: scan.staffs, page: Data(), pageWidth: scan.pageWidth,
        pageHeight: scan.pageHeight, seconds: scan.seconds, repairedMeasures: 0)
    }
    placed = ScanResult(
      xml: placed.xml, rawXML: placed.rawXML, staffs: placed.staffs, page: Data(), pageWidth: placed.pageWidth,
      pageHeight: placed.pageHeight, seconds: placed.seconds + text.seconds, repairedMeasures: 0)
    if let lyrics = text.lyrics, !lyrics.isEmpty {
      // the syllables go onto the notes the scanner tagged
      let xml = try ScoreLyricsMusicXML.inserting(lyrics, into: placed.xml)
      placed = ScanResult(
        xml: xml, rawXML: xml, staffs: placed.staffs, page: placed.page, pageWidth: placed.pageWidth,
        pageHeight: placed.pageHeight, seconds: placed.seconds, repairedMeasures: placed.repairedMeasures,
        chordWords: placed.chordWords, chordWordStaffs: placed.chordWordStaffs, lyricWords: placed.lyricWords)
    }
    return PageReading(scan: placed, chords: chords, text: text, cropImages: [])
  }

  private static func finished(
    score: DocumentScanResult, metadata: AppleScoreMetadata?, chords: AppleChordAnalysis,
    text: AppleScoreTextAnalysis, crops: [ChordCropImage]
  ) -> ScoreReading {
    var chords = chords
    chords.counts?.placedInScore = chordCount(in: score.xml)
    return ScoreReading(score: score, metadata: metadata, chords: chords, text: text, chordCrops: crops)
  }

  private static func scoreTextDirections(
    from analysis: AppleScoreTextAnalysis, systemOffsets: [Int: Int] = [:]
  ) -> [ScoreTextDirection] {
    analysis.staffText.map {
      ScoreTextDirection(
        voice: $0.voice, system: $0.system + systemOffsets[$0.voice, default: 0],
        bar: $0.bar, barCount: $0.barCount, text: $0.text, category: $0.category)
    }
  }

  /// The instrument names the header reading found ("Voice, Piano"), one per part in order.
  static func partNames(_ text: String?) -> [String] {
    guard let text else { return [] }
    return text.replacingOccurrences(of: " & ", with: ",").replacingOccurrences(of: " and ", with: ",")
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  static func chordCount(in xml: Data) -> Int {
    guard let text = String(data: xml, encoding: .utf8) else { return 0 }
    return text.components(separatedBy: "<harmony").count - 1
  }
}

/// Whether a reading that prefers Private Cloud Compute may finish on the on-device model when PCC is unavailable
/// or a request fails. The on-device model is markedly less accurate on scanned scores and has recited its own
/// prompt as staff text, so by default a reading stops rather than quietly degrade. Set per reading from
/// `ScoreReadOptions.allowOnDeviceFallback`.
enum AppleModelRoute {
  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
  }
  private static let fallback = Flag()

  static var fallbackAllowed: Bool { fallback.get() }
  static func setFallbackAllowed(_ allowed: Bool) { fallback.set(allowed) }

  static var cloudAvailable: Bool {
    #if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
      guard #available(iOS 27.0, *) else { return false }
      return AppleModelAvailability.privateCloudAvailable
    #else
      return false
    #endif
  }
}

public enum AppleModelRouteError: LocalizedError {
  case cloudUnavailable(String)
  case cloudFailed(String)

  public var errorDescription: String? {
    switch self {
    case .cloudUnavailable(let reason):
      "Private Cloud Compute is unavailable (\(reason)), and on-device reading is turned off."
    case .cloudFailed(let reason):
      "A Private Cloud Compute request failed (\(reason)), and on-device reading is turned off."
    }
  }
}
