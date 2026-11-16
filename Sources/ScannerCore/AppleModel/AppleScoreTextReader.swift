import CoreGraphics
import Foundation

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  import FoundationModels
#endif

public struct AppleScoreMetadata: Codable, Sendable {
  public let title: String
  public let subtitle: String
  public let composer: String
  public let arranger: String
  public let partName: String
  public let tempoText: String
  public let beatUnit: String
  public let bpm: Int
  public let copyright: String

  public var isEmpty: Bool {
    [title, subtitle, composer, arranger, partName, tempoText, copyright]
      .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && bpm <= 0
  }

  public var headerTempo: ScoreHeaderTempo {
    ScoreHeaderTempo(text: tempoText, beatUnit: beatUnit, bpm: bpm)
  }
}

public struct AppleStaffTextReading: Codable, Identifiable, Sendable {
  public let id: UUID
  public let page: Int
  public let staff: Int
  public let voice: Int
  public let system: Int
  public let bar: Int
  public let barCount: Int
  public let text: String
  public let category: String
}

public struct AppleScoreTextAnalysis: Codable, Sendable {
  public let route: String
  public let routeNote: String?
  public let metadata: AppleScoreMetadata?
  public let initialTimeSignature: ScoreTimeSignature?
  public let staffText: [AppleStaffTextReading]
  public let seconds: Double
  /// The instrument names printed left of each part's staves on the first system, one per part in score order
  /// ("" where none was read); nil when the reader does not look for them. Read on this device only.
  public var partNames: [String]? = nil
  /// The short names printed beside the second system ("Vln. I"), the same way.
  public var partAbbreviations: [String]? = nil
}

