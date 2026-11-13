import CoreGraphics
import Foundation

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  import FoundationModels
#endif

public struct AppleChordReading: Codable, Identifiable, Sendable {
  public let id: UUID
  public let visibleText: String
  public let proposedChord: String
  public let acceptedChord: String?
  public let recoveredFromIgnoredText: Bool
  /// How the reading was judged; absent in reports written before verdicts.
  public let verdict: ChordText.Verdict?

  public init(
    visibleText: String, proposedChord: String, acceptedChord: String?,
    recoveredFromIgnoredText: Bool = false, verdict: ChordText.Verdict? = nil
  ) {
    id = UUID()
    self.visibleText = visibleText
    self.proposedChord = proposedChord
    self.acceptedChord = acceptedChord
    self.recoveredFromIgnoredText = recoveredFromIgnoredText
    self.verdict = verdict ?? (acceptedChord == nil ? .blocked : .accepted)
  }
}

public struct AppleChordCropAnalysis: Codable, Identifiable, Sendable {
  public let id: UUID
  public let cropIndex: Int
  public let page: Int
  public let staff: Int
  public let system: Int?
  public let bar: Int
  public let chords: [AppleChordReading]
  public let ignoredShortText: [String]

  public init(
    cropIndex: Int, page: Int, crop: ChordImageCrop, chords: [AppleChordReading],
    ignoredShortText: [String]
  ) {
    id = UUID()
    self.cropIndex = cropIndex
    self.page = page
    staff = crop.staff
    system = crop.system
    bar = crop.bar
    self.chords = chords
    self.ignoredShortText = ignoredShortText
  }
}

/// Where a scan's chord readings went: how many the check accepted as known
/// chords, accepted as unusual ones, or blocked, and how many reached the score.
public struct AppleChordCounts: Codable, Sendable {
  public let accepted: Int
  public let unusual: Int
  public let blocked: Int
  public var placedInScore: Int?
}

public struct AppleChordAnalysis: Codable, Sendable {
  public let route: String
  public let routeNote: String?
  public let crops: [AppleChordCropAnalysis]
  public let seconds: Double
  /// Absent in reports written before the counts.
  public var counts: AppleChordCounts?

  public init(route: String, routeNote: String?, crops: [AppleChordCropAnalysis], seconds: Double) {
    self.route = route
    self.routeNote = routeNote
    self.crops = crops
    self.seconds = seconds
    let readings = crops.flatMap(\.chords)
    func count(_ verdict: ChordText.Verdict) -> Int {
      readings.filter { $0.verdict == verdict }.count
    }
    counts = AppleChordCounts(
      accepted: count(.accepted), unusual: count(.unusual), blocked: count(.blocked))
  }

  public var chords: [AppleChordReading] { crops.flatMap(\.chords) }
  public var ignoredShortText: [String] { crops.flatMap(\.ignoredShortText) }
}

enum AppleChordReaderError: LocalizedError {
  case requiresXcode27
  case requiresIOS27
  case invalidCrop

  var errorDescription: String? {
    switch self {
    case .requiresXcode27:
      return "Build with Xcode 27 or later to use Apple Foundation Models for chords."
    case .requiresIOS27:
      return "Apple's visual Foundation Models API requires iOS 27 or later."
    case .invalidCrop:
      return "The scanner produced an invalid chord image crop."
    }
  }
}

enum AppleChordReader {
  /// The measure crop as sent to the reader, named by its bar, so the same
  /// image can be given to another model for comparison.
  static func exported(_ crop: ChordImageCrop, index: Int, page: Int) -> (name: String, png: Data)? {
    guard
      let image = try? CropImage.enlarged(
        pixels: crop.pixels, width: crop.width, height: crop.height),
      let data = CropImage.png(image)
    else { return nil }
    let bar = String(format: "%03d", index)
    return ("p\(page)-crop\(bar)-system\((crop.system ?? 0) + 1)-bar\(crop.bar + 1).png", data)
  }

