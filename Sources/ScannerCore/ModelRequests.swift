import Foundation

/// Limits how many model requests are in flight at once. Waiting requests are
/// served by priority, then in the order they arrived.
///
/// A Private Cloud Compute request spends most of its few seconds waiting on
/// the network, and a scan's requests do not depend on one another, so sending
/// several at once cuts the wait without changing any answer. Apple publishes
/// no limit on how many an app may send together, so the limit is a setting.
public actor RequestGate {
  private var limit: Int
  private var running = 0
  private var waiting: [(priority: Int, continuation: CheckedContinuation<Void, Never>)] = []

  public init(limit: Int) { self.limit = max(1, limit) }

  public func setLimit(_ newLimit: Int) {
    limit = max(1, newLimit)
    while running < limit, !waiting.isEmpty {
      running += 1
      next().resume()
    }
  }

  private func acquire(priority: Int) async {
    if running < limit {
      running += 1
      return
    }
    await withCheckedContinuation { waiting.append((priority, $0)) }
  }

  private func release() {
    // The slot passes straight to the next waiter, unless the limit was
    // lowered while it was taken.
    if running <= limit, !waiting.isEmpty {
      next().resume()
    } else {
      running -= 1
    }
  }

  /// The earliest of the highest-priority waiters.
  private func next() -> CheckedContinuation<Void, Never> {
    let top = waiting.map(\.priority).max()!
    return waiting.remove(at: waiting.firstIndex { $0.priority == top }!).continuation
  }

  /// Runs `body` once a slot is free and frees the slot afterwards. A waiting
  /// request with a higher `priority` gets the next free slot first, so a
  /// request known to be slow can start before quick ones queued ahead of it.
  public nonisolated func run<T: Sendable>(
    priority: Int = 0, _ body: @Sendable () async throws -> T
  ) async throws -> T {
    await acquire(priority: priority)
    do {
      try Task.checkCancellation()
      let value = try await body()
      await release()
      return value
    } catch {
      await release()
      throw error
    }
  }
}

/// Why a model request failed, as far as sending it again is concerned.
public enum ModelRequestFailure: Sendable, Equatable {
  /// The service is throttling requests. The same request can be sent again
  /// once the throttle resets; `until` is when, if the service said.
  case throttled(until: Date?)
  /// Sending the same request again will not help.
  case failed
}

/// One reading, and why it came from the fallback instead of the cloud when
/// it did.
public struct ModelAnswer<Value: Sendable>: Sendable {
  public let value: Value
  public let fallbackReason: String?

  public init(value: Value, fallbackReason: String? = nil) {
    self.value = value
    self.fallbackReason = fallbackReason
  }
}

public struct ModelRequestPolicy: Sendable {
  /// A throttle that resets later than this is not waited out; the request
  /// goes to the fallback instead.
  public var longestWait: TimeInterval
  /// How many times one request is sent again after being throttled.
  public var retries: Int
  /// The wait before the first retry when the throttle gives no reset time.
  /// Each later retry waits twice as long.
  public var firstBackoff: TimeInterval

  public init(longestWait: TimeInterval, retries: Int, firstBackoff: TimeInterval) {
    self.longestWait = longestWait
    self.retries = retries
    self.firstBackoff = firstBackoff
  }

  public static let standard = ModelRequestPolicy(longestWait: 60, retries: 3, firstBackoff: 2)
}

public enum ModelRequest {
  /// Sends one request to the cloud. A short throttle is waited out and the
  /// same request sent again; any other failure, or a throttle that will not
  /// reset soon, hands just this request to `fallback` with the cloud's error.
  /// Cancellation is never a failure and is always rethrown.
  public static func cloudFirst<Value: Sendable>(
    policy: ModelRequestPolicy = .standard,
    classify: @Sendable (any Error) -> ModelRequestFailure,
    cloud: @Sendable () async throws -> Value,
    fallback: @Sendable (any Error) async throws -> Value,
    onThrottle: @Sendable (TimeInterval) -> Void = { _ in },
    sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    now: @Sendable () -> Date = { Date() }
  ) async throws -> ModelAnswer<Value> {
    var retries = 0
    while true {
      do {
        return ModelAnswer(value: try await cloud())
      } catch {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
        if case .throttled(let until) = classify(error), retries < policy.retries {
          let wait = max(
            0, until?.timeIntervalSince(now()) ?? policy.firstBackoff * pow(2, Double(retries)))
          if wait <= policy.longestWait {
            retries += 1
            onThrottle(wait)
            try await sleep(wait)
            continue
          }
        }
        return ModelAnswer(value: try await fallback(error), fallbackReason: error.localizedDescription)
      }
    }
  }
}

public enum ModelRoute {
  public static let cloud = "Private Cloud Compute"
  public static let fallback = "On-device fallback"

  /// The route and note for a reader whose requests went to Private Cloud
  /// Compute first, from each request's name and fallback reason. Only the
  /// requests that failed were read on device, so the note names them.
  public static func summary(_ requests: [(name: String, fallbackReason: String?)]) -> (
    route: String, note: String?
  ) {
    let fellBack = requests.compactMap { request in
      request.fallbackReason.map { (request.name, $0) }
    }
    guard !fellBack.isEmpty else { return (cloud, nil) }
    let route = fellBack.count == requests.count ? fallback : "\(cloud) + on-device fallback"
    let note = fellBack.map { "\($0.0) read on device. PCC request failed: \($0.1)" }
      .joined(separator: "\n")
    return (route, note)
  }
}

public enum Concurrently {
  /// Runs `body` for every element at once and returns the results in the
  /// elements' order. `finished` is called as each one completes, in the order
  /// they complete, for progress. The first error cancels the rest. Bound the
  /// work with a `RequestGate` inside `body`.
  public static func map<Element: Sendable, Result: Sendable>(
    _ elements: [Element],
    _ body: @escaping @Sendable (Element) async throws -> Result,
    finished: (Element, Result) -> Void = { _, _ in }
  ) async throws -> [Result] {
    try await withThrowingTaskGroup(of: (Int, Result).self) { group in
      for (index, element) in elements.enumerated() {
        group.addTask { (index, try await body(element)) }
      }
      var results = [Result?](repeating: nil, count: elements.count)
      for try await (index, result) in group {
        results[index] = result
        finished(elements[index], result)
      }
      return results.map { $0! }
    }
  }
}