enum AppleScoreTextReader {
  static func analyze(
    crops: [ScoreTextImageCrop], preferPrivateCloud: Bool, page: Int,
    readStaffText: Bool = true,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> AppleScoreTextAnalysis {
    #if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
      guard #available(iOS 27.0, *) else { throw AppleChordReaderError.requiresIOS27 }
      return try await analyze27(
        crops: crops, preferPrivateCloud: preferPrivateCloud, page: page,
        readStaffText: readStaffText, progress: progress)
    #else
      throw AppleChordReaderError.requiresXcode27
    #endif
  }

  static func image(from crop: ScoreTextImageCrop) throws -> CGImage {
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
}

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedScoreMetadata {
    @Guide(description: "Main printed score title only; empty if absent.")
    var title: String
    @Guide(description: "Printed subtitle only; empty if absent.")
    var subtitle: String
    @Guide(description: "Composer or songwriter names only; empty if absent.")
    var composer: String
    @Guide(description: "Arranger name only, without words such as Arr. or arranged by; empty if absent.")
    var arranger: String
    @Guide(description: "Part or instrument name printed in the header; empty if absent.")
    var partName: String
    @Guide(description: "Exact tempo or style marking at the start, such as Swing, Ballad, Moderato, or a note = number metronome mark. Never section labels or cues such as Intro or Piano Intro; empty if absent.")
    var tempoText: String
    @Guide(description: "Note value printed left of = in the metronome mark: whole, half, quarter, eighth, or sixteenth, prefixed with dotted- when that note has a dot; empty if absent.")
    var beatUnit: String
    @Guide(description: "Printed metronome number, or zero when none is visible.")
    var bpm: Int
    @Guide(description: "Printed copyright line only; empty if absent.")
    var copyright: String
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedInitialMeter {
    @Guide(description: "True only if a time signature is visibly printed immediately after the opening clef and key signature on the staff.")
    var hasPrintedSignature: Bool
    @Guide(description: "Upper number of the opening time signature; zero if none is visibly printed. Common time is 4; cut time is 2.")
    var beats: Int
    @Guide(description: "Lower number of the opening time signature; zero if none is visibly printed. Common time is 4; cut time is 2.")
    var beatType: Int
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedStaffText {
    @Guide(description: "Exact visibly printed text. Never infer or correct wording.")
    var visibleText: String
    @Guide(description: "One of rehearsal, navigation, tempo, instruction, instrument-cue, section, or other.")
    var category: String
    @Guide(description: "Zero-based bar containing the left edge of the text.")
    var barIndex: Int
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedSystemText {
    @Guide(description: "Integer from the system-N image label.")
    var cropNumber: Int
    @Guide(description: "Visible non-chord staff text. Empty when none is present.")
    var items: [GeneratedStaffText]
  }

  @available(iOS 27.0, *)
  @Generable
  private struct GeneratedSystemTextBatch {
    @Guide(description: "Exactly one result for each labeled system image.")
    var systems: [GeneratedSystemText]
  }

  @available(iOS 27.0, *)
  private extension AppleScoreTextReader {
    /// The score text readings, sent as separate requests.
    enum TextRequest: Sendable {
      case header(Int)
      case meter(Int)
      case systems(position: Int, indices: [Int])
    }

    enum TextReading: Sendable {
      case header(AppleScoreMetadata?)
      case meter(ScoreTimeSignature?)
      case systems([AppleStaffTextReading])
    }

    static func analyze27(
      crops: [ScoreTextImageCrop], preferPrivateCloud: Bool, page: Int,
      readStaffText: Bool,
      progress: @escaping @Sendable (String) -> Void
    ) async throws -> AppleScoreTextAnalysis {
      let start = Date()
      let images = try crops.map(image(from:))
      let requester = try AppleModelRequester(
        preferPrivateCloud: preferPrivateCloud,
        unavailable: "PCC unavailable; reading score text on device", progress: progress)

      var requests: [TextRequest] = []
      if let index = crops.firstIndex(where: { $0.kind == .header }) {
        requests.append(.header(index))
      }
      if let index = crops.firstIndex(where: { $0.kind == .initialMeter }) {
        requests.append(.meter(index))
      }
      // The title, composer, tempo, and opening meter above are not staff text,
      // so they are still read when staff text is switched off.
      let systems = readStaffText ? crops.indices.filter { crops[$0].kind == .system } : []
      for (position, batch) in zip(
        stride(from: 0, to: systems.count, by: 4), appleModelBatches(systems))
      {
        requests.append(.systems(position: position, indices: batch))
      }

      // None of these readings depends on another, so they are sent together.
      var done = 0
      let answers = try await Concurrently.map(requests) { request -> (String, ModelAnswer<TextReading>)? in
        switch request {
        case .header(let index):
          progress("Reading title and score metadata")
          let answer = try await requester.respond("Score header") { session in
            TextReading.header(
              scoreMetadata(try await headerResponse(from: session, image: images[index])))
          }
          return ("Score header", answer)
        case .meter(let index):
          progress("Reading the opening time signature")
          // An unreadable meter keeps HOMR's, rather than stopping the scan or
          // asking the on-device model instead.
          do {
            let answer = try await requester.respond("Opening time signature", fallback: false) {
              session in
              let generated = try await meterResponse(from: session, image: images[index])
              let value = ScoreTimeSignature(beats: generated.beats, beatType: generated.beatType)
              return TextReading.meter(
                generated.hasPrintedSignature && value.isSupported ? value : nil)
            }
            return ("Opening time signature", answer)
          } catch {
            if error is CancellationError { throw error }
            progress("Opening meter unreadable; keeping HOMR's time signature")
            return nil
          }
        case .systems(let position, let batch):
          let name = appleModelBatchName("Staff text systems", Array(position..<position + batch.count))
          // A strip of whole systems is the slowest reading of a page, about
          // 13 s on PCC against 2–4 s for a chord batch, so it goes first.
          let answer = try await requester.respond(name, slow: true) { session in
            TextReading.systems(
              staffText(
                batch, crops: crops, page: page,
                generated: try await systemResponse(
                  from: session, crops: batch.map { ($0, crops[$0], images[$0]) })))
          }
          return (name, answer)
        }
      } finished: { request, _ in
        guard case .systems(_, let batch) = request else { return }
        done += batch.count
        progress("Reading staff text: \(done) of \(systems.count) done")
      }

      var metadata: AppleScoreMetadata?
      var initialTimeSignature: ScoreTimeSignature?
      var readings: [AppleStaffTextReading] = []
      for case let (_, answer)? in answers {
        switch answer.value {
        case .header(let value): metadata = value
        case .meter(let value): initialTimeSignature = value
        case .systems(let value): readings += value
        }
      }
      let route = requester.route(answers.compactMap { $0.map { ($0.0, $0.1.fallbackReason) } })
      return AppleScoreTextAnalysis(
        route: route.route, routeNote: route.note,
        metadata: metadata, initialTimeSignature: initialTimeSignature, staffText: readings,
        seconds: Date().timeIntervalSince(start))
    }

    static func scoreMetadata(_ generated: GeneratedScoreMetadata) -> AppleScoreMetadata? {
      let value = AppleScoreMetadata(
        title: clean(generated.title), subtitle: clean(generated.subtitle),
        composer: clean(generated.composer), arranger: clean(generated.arranger),
        partName: clean(generated.partName), tempoText: clean(generated.tempoText),
        beatUnit: clean(generated.beatUnit), bpm: max(0, generated.bpm),
        copyright: clean(generated.copyright))
      return value.isEmpty ? nil : value
    }

    static func staffText(
      _ batch: [Int], crops: [ScoreTextImageCrop], page: Int, generated: GeneratedSystemTextBatch
    ) -> [AppleStaffTextReading] {
      let byNumber = Dictionary(
        generated.systems.map { ($0.cropNumber, $0) },
        uniquingKeysWith: { first, _ in first })
      var readings: [AppleStaffTextReading] = []
      for index in batch {
        let crop = crops[index]
        guard let staff = crop.staff, let system = crop.system else { continue }
        let items = byNumber[index]?.items ?? []
        // A strip that recites the instructions was not read from the page,
        // so none of its items can be trusted, including any D.C. or Fine
        // listed alongside the recited categories.
        guard !isPromptEcho(items.map { clean($0.visibleText) }) else { continue }
        for item in items {
          let text = clean(item.visibleText)
          let kind = category(item.category)
          // A boxed rehearsal letter is intentionally chord-shaped. Preserve
          // it only when the structured classification explicitly says it is
          // a rehearsal mark; reject chord-shaped text in every other role.
          guard !text.isEmpty, !isNumberOnly(text),
            kind == "rehearsal" || !looksLikeChord(text)
          else { continue }
          readings.append(
            AppleStaffTextReading(
              id: UUID(), page: page, staff: staff, voice: crop.voice ?? 0, system: system,
              bar: min(max(0, item.barIndex), max(0, crop.barCount - 1)),
              barCount: crop.barCount,
              text: text, category: kind))
        }
      }
      return readings
    }

    static func meterResponse(
      from session: LanguageModelSession, image: CGImage
    ) async throws -> GeneratedInitialMeter {
      let response = try await session.respond(
        generating: GeneratedInitialMeter.self,
        options: GenerationOptions(samplingMode: .greedy)
      ) {
        """
        Inspect only the opening time signature printed on these staff lines, immediately after
        the clef and key signature. Read its upper and lower numbers. A common-time C means
        4/4; a cut-time C with a vertical stroke means 2/2. Do not infer meter from notes,
        rests, beaming, bar lengths, chord labels, rehearsal marks, tempo numbers, or measure
        numbers. If no opening signature is clearly visible, set hasPrintedSignature false
        and both numbers to zero. Unsupported additive or unusual signatures should also
        return false and zero. This crop is from the first music system only.
        """
        Attachment(image).label("opening-staff-and-time-signature")
      }
      return response.content
    }

    static func headerResponse(
      from session: LanguageModelSession, image: CGImage
    ) async throws -> GeneratedScoreMetadata {
      let response = try await session.respond(
        generating: GeneratedScoreMetadata.self,
        options: GenerationOptions(samplingMode: .greedy)
      ) {
        """
        Read only visibly printed header metadata from the top of this sheet-music page. It may
        include the first staff. Never infer missing names or values. Separate the title,
        subtitle, composer, arranger, part name, copyright, and tempo. A musical note followed
        by = and a number is a metronome mark; its beat unit is that note, including any dot.
        Tempo is only a tempo or style marking; section labels and cues such as Intro or Piano
        Intro are not tempo. Ignore page numbers, chord symbols, lyrics, rehearsal marks, and
        notation.
        """
        Attachment(image).label("score-header")
      }
      return response.content
    }

    static func systemResponse(
      from session: LanguageModelSession,
      crops: [(Int, ScoreTextImageCrop, CGImage)]
    ) async throws -> GeneratedSystemTextBatch {
      let geometry = crops.map { index, crop, _ in
        let boundaries = crop.barBoundaryFractions.map { String(format: "%.3f", $0) }
          .joined(separator: ",")
        return "system-\(index): \(crop.barCount) bars; boundaries \(boundaries)"
      }.joined(separator: "\n")
      let response = try await session.respond(
        generating: GeneratedSystemTextBatch.self,
        options: GenerationOptions(samplingMode: .greedy)
      ) {
        """
        Read non-chord staff text visibly printed in each narrow strip above a music system.
        Include rehearsal marks, D.C./D.S./Fine/Coda navigation, tempo changes, section names,
        instrument entrances, and performance instructions. Exclude all chord symbols, measure
        numbers, lyrics, dynamics such as p or mf, and musical notation. Never infer missing text.
        Report the zero-based bar containing the text's left edge using this crop geometry:
        \(geometry)
        """
        for (index, _, image) in crops { Attachment(image).label("system-\(index)") }
      }
      return response.content
    }

    static func clean(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func category(_ value: String) -> String {
      let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
      let allowed = ["rehearsal", "navigation", "tempo", "instruction", "instrument-cue", "section"]
      return allowed.contains(normalized) ? normalized : "other"
    }

    static func looksLikeChord(_ value: String) -> Bool {
      ChordText.normalizedSymbols(value) != nil
    }

    /// The category names the prompt lists. They describe kinds of text and
    /// are never printed on a score themselves.
    static let promptCategories: Set<String> = [
      "rehearsal marks", "rehearsal mark", "tempo changes", "tempo change", "section names",
      "section name", "instrument entrances", "instrument entrance", "performance instructions",
      "performance instruction", "navigation", "staff text", "chord symbols", "measure numbers",
      "dynamics", "lyrics",
    ]

    /// True when a strip's readings repeat the prompt instead of the page: any
    /// recited category name, or most of the navigation examples at once,
    /// which a real score does not print together on one line.
    static func isPromptEcho(_ texts: [String]) -> Bool {
      let lowered = texts.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
      if lowered.contains(where: promptCategories.contains) { return true }
      let navigation = Set(lowered).intersection(["d.c.", "d.s.", "fine", "coda"])
      return navigation.count >= 3
    }

    static func isNumberOnly(_ value: String) -> Bool {
      let meaningful = value.filter { !$0.isWhitespace && !$0.isPunctuation }
      return !meaningful.isEmpty && meaningful.allSatisfy(\.isNumber)
    }
  }
#endif
