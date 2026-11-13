import PlumbContracts

/// Counts compressions and remembers where the current unbroken run of them began.
struct RunTally: Equatable, Sendable {
    /// Compressions counted this session.
    private(set) var total = 0
    /// The value of `total` when the last pause was seen. 0 until there has been one.
    private var totalAtLastPause = 0

    /// True once the first compression of the session has been counted.
    var hasStarted: Bool { total > 0 }

    /// Compressions since the session start or the last pause, whichever came later.
    var sincePause: Int { total - totalAtLastPause }

    /// Takes in one look's worth of news. Returns true when a pause was seen, which ends the current run.
    mutating func absorb(metrics: Metrics, events: [SignalEvent]) -> Bool {
        var sawPause = metrics.isPaused
        // Events are walked in order so that a pause which began and ended between two looks
        // still splits the compressions before it from the ones after it.
        for event in events {
            switch event {
            case .compression(let compression):
                total = max(total, compression.index)
            case .pauseStarted:
                totalAtLastPause = total
                sawPause = true
            case .pauseEnded, .lockChanged:
                // Metrics is always current for these, so the events add nothing here.
                break
            }
        }
        total = max(total, metrics.count)
        if metrics.isPaused { totalAtLastPause = total }
        return sawPause
    }
}
