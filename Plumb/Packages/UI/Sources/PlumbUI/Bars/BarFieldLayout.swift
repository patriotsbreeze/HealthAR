import Foundation
import PlumbContracts

/// Where each finished push and pause sits for one frame, in slots counted leftwards from the live slot.
struct BarFieldLayout: Equatable {
    struct Stroke: Equatable {
        var bar: StrokeBar
        /// Slots from the right edge. 1 is the newest finished push once it has stepped.
        var slot: Double
        /// 0...1, how far the bar is widened towards filling its slot.
        var swell: Double
    }

    struct Block: Equatable {
        var fromSlot: Double
        var toSlot: Double
        var seconds: Double
        /// True for the pause still in progress, which carries the count.
        var isCurrent: Bool
    }

    var strokes: [Stroke] = []
    var blocks: [Block] = []
    /// False while paused, and whenever depth is not trusted enough to draw at all.
    var showsLiveBar: Bool
    /// 0...1, how far the target line is thickened by a push that has just reached it.
    var linePulse: Double

    init(frame: BarFieldFrame, slots: Int, reduceMotion: Bool, metrics: Theme.Metrics = Theme.metrics) {
        let limit = Double(slots)
        // A pause is as wide as the pushes it cost: one slot for each beat that went by.
        let slotsPerSecond = frame.targets.beatPerMin / 60
        let isPaused = frame.pauseSeconds > 0
        let emphasis = Self.emphasis(frame: frame, metrics: metrics)

        var cursor: Double
        if isPaused {
            let span = min(max(frame.pauseSeconds * slotsPerSecond, 1), limit)
            blocks.append(Block(fromSlot: 0, toSlot: span, seconds: frame.pauseSeconds, isCurrent: true))
            cursor = span
        } else {
            cursor = 1 - (reduceMotion ? 0 : Self.stepRemaining(frame: frame, metrics: metrics))
        }

        var isNewest = true
        for mark in frame.marks.reversed() {
            guard cursor < limit else { break }
            switch mark {
            case .stroke(let bar):
                // A bar is shown whole or not at all: a sliver at the edge reads as a shallow push.
                if cursor + 1 <= limit {
                    let swell = isNewest ? (reduceMotion ? emphasis.held : emphasis.decaying) : 0
                    strokes.append(Stroke(bar: bar, slot: cursor, swell: swell))
                }
                cursor += 1
            case .pause(let seconds):
                let span = max(seconds * slotsPerSecond, 1)
                blocks.append(Block(fromSlot: cursor, toSlot: min(cursor + span, limit), seconds: seconds,
                                    isCurrent: false))
                cursor += span
            }
            isNewest = false
        }

        showsLiveBar = !isPaused && (frame.trust == .locked || frame.trust == .estimating)
        linePulse = reduceMotion ? 0 : emphasis.decaying
    }

    /// How much of the one-slot step is still to go: 1 the instant a push arrives, 0 once it has settled.
    private static func stepRemaining(frame: BarFieldFrame, metrics: Theme.Metrics) -> Double {
        guard let since = frame.sinceLastStroke, metrics.stepSeconds > 0 else { return 0 }
        let progress = since / metrics.stepSeconds
        guard progress < 1 else { return 0 }
        return pow(1 - progress, metrics.stepEase)
    }

    /// Emphasis for the newest push, if it reached the line. `decaying` fades over the emphasis time;
    /// `held` stays on while the push is the newest, which is what Reduce Motion gets instead of a pulse.
    private static func emphasis(frame: BarFieldFrame, metrics: Theme.Metrics) -> (decaying: Double, held: Double) {
        guard case .stroke(let bar)? = frame.marks.last, BarStyle(bar) == .reached,
              let since = frame.sinceLastStroke, metrics.emphasisSeconds > 0 else { return (0, 0) }
        let progress = since / metrics.emphasisSeconds
        return (progress < 1 ? pow(1 - progress, metrics.emphasisEase) : 0, 1)
    }
}
