import Foundation

/// Keeps the books on pauses and hands-on time.
///
/// Every time here is on the "seen" clock: seconds during which a signal was present.
/// The clock stands still while the signal is lost, so time the analyzer could not see
/// is never counted as a pause, nor as compressing.
struct PauseLedger: Sendable {
    private let pauseAfterS: Double
    private(set) var isPaused = false
    private var firstStrokeAt: Double?
    private var lastStrokeAt: Double?
    private var finishedPausesS = 0.0

    init(pauseAfterS: Double) {
        self.pauseAfterS = pauseAfterS
    }

    /// Starts a pause once no compression has been seen for longer than the threshold. True when one just began.
    mutating func beginPauseIfDue(now: Double) -> Bool {
        guard !isPaused, let lastStrokeAt, now - lastStrokeAt > pauseAfterS else { return false }
        isPaused = true
        return true
    }

    /// Records a compression's deepest point. Returns the length of the pause it ended, if it ended one.
    mutating func recordStroke(at t: Double) -> Double? {
        defer {
            lastStrokeAt = t
            firstStrokeAt = firstStrokeAt ?? t
        }
        guard isPaused, let lastStrokeAt else { return nil }
        isPaused = false
        let length = max(0, t - lastStrokeAt)
        finishedPausesS += length
        return length
    }

    /// Length of the pause in progress, counted from the last compression. Zero when not paused.
    func currentPauseS(now: Double) -> Double {
        guard isPaused, let lastStrokeAt else { return 0 }
        return max(0, now - lastStrokeAt)
    }

    /// Share of the seen time since the first compression that was not spent paused. Nil before the first one.
    func handsOnFraction(now: Double) -> Double? {
        guard let firstStrokeAt else { return nil }
        let elapsed = now - firstStrokeAt
        guard elapsed > 0 else { return 1 }
        let paused = finishedPausesS + currentPauseS(now: now)
        return min(1, max(0, 1 - paused / elapsed))
    }
}
