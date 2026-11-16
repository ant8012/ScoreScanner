#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
import Foundation
#if canImport(Android)
import Android
#endif

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  import FoundationModels
#endif

/// Request slots shared by every reader. Chords, staff text, clefs and bar
/// lines are read side by side, so the limits apply to the whole scan rather
/// than to each reader.
enum AppleModelGates {
  /// Private Cloud Compute requests in flight, set from Settings when a scan
  /// starts.
  static let cloud = RequestGate(limit: 4)
  /// On-device requests in flight. Two is what a scan already ran on device
  /// before the readers overlapped: chords beside staff text.
  static let device = RequestGate(limit: 2)
}

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  /// Where one reader sends its requests, decided when the reader starts.
  @available(iOS 27.0, *)
  struct AppleModelRequester: Sendable {
    private let cloud: PrivateCloudComputeLanguageModel?
    private let preferPrivateCloud: Bool
    private let allowFallback: Bool
    private let unavailableReason: String?
    private let progress: @Sendable (String) -> Void

    /// Throws when Private Cloud Compute is preferred, is unavailable, and
    /// on-device fallback is off. `unavailable` is the status shown when the
    /// whole reader moves to the device instead.
    init(
      preferPrivateCloud: Bool, unavailable: String,
      progress: @escaping @Sendable (String) -> Void
    ) throws {
      self.preferPrivateCloud = preferPrivateCloud
      self.progress = progress
      allowFallback = AppleModelRoute.fallbackAllowed
      guard preferPrivateCloud else {
        cloud = nil
        unavailableReason = nil
        return
      }
      let model = PrivateCloudComputeLanguageModel()
      if model.isAvailable {
        cloud = model
        unavailableReason = nil
        return
      }
      let reason = String(describing: model.availability)
      guard allowFallback else { throw AppleModelRouteError.cloudUnavailable(reason) }
      progress(unavailable)
      cloud = nil
      unavailableReason = reason
    }

    /// One request. On Private Cloud Compute a short throttle is waited out
    /// and the request sent again. Any other failure reads just this request
    /// on device when fallback is on and `fallback` allows it; otherwise the
    /// scan stops, or with `fallback` false the cloud's error is rethrown for
    /// the caller to handle. A request marked `slow` takes the next free slot
    /// ahead of quicker ones, so it does not start last and hold up the scan.
    func respond<Value: Sendable>(
      _ name: String, slow: Bool = false, fallback: Bool = true,
      _ body: @escaping @Sendable (LanguageModelSession) async throws -> Value
    ) async throws -> ModelAnswer<Value> {
      let priority = slow ? 1 : 0
      guard let cloud else {
        return ModelAnswer(
          value: try await AppleModelGates.device.run(priority: priority) {
            try await body(LanguageModelSession())
          })
      }
      let allowFallback = allowFallback
      let progress = progress
      #if DEBUG
        let queued = ProcessInfo.processInfo.systemUptime
      #endif
      return try await ModelRequest.cloudFirst(
        classify: Self.classify,
        cloud: {
          try await AppleModelGates.cloud.run(priority: priority) {
            #if DEBUG
              try await AppleModelFaults.shared.check(name)
              // One line per request, for laying out a scan's timeline.
              let started = ProcessInfo.processInfo.systemUptime
              defer {
                print(
                  "SCANNER_PCC_REQUEST name=\(name) queued=\(queued) started=\(started) ended=\(ProcessInfo.processInfo.systemUptime)"
                )
              }
            #endif
            return try await body(LanguageModelSession(model: cloud))
          }
        },
        fallback: { error in
          guard fallback else { throw error }
          guard allowFallback else {
            throw AppleModelRouteError.cloudFailed("\(name): \(error.localizedDescription)")
          }
          progress("PCC request failed; reading \(name.lowercased()) on device")
          print("SCANNER_PCC fallback \(name): \(error.localizedDescription)")
          return try await AppleModelGates.device.run(priority: priority) {
            try await body(LanguageModelSession())
          }
        },
        onThrottle: { seconds in
          progress("PCC is throttling requests; retrying in \(Int(seconds.rounded())) s")
          print("SCANNER_PCC throttled \(name); retrying in \(String(format: "%.1f", seconds)) s")
        })
    }

    /// The route and note for the reader's report, from each request's name
    /// and answer.
    func route(_ requests: [(name: String, fallbackReason: String?)]) -> (
      route: String, note: String?
    ) {
      guard preferPrivateCloud else { return ("On-device", nil) }
      if let unavailableReason {
        return (ModelRoute.fallback, "PCC was unavailable: \(unavailableReason)")
      }
      return ModelRoute.summary(requests)
    }

    private static func classify(_ error: any Error) -> ModelRequestFailure {
      if let error = error as? LanguageModelError, case .rateLimited(let limit) = error {
        return .throttled(until: limit.resetDate)
      }
      return .failed
    }
  }

  #if DEBUG
    /// Launch arguments that make one named PCC request fail, so the fallback
    /// and throttle handling can be exercised on a device, where PCC rarely
    /// fails on demand. `-debugFailPCC "Chord measures 5–8"` fails that
    /// request every time; `-debugThrottlePCC "Chord measures 1–4"` throttles
    /// its first attempt for three seconds.
    @available(iOS 27.0, *)
    actor AppleModelFaults {
      static let shared = AppleModelFaults()
      private var throttled: Set<String> = []

      struct SimulatedFailure: LocalizedError {
        var errorDescription: String? { "Simulated PCC failure (debugFailPCC)" }
      }

      func check(_ name: String) throws {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "debugFailPCC") == name { throw SimulatedFailure() }
        if defaults.string(forKey: "debugThrottlePCC") == name, throttled.insert(name).inserted {
          throw LanguageModelError.rateLimited(
            .init(
              resetDate: Date().addingTimeInterval(3),
              debugDescription: "Simulated throttle (debugThrottlePCC)"))
        }
      }
    }
  #endif

  /// Consecutive runs of `size` indices, the way crops are sent to the model.
  func appleModelBatches(_ indices: [Int], size: Int = 4) -> [[Int]] {
    stride(from: 0, to: indices.count, by: size).map {
      Array(indices[$0..<min($0 + size, indices.count)])
    }
  }

  /// "Chord measures 5–8", numbered from one, for status lines and reports.
  func appleModelBatchName(_ label: String, _ batch: [Int]) -> String {
    guard let first = batch.first, let last = batch.last else { return label }
    return first == last ? "\(label) \(first + 1)" : "\(label) \(first + 1)–\(last + 1)"
  }
#endif

#if canImport(CoreGraphics)
/// A grey crop as an image for the model, enlarged so its short side is about `targetShortSide`: no detail is
/// added, the existing pixels are just given more room.
enum CropImage {
  static let targetShortSide = 260.0

  static func enlarged(pixels: Data, width: Int, height: Int) throws -> CGImage {
    guard width > 0, height > 0, pixels.count == width * height,
      let provider = CGDataProvider(data: pixels as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else { throw AppleChordReaderError.invalidCrop }
    let scale = min(6, max(1, Int(ceil(targetShortSide / Double(min(width, height))))))
    guard scale > 1 else { return image }
    guard
      let context = CGContext(
        data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
        bytesPerRow: width * scale, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
    return context.makeImage() ?? image
  }

  static func png(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
#endif

#if compiler(>=6.4) && canImport(FoundationModels) && os(iOS)
  @available(iOS 27.0, *)
  enum AppleModelAvailability {
    static var privateCloudAvailable: Bool { PrivateCloudComputeLanguageModel().isAvailable }
  }
#endif
