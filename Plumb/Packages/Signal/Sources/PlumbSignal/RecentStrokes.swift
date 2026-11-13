import Foundation

/// The rolling picture of the latest strokes: the typical rate and depth, and how much depth varies.
struct RecentStrokes: Sendable {
    private let rateWindow: Int
    private let depthWindow: Int
    private var intervalsS: [Double] = []
    /// Depths of the latest strokes, nil where the depth was measured without full trust.
    private var depthsMM: [Double?] = []

    /// Compressions per minute. Nil until two intervals exist.
    private(set) var ratePerMin: Double?
    /// Typical trusted depth. Nil when none of the latest strokes was trusted.
    private(set) var depthMM: Double?
    /// How far trusted depths typically stray from that. Nil below two trusted strokes.
    private(set) var depthSpreadMM: Double?

    init(rateWindow: Int, depthWindow: Int) {
        self.rateWindow = max(2, rateWindow)
        self.depthWindow = max(1, depthWindow)
        intervalsS.reserveCapacity(self.rateWindow + 1)
        depthsMM.reserveCapacity(self.depthWindow + 1)
    }

    /// Adds one compression. `intervalS` is nil when it does not follow straight on from the one before.
    mutating func add(depthMM depth: Double, trusted: Bool, intervalS: Double?) {
        depthsMM.append(trusted ? depth : nil)
        if depthsMM.count > depthWindow {
            depthsMM.removeFirst()
        }
        if let intervalS {
            intervalsS.append(intervalS)
            if intervalsS.count > rateWindow {
                intervalsS.removeFirst()
            }
        }
        summarise()
    }

    /// Forgets everything, as after a pause or a loss of signal: the old picture no longer describes now.
    mutating func clear() {
        intervalsS.removeAll(keepingCapacity: true)
        depthsMM.removeAll(keepingCapacity: true)
        summarise()
    }

    private mutating func summarise() {
        let typicalInterval = intervalsS.count >= 2 ? RobustStats.median(intervalsS) : nil
        ratePerMin = typicalInterval.flatMap { $0 > 0 ? 60 / $0 : nil }
        let trusted = depthsMM.compactMap { $0 }
        depthMM = RobustStats.median(trusted)
        depthSpreadMM = RobustStats.spread(trusted)
    }
}
