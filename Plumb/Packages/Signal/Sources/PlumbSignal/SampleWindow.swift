import Foundation

/// One reading as kept in the short history: when, its height as measured, and its smoothed height.
struct TracePoint: Equatable, Sendable {
    var t: TimeInterval
    var rawMM: Double
    var smoothMM: Double
}

/// The last fraction of a second of readings, oldest first, in storage that is allocated once.
struct SampleWindow: Sendable {
    private var storage: [TracePoint]
    private var oldest = 0
    private(set) var count = 0
    private let spanS: Double

    init(capacity: Int, spanS: Double) {
        self.spanS = spanS
        storage = Array(repeating: TracePoint(t: 0, rawMM: 0, smoothMM: 0), count: max(1, capacity))
    }

    /// The reading at `index`, where 0 is the oldest kept.
    subscript(index: Int) -> TracePoint {
        storage[(oldest + index) % storage.count]
    }

    /// Adds a reading, letting go of any that are now older than the span or no longer fit.
    mutating func append(_ point: TracePoint) {
        while count > 0, self[0].t < point.t - spanS {
            dropOldest()
        }
        if count == storage.count {
            dropOldest()
        }
        storage[(oldest + count) % storage.count] = point
        count += 1
    }

    /// Forgets every reading.
    mutating func removeAll() {
        oldest = 0
        count = 0
    }

    private mutating func dropOldest() {
        oldest = (oldest + 1) % storage.count
        count -= 1
    }
}
