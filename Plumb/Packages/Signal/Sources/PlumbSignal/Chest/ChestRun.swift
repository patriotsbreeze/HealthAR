import Foundation

/// One unbroken stretch of watching the chest: from the first usable sample after a gap until samples stop.
///
/// Samples are gathered into short bins, each bin stands for its median, and the medians are smoothed.
/// A swing is two smoothed points no more than one window apart whose heights differ by at least the
/// threshold: the same as the peak-to-peak over a sliding window reaching the threshold. The quiet stretch
/// is the time since the last swing began, so it says how long the chest has stayed inside the threshold.
struct ChestRun: Sendable {
    /// When the first usable sample of this stretch arrived.
    let startT: TimeInterval
    /// When the newest usable sample arrived.
    private(set) var lastSampleT: TimeInterval
    /// Start of the quiet stretch: no swing that began at or after this moment has been seen.
    private(set) var quietFrom: TimeInterval
    /// True once a swing has been seen in this stretch.
    private(set) var hasSwung = false

    private let config: ChestMovementAnalyzer.Config
    private var smoother: HeightSmoother
    /// One point per finished bin: its time, its median and its smoothed height.
    private var points: SampleWindow
    private var openBin: Int
    private var binHeights: [Double] = []
    /// The smoothing starts from the first bin alone, which is far noisier than a smoothed value.
    /// Bins before this moment are smoothed but not kept, so that start cannot pass as a swing.
    private let warmUpUntil: TimeInterval

    init(firstSampleAt t: TimeInterval, config: ChestMovementAnalyzer.Config) {
        self.config = config
        startT = t
        lastSampleT = t
        quietFrom = t
        smoother = HeightSmoother(timeConstantS: config.smoothingTimeS)
        points = SampleWindow(capacity: config.traceSlots + 2, spanS: config.traceS)
        openBin = Self.bin(of: t, binS: config.binS)
        warmUpUntil = t + Self.warmUpTimeConstants * config.smoothingTimeS
    }

    /// Takes one usable sample. A sample in a later bin finishes the open one first.
    /// `thresholdMM` is what counts as movement for the bin being finished.
    mutating func add(t: TimeInterval, heightMM: Double, thresholdMM: Double) {
        let bin = Self.bin(of: t, binS: config.binS)
        if bin != openBin {
            finishBin(thresholdMM: thresholdMM)
            openBin = bin
        }
        binHeights.append(heightMM)
        lastSampleT = t
    }

    /// Highest minus lowest smoothed height over the last window, in millimetres. Nil before the first bin.
    var swingMM: Double? {
        recentRange.map { $0.upperBound - $0.lowerBound }
    }

    /// The trace, ending at the newest finished bin. A bin with no usable sample inside the stretch
    /// holds the value before it, so a dropped frame does not break the line.
    func trace(thresholdMM: Double) -> ChestTrace {
        let slots = config.traceSlots
        guard points.count > 0 else { return .blank(config) }
        let newestBin = Self.bin(of: points[points.count - 1].t, binS: config.binS)
        let firstBin = newestBin - slots + 1
        let shown = (0..<points.count).map { points[$0] }
            .filter { Self.bin(of: $0.t, binS: config.binS) >= firstBin }
        let centre = RobustStats.median(shown.map(\.smoothMM)) ?? 0

        var values: [Double?] = Array(repeating: nil, count: slots)
        var held: Double?
        var next = 0
        for slot in 0..<slots {
            let bin = firstBin + slot
            while next < shown.count, Self.bin(of: shown[next].t, binS: config.binS) <= bin {
                held = shown[next].smoothMM - centre
                next += 1
            }
            values[slot] = held
        }

        let band = recentRange.map { range -> ClosedRange<Double> in
            let middle = (range.lowerBound + range.upperBound) / 2 - centre
            return (middle - thresholdMM / 2)...(middle + thresholdMM / 2)
        }
        return ChestTrace(stepS: config.binS, valuesMM: values, bandMM: band, bandSpanS: config.windowS)
    }
}

private extension ChestRun {
    /// Time constants after which the first bin's share of the smoothed value is under a twentieth.
    static let warmUpTimeConstants = 3.0

    static func bin(of t: TimeInterval, binS: Double) -> Int {
        Int((t / binS).rounded(.down))
    }

    /// True when a bin at `t` lies inside the window that ends with the bin at `end`.
    /// Bin times sit half a bin from any boundary, so rounding cannot move one in or out.
    func isInWindow(_ t: TimeInterval, endingAt end: TimeInterval) -> Bool {
        end - t < config.windowS - config.binS / 2
    }

    /// Lowest and highest smoothed height over the last window.
    var recentRange: ClosedRange<Double>? {
        guard points.count > 0 else { return nil }
        let newestT = points[points.count - 1].t
        var low = Double.infinity
        var high = -Double.infinity
        for index in stride(from: points.count - 1, through: 0, by: -1) {
            let point = points[index]
            guard isInWindow(point.t, endingAt: newestT) else { break }
            low = min(low, point.smoothMM)
            high = max(high, point.smoothMM)
        }
        return low...high
    }

    /// Turns the open bin into a point and looks for a swing that ends at it.
    mutating func finishBin(thresholdMM: Double) {
        guard let median = RobustStats.median(binHeights) else { return }
        binHeights.removeAll(keepingCapacity: true)
        let t = (Double(openBin) + 0.5) * config.binS
        let smoothMM = smoother.smooth(CleanReading(t: t, heightMM: median))
        guard t >= warmUpUntil else { return }
        points.append(TracePoint(t: t, rawMM: median, smoothMM: smoothMM))
        findSwing(endingAt: t, smoothMM: smoothMM, thresholdMM: thresholdMM)
    }

    /// Looks back over the window for the newest point that differs from this one by the threshold.
    /// Only a swing that began inside the quiet stretch moves its start, so the stretch never grows back.
    mutating func findSwing(endingAt t: TimeInterval, smoothMM: Double, thresholdMM: Double) {
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            let earlier = points[index]
            guard isInWindow(earlier.t, endingAt: t), earlier.t + config.binS > quietFrom else { return }
            if abs(smoothMM - earlier.smoothMM) >= thresholdMM {
                quietFrom = earlier.t + config.binS
                hasSwung = true
                return
            }
        }
    }
}
