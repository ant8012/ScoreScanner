import Foundation
import Testing

@testable import ScannerCore

struct ModelRequestTests {
  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
  }

  private actor Log {
    var calls = 0
    var waits: [TimeInterval] = []
    var running = 0
    var mostRunning = 0

    func call() -> Int {
      calls += 1
      return calls
    }
    func wait(_ seconds: TimeInterval) { waits.append(seconds) }
    func start() {
      running += 1
      mostRunning = max(mostRunning, running)
    }
    func stop() { running -= 1 }
  }

  private let start = Date(timeIntervalSinceReferenceDate: 0)

  /// Throttled whenever the description says so, with the reset time given.
  private func classify(reset: Date?) -> @Sendable (any Error) -> ModelRequestFailure {
    { error in
      (error as? Failure)?.errorDescription == "throttled" ? .throttled(until: reset) : .failed
    }
  }

  @Test func gateNeverRunsMoreThanItsLimitAndKeepsOrder() async throws {
    let gate = RequestGate(limit: 3)
    let log = Log()
    let results = try await Concurrently.map(Array(0..<10)) { value in
      try await gate.run {
        await log.start()
        try await Task.sleep(for: .milliseconds(20))
        await log.stop()
        return value * 2
      }
    }
    #expect(results == (0..<10).map { $0 * 2 })
    #expect(await log.mostRunning == 3)
  }

  @Test func raisingTheLimitStartsWaitingRequests() async throws {
    let gate = RequestGate(limit: 1)
    let log = Log()
    async let results = Concurrently.map(Array(0..<4)) { value in
      try await gate.run {
        await log.start()
        try await Task.sleep(for: .milliseconds(60))
        await log.stop()
        return value
      }
    }
    try await Task.sleep(for: .milliseconds(10))
    await gate.setLimit(4)
    #expect(try await results == [0, 1, 2, 3])
    #expect(await log.mostRunning == 4)
  }

  @Test func higherPriorityWaiterGetsTheNextSlot() async throws {
    let gate = RequestGate(limit: 1)
    let order = Order()
    async let holder: Void = gate.run { try await Task.sleep(for: .milliseconds(50)) }
    try await Task.sleep(for: .milliseconds(10))
    async let quick: Void = gate.run { await order.append("quick") }
    try await Task.sleep(for: .milliseconds(10))
    async let slow: Void = gate.run(priority: 1) { await order.append("slow") }
    _ = try await (holder, quick, slow)
    #expect(await order.names == ["slow", "quick"])
  }

  private actor Order {
    var names: [String] = []
    func append(_ name: String) { names.append(name) }
  }

  @Test func shortThrottleIsWaitedOutAndSentAgain() async throws {
    let log = Log()
    let answer = try await ModelRequest.cloudFirst(
      classify: classify(reset: start.addingTimeInterval(5)),
      cloud: {
        if await log.call() == 1 { throw Failure("throttled") }
        return "cloud"
      },
      fallback: { _ in "device" },
      sleep: { await log.wait($0) },
      now: { [start] in start })
    #expect(answer.value == "cloud")
    #expect(answer.fallbackReason == nil)
    #expect(await log.waits == [5])
  }

  @Test func throttleWithoutResetBacksOffThenFallsBack() async throws {
    let log = Log()
    let answer = try await ModelRequest.cloudFirst(
      classify: classify(reset: nil),
      cloud: { () async throws -> String in
        _ = await log.call()
        throw Failure("throttled")
      },
      fallback: { _ in "device" },
      sleep: { await log.wait($0) })
    #expect(answer.value == "device")
    #expect(answer.fallbackReason == "throttled")
    #expect(await log.waits == [2, 4, 8])
    #expect(await log.calls == 4)
  }

  @Test func throttleResettingTooLateGoesStraightToFallback() async throws {
    let log = Log()
    let answer = try await ModelRequest.cloudFirst(
      classify: classify(reset: start.addingTimeInterval(3600)),
      cloud: { () async throws -> String in throw Failure("throttled") },
      fallback: { _ in "device" },
      sleep: { await log.wait($0) },
      now: { [start] in start })
    #expect(answer.value == "device")
    #expect(await log.waits.isEmpty)
  }

  @Test func otherFailureFallsBackOnceWithoutRetrying() async throws {
    let log = Log()
    let answer = try await ModelRequest.cloudFirst(
      classify: classify(reset: nil),
      cloud: { () async throws -> String in
        _ = await log.call()
        throw Failure("guardrail")
      },
      fallback: { error in "device after \(error.localizedDescription)" },
      sleep: { await log.wait($0) })
    #expect(answer.value == "device after guardrail")
    #expect(answer.fallbackReason == "guardrail")
    #expect(await log.calls == 1)
    #expect(await log.waits.isEmpty)
  }

  @Test func fallbackThatRefusesStopsTheRequest() async {
    await #expect(throws: Failure.self) {
      try await ModelRequest.cloudFirst(
        classify: classify(reset: nil),
        cloud: { () async throws -> String in throw Failure("guardrail") },
        fallback: { error in throw error })
    }
  }

  @Test func cancellationIsNeverSentToFallback() async {
    let log = Log()
    await #expect(throws: CancellationError.self) {
      try await ModelRequest.cloudFirst(
        classify: classify(reset: nil),
        cloud: { () async throws -> String in throw CancellationError() },
        fallback: { _ in
          _ = await log.call()
          return "device"
        })
    }
    #expect(await log.calls == 0)
  }

  @Test func firstErrorStopsTheWholeMap() async {
    await #expect(throws: Failure.self) {
      try await Concurrently.map(Array(0..<5)) { value in
        if value == 2 { throw Failure("stop") }
        try await Task.sleep(for: .seconds(5))
        return value
      }
    }
  }

  @Test func routeNamesOnlyTheRequestsThatFellBack() {
    #expect(ModelRoute.summary([("a", nil), ("b", nil)]).route == "Private Cloud Compute")
    #expect(ModelRoute.summary([("a", nil), ("b", nil)]).note == nil)

    let mixed = ModelRoute.summary([("Measures 1–4", nil), ("Measures 5–8", "refused")])
    #expect(mixed.route == "Private Cloud Compute + on-device fallback")
    #expect(mixed.note == "Measures 5–8 read on device. PCC request failed: refused")

    #expect(ModelRoute.summary([("a", "x"), ("b", "y")]).route == "On-device fallback")
  }
}
