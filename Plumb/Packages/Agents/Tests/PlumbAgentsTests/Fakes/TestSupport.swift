import Foundation
import PlumbContracts
@testable import PlumbAgents

/// A value several tasks can read and change safely.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        lock.withLock { value }
    }

    @discardableResult
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

/// Polls until the condition holds or the time runs out. Returns whether it held.
/// Timed on a clock that stops while the machine sleeps, so a nap mid-test is not a failure.
func eventually(within timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A session clock that hands out a fixed list of times, then repeats the last one.
final class StepClock: Sendable {
    private let times: Locked<[TimeInterval]>

    init(_ times: [TimeInterval]) {
        self.times = Locked(times)
    }

    func now() -> TimeInterval {
        times.with { $0.count > 1 ? $0.removeFirst() : ($0.first ?? 0) }
    }
}

/// Holds tasks at a door until it is opened. Ignores cancellation on purpose, to stand in for a
/// tool that does not cooperate.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    var waiting: Int {
        lock.withLock { waiters.count }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        released.forEach { $0.resume() }
    }
}

/// A digest with ordinary, trusted numbers.
func freshDigest() -> WorldDigest {
    WorldDigest(lock: .locked, count: 87, ratePerMin: 111.7, depthMM: 54.2, depthSpreadMM: 3.4,
                isPaused: false, pauseSeconds: 0, handsOnFraction: 0.874, ageS: 0.42, stale: false)
}

/// The key used wherever a test needs to prove the key does not leak.
let secretKey = "AIzaSy-TEST-KEY-0123456789abcdef"
