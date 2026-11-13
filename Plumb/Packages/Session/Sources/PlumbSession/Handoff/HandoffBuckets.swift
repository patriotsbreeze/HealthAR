import Foundation
import PlumbContracts

/// Cuts a session into equal slices of time for the session bar chart.
enum HandoffBuckets {
    static func make(compressions: [Compression], pauses: [HandoffStats.Pause], endT: TimeInterval,
                     config: SessionConfig) -> [HandoffStats.Bucket] {
        guard endT > 0 else { return [] }
        let width = sliceWidth(endT: endT, config: config)
        let count = max(1, Int((endT / width - config.sliverShare).rounded(.up)))

        var strokes = Array(repeating: [Compression](), count: count)
        for stroke in compressions {
            strokes[slot(of: stroke.tBottom, width: width, count: count)].append(stroke)
        }

        return (0..<count).map { index in
            let start = Double(index) * width
            // The last slice ends where the session ends, so the slices add up to the session.
            let end = index == count - 1 ? endT : start + width
            return HandoffStats.Bucket(
                start: start,
                lengthS: end - start,
                compressions: strokes[index].count,
                depthMM: Quantiles.median(strokes[index].trustedDepthsMM),
                pausedS: pausedSeconds(pauses, from: start, to: end))
        }
    }

    /// The asked-for width, widened when the session is long enough to need more slices than allowed.
    private static func sliceWidth(endT: TimeInterval, config: SessionConfig) -> Double {
        let asked = config.bucketS.isFinite && config.bucketS > 0 ? config.bucketS : SessionConfig.standard.bucketS
        return max(asked, endT / Double(max(1, config.maxBuckets)))
    }

    /// Which slice a moment falls in. Moments outside the session go to the nearest slice, so
    /// every compression in the log is counted exactly once.
    private static func slot(of t: TimeInterval, width: Double, count: Int) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        let slot = (t / width).rounded(.down)
        return slot >= Double(count) ? count - 1 : Int(slot)
    }

    private static func pausedSeconds(_ pauses: [HandoffStats.Pause], from start: TimeInterval,
                                      to end: TimeInterval) -> Double {
        pauses.reduce(0) { total, pause in
            total + max(0, min(end, pause.start + pause.durationS) - max(start, pause.start))
        }
    }
}
