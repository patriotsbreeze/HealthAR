import Foundation

/// The height the top of the hands keeps coming back up to between compressions: the highest of
/// the hands' recent heights. Each height is first steadied by the median of the readings just
/// before it, because one noisy frame can lift a plain maximum but cannot lift a median of several.
///
/// Heights are metres up in the gravity-aligned world (ARKit's world y), times are seconds.
struct RestTopTracker: Sendable {
    /// Seconds of steadied heights the top is taken over.
    let spanS: TimeInterval
    /// Seconds of readings each height is steadied over.
    let steadyS: TimeInterval
    /// Fewest steadied heights in the span before there is a top.
    let minReadings: Int

    private var readings: [(t: TimeInterval, heightM: Double)] = []
    private var steadied: [(t: TimeInterval, heightM: Double)] = []

    /// Below this many readings in the steadying window a median cannot outvote one bad frame.
    static let minToSteady = 3

    init(spanS: TimeInterval, steadyS: TimeInterval, minReadings: Int) {
        self.spanS = spanS
        self.steadyS = steadyS
        self.minReadings = minReadings
    }

    /// The top of the stroke in metres, or nil until enough steadied heights have been seen lately.
    var topM: Double? {
        guard steadied.count >= max(minReadings, 1) else { return nil }
        return steadied.map(\.heightM).max()
    }

    /// Takes the height of the top of the hands seen at time `t`, and forgets what is now too old.
    mutating func add(_ heightM: Double, at t: TimeInterval) {
        advance(to: t)
        readings.append((t, heightM))
        guard readings.count >= Self.minToSteady else { return }
        steadied.append((t, Self.median(readings.map(\.heightM))))
    }

    /// Forgets what is too old at time `t`, without adding anything; call it on frames with no reading.
    mutating func advance(to t: TimeInterval) {
        // A clock that steps backwards means a new run; old heights would never age out.
        if let newest = readings.last?.t ?? steadied.last?.t, newest > t {
            reset()
        }
        readings.removeAll { $0.t <= t - steadyS }
        steadied.removeAll { $0.t <= t - spanS }
    }

    /// Forgets every height, as for a newly placed hands box.
    mutating func reset() {
        readings.removeAll()
        steadied.removeAll()
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