  /// Accepted chords per crop index, with names that a bar line cut in two
  /// joined back together.
  ///
  /// A lead sheet places a chord over the bar's first note but starts its text
  /// a little left of the bar line, so the measure crop can split it: the root
  /// ("C", "B", or a partial "Dr") lands at the end of the previous bar and the
  /// quality ("min7", "♭maj7") opens the next. Each piece is read faithfully,
  /// so the root was accepted as a major chord in the wrong bar and the quality
  /// was rejected. Rejoined, the chord belongs to the bar holding its quality,
  /// which is the bar whose note it sits over.
  static func rejoinedChords(_ analysis: AppleChordAnalysis) -> [Int: [String]] {
    let crops = analysis.crops.sorted { $0.cropIndex < $1.cropIndex }
    var chords = Dictionary(
      uniqueKeysWithValues: crops.map { ($0.cropIndex, $0.chords.compactMap(\.acceptedChord)) })
    let root = try! NSRegularExpression(pattern: #"^([A-G](?:b|#|♭|♯)?)[a-z]?$"#)
    func bareRoot(_ text: String) -> String? {
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      guard let match = root.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
        let range = Range(match.range(at: 1), in: trimmed)
      else { return nil }
      return String(trimmed[range])
    }
    for (previous, current) in zip(crops, crops.dropFirst())
    where previous.page == current.page && previous.staff == current.staff
      && current.bar == previous.bar + 1
    {
      // The fragment opens the bar and has no root of its own.
      guard let first = current.chords.first, first.acceptedChord == nil,
        let initial = first.visibleText.trimmingCharacters(in: .whitespaces).first,
        !("A"..."G").contains(initial)
      else { continue }
      // The root closes the previous bar: its last reading, or a short text
      // the reader set aside when the bar had no chord of its own.
      let tail = previous.chords.last?.visibleText ?? previous.ignoredShortText.last
      guard let tail, let letters = bareRoot(tail),
        let joined = ChordText.acceptedSymbols(
          visibleText: letters + first.visibleText, proposedChord: letters + first.visibleText),
        joined.count == 1
      else { continue }
      if previous.chords.last?.visibleText == tail, !(chords[previous.cropIndex] ?? []).isEmpty,
        let last = chords[previous.cropIndex]?.last, bareRoot(last) != nil
      {
        chords[previous.cropIndex]?.removeLast()
      }
      chords[current.cropIndex] = joined + (chords[current.cropIndex] ?? [])
    }
    return chords
  }

  static var buildSupportDescription: String {
    #if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
      "Reads the chord strip above each staff, bar by bar, with rehearsal boxes cleaned out."
    #else
      "Install and build with Xcode 27 to enable Apple Foundation Models."
    #endif
  }

  /// Reads the chord symbols in `crops`. With `checking`, the model is first
  /// asked whether that page shows any chord symbols at all, and a page without
  /// them is not read measure by measure: art songs and classical parts would
  /// otherwise spend one request per four bars finding nothing.
  static func analyze(
    crops: [ChordImageCrop], preferPrivateCloud: Bool, page: Int = 1,
    checking scan: ScanResult? = nil,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> AppleChordAnalysis {
    #if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
      guard #available(iOS 27.0, *) else { throw AppleChordReaderError.requiresIOS27 }
      return try await analyze27(
        crops: crops, preferPrivateCloud: preferPrivateCloud, page: page, checking: scan,
        progress: progress)
    #else
      throw AppleChordReaderError.requiresXcode27
    #endif
  }

  /// Loads the model while the notation scan runs, so the first batch does not
  /// also pay for the load. The on-device model is only loaded when the scan
  /// may use it. Best effort only: a failure here costs nothing.
  static func prewarm(preferPrivateCloud: Bool) {
    #if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
      guard #available(iOS 27.0, *) else { return }
      if preferPrivateCloud {
        let cloud = PrivateCloudComputeLanguageModel()
        if cloud.isAvailable { LanguageModelSession(model: cloud).prewarm() }
        guard AppleModelRoute.fallbackAllowed else { return }
      }
      LanguageModelSession().prewarm()
    #endif
  }

  fileprivate static func image(from crop: ChordImageCrop) throws -> CGImage {
    guard crop.width > 0, crop.height > 0,
      crop.pixels.count == crop.width * crop.height,
      let provider = CGDataProvider(data: crop.pixels as CFData),
      let image = CGImage(
        width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else { throw AppleChordReaderError.invalidCrop }
    return image
  }

  /// The longest side of the page sent to the chord check. A rendered page is
  /// larger than the model needs to spot chord text, and smaller uploads are
  /// quicker.
  static let pageCheckLongSide = 2048.0

  fileprivate static func pageImage(from scan: ScanResult) throws -> CGImage {
    let width = scan.pageWidth, height = scan.pageHeight
    guard width > 0, height > 0, scan.page.count == width * height,
      let provider = CGDataProvider(data: scan.page as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else { throw AppleChordReaderError.invalidCrop }
    let scale = pageCheckLongSide / Double(max(width, height))
    guard scale < 1 else { return image }
    let w = Int(Double(width) * scale), h = Int(Double(height) * scale)
    guard
      let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage() ?? image
  }
}

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedChordReading {
    @Guide(description: "Exact chord text visible in the crop, preserving accidentals and suffixes.")
    var visibleText: String

    @Guide(description: "The same single chord normalized with ASCII b and # accidentals. Never simplify or infer harmony.")
    var normalizedChord: String
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedChordCrop {
    @Guide(description: "The integer from the crop-N image label.")
    var cropNumber: Int

    @Guide(description: "All visibly printed chord symbols in this crop, left to right. Empty when there are none.")
    var chords: [GeneratedChordReading]

    @Guide(description: "Only short chord-like text excluded as navigation, rehearsal, or staff text.")
    var ignoredShortText: [String]
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedChordPresence {
    @Guide(description: "Up to three chord symbols copied exactly as printed on the page. Empty when there are none.")
    var examples: [String]

    @Guide(description: "True when the page prints chord symbols above or below a staff; also true when unsure.")
    var hasChordSymbols: Bool
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedChordBatch {
    @Guide(description: "Exactly one result for each labeled crop image, in crop-number order.")
    var crops: [GeneratedChordCrop]
  }

  @available(iOS 27.0, *)
  private extension AppleChordReader {
    static func analyze27(
      crops: [ChordImageCrop], preferPrivateCloud: Bool, page: Int, checking scan: ScanResult?,
      progress: @escaping @Sendable (String) -> Void
    ) async throws -> AppleChordAnalysis {
      let start = Date()
      if crops.isEmpty {
        return AppleChordAnalysis(
          route: "Apple Foundation Models", routeNote: "No measure crops were found.",
          crops: [], seconds: 0)
      }
      let requester = try AppleModelRequester(
        preferPrivateCloud: preferPrivateCloud,
        unavailable: "Private Cloud Compute unavailable; reading chord crops on device",
        progress: progress)
      if let scan {
        progress("Checking the page for chord symbols")
        let pageImage = try pageImage(from: scan)
        let check = try await requester.respond("Chord check") { session in
          try await presence(from: session, page: pageImage)
        }
        if !check.value.hasChordSymbols {
          let route = requester.route([("Chord check", check.fallbackReason)])
          return AppleChordAnalysis(
            route: route.route,
            routeNote: [route.note, "The page shows no chord symbols; its \(crops.count) measures were not read."]
              .compactMap { $0 }.joined(separator: "\n"),
            crops: [], seconds: Date().timeIntervalSince(start))
        }
      }
      let images = try crops.map(image(from:))
      // Every batch is its own session and its own answer, so the batches are
      // sent together and only the order of arrival changes.
      let batches = appleModelBatches(Array(crops.indices))
      var done = 0
      progress("Reading chord measures: 0 of \(crops.count) done")
      let answers = try await Concurrently.map(batches) { indices in
        try await requester.respond(appleModelBatchName("Chord measures", indices)) { session in
          readings(
            indices, crops: crops, page: page,
            generated: try await response(from: session, images: indices.map { ($0, images[$0]) }))
        }
      } finished: { indices, _ in
        done += indices.count
        progress("Reading chord measures: \(done) of \(crops.count) done")
      }
      let route = requester.route(
        zip(batches, answers).map { (appleModelBatchName("Chord measures", $0), $1.fallbackReason) })
      return AppleChordAnalysis(
        route: route.route, routeNote: route.note, crops: answers.flatMap(\.value),
        seconds: Date().timeIntervalSince(start))
    }

    static func readings(
      _ indices: [Int], crops: [ChordImageCrop], page: Int, generated: GeneratedChordBatch
    ) -> [AppleChordCropAnalysis] {
      let byNumber = Dictionary(
        generated.crops.map { ($0.cropNumber, $0) },
        uniquingKeysWith: { first, _ in first })
      return indices.map { index in
        let item = byNumber[index]
        // The cloud model is trusted on what each chord is; the check only
        // keeps out readings that are not chords at all.
        var readings = (item?.chords ?? []).flatMap { chord -> [AppleChordReading] in
          let judged = ChordText.modelSymbols(
            visibleText: chord.visibleText, proposedChord: chord.normalizedChord)
          guard !judged.chords.isEmpty else {
            return [
              AppleChordReading(
                visibleText: chord.visibleText, proposedChord: chord.normalizedChord,
                acceptedChord: nil, verdict: .blocked)
            ]
          }
          return judged.chords.map {
            AppleChordReading(
              visibleText: chord.visibleText, proposedChord: chord.normalizedChord,
              acceptedChord: $0, verdict: judged.verdict)
          }
        }
        var stillIgnored: [String] = []
        for text in item?.ignoredShortText ?? [] {
          guard let recovered = ChordText.recoverableIgnoredSymbols(text) else {
            stillIgnored.append(text)
            continue
          }
          for chord in recovered where !readings.contains(where: { $0.acceptedChord == chord }) {
            readings.append(
              AppleChordReading(
                visibleText: text, proposedChord: chord, acceptedChord: chord,
                recoveredFromIgnoredText: true))
          }
        }
        return AppleChordCropAnalysis(
          cropIndex: index, page: page, crop: crops[index], chords: readings,
          ignoredShortText: stillIgnored)
      }
    }

    static func response(
      from session: LanguageModelSession, images: [(Int, CGImage)]
    ) async throws -> GeneratedChordBatch {
      let prompt = """
        Each attached image is the chord-text band above exactly one detected measure. Transcribe
        only chord symbols visibly printed in each crop. Do not infer harmony from the music, key,
        or neighboring crops. Preserve root, accidental, quality, extension, alterations, and slash
        bass. A bare A through G is a chord only when typography and placement make it a harmony.
        Ignore rehearsal letters, measure numbers, lyrics, dynamics, tempo words, Fine, D.C., D.S.,
        Segno, Coda, To Coda, and other staff directions. Rehearsal boxes have already been erased.
        Keep repeated symbols and return them left to right. Return one result per image using the
        integer in its crop-N label; return an empty chords array for a blank crop.
        """
      let response = try await session.respond(
        generating: GeneratedChordBatch.self,
        options: GenerationOptions(samplingMode: .greedy)
      ) {
        prompt
        for (number, image) in images { Attachment(image).label("crop-\(number)") }
      }
      return response.content
    }

    static func presence(
      from session: LanguageModelSession, page: CGImage
    ) async throws -> GeneratedChordPresence {
      let prompt = """
        The attached image is one page of printed music. Decide whether it prints chord symbols:
        harmony names such as C, Am7, F#m7b5, Bbmaj7, G7(b9), D/F# or N.C., written as text
        above or below a staff, as in a lead sheet, fake book, or guitar part. Lyrics, dynamics,
        tempo words, rehearsal letters, measure numbers, fingerings, figured bass, Roman numerals,
        titles and credits are not chord symbols. Copy up to three chord symbols you can see, then
        answer. Missing real chord symbols is worse than a false alarm, so answer true when unsure.
        """
      let response = try await session.respond(
        generating: GeneratedChordPresence.self,
        options: GenerationOptions(samplingMode: .greedy)
      ) {
        prompt
        Attachment(page).label("page")
      }
      return response.content
    }
  }
#endif
