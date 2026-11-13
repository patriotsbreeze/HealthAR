import Foundation
import PlumbContracts

/// What the bar field shows, written by the app and read by the field once a frame.
/// A plain reference type on purpose: writing a sample must not invalidate any SwiftUI view.
@MainActor
public final class BarFieldModel {
    /// One entry in the field's history: a finished push, or a stretch with no pushes.
    public enum Mark: Equatable, Sendable {
        /// A finished push.
        case stroke(StrokeBar)
        /// A finished pause and how long it lasted.
        case pause(seconds: Double)
    }

    /// Finished pushes and pauses, oldest first. Never longer than `capacity`.
    public private(set) var marks: [Mark] = []
    /// How far below the top of the current stroke the hands are, in millimetres. Write it on every sample.
    public var liveDepthMM: Double = 0
    /// How far the measurement can be trusted right now. Decides how the live bar is drawn.
    public var trust: LockState = .lost
    /// The target lines drawn across the field, and the tempo that sets how fast a pause grows.
    public var targets: Targets
    /// Length of the pause in progress as last reported, in seconds. 0 while pushes are arriving.
    public private(set) var pauseSeconds: Double = 0
    /// When the newest finished push arrived. Times the step and the emphasis.
    public private(set) var lastStrokeAt: Date?
    /// How many history entries are kept.
    public let capacity: Int

    private var pauseReportedAt: Date?

    /// An empty field.
    public init(targets: Targets = .adult, capacity: Int = Theme.metrics.barHistory) {
        self.targets = targets
        self.capacity = max(1, capacity)
    }

    /// The finished pushes alone, oldest first.
    public var bars: [StrokeBar] {
        marks.compactMap { mark in
            if case .stroke(let bar) = mark { bar } else { nil }
        }
    }

    /// Adds a finished push. A pause in progress is closed and kept in the history first.
    public func append(_ bar: StrokeBar, at now: Date = Date()) {
        closePause()
        keep(.stroke(bar))
        lastStrokeAt = now
    }

    /// Reports the length of the pause in progress. Passing 0 ends it and keeps it in the history.
    public func setPause(seconds: Double, at now: Date = Date()) {
        guard seconds > 0 else {
            closePause()
            return
        }
        pauseSeconds = seconds
        pauseReportedAt = now
    }

    /// Copies the live depth and trust from the analyzer's per-sample report.
    public func update(_ live: LiveStroke) {
        liveDepthMM = live.currentDepthMM
        trust = live.lock
    }

    /// Empties the field for a new session.
    public func reset() {
        marks.removeAll()
        liveDepthMM = 0
        trust = .lost
        pauseSeconds = 0
        pauseReportedAt = nil
        lastStrokeAt = nil
    }

    /// The pause as it stands at `now`. Reports arrive a few times a second, so the field carries the
    /// count forward between them, but only briefly, so a stalled app cannot invent a pause.
    func pauseSeconds(at now: Date, coast: Double = Theme.metrics.pauseCoastSeconds) -> Double {
        guard pauseSeconds > 0, let pauseReportedAt else { return 0 }
        let sinceReport = now.timeIntervalSince(pauseReportedAt)
        return pauseSeconds + min(max(0, sinceReport), coast)
    }

    /// A copy of everything needed to draw the frame at `now`.
    func frame(at now: Date) -> BarFieldFrame {
        BarFieldFrame(marks: marks,
                      liveDepthMM: liveDepthMM,
                      trust: trust,
                      pauseSeconds: pauseSeconds(at: now),
                      targets: targets,
                      sinceLastStroke: lastStrokeAt.map { max(0, now.timeIntervalSince($0)) })
    }

    private func closePause() {
        guard pauseSeconds > 0 else { return }
        keep(.pause(seconds: pauseSeconds))
        pauseSeconds = 0
        pauseReportedAt = nil
    }

    private func keep(_ mark: Mark) {
        marks.append(mark)
        if marks.count > capacity {
            marks.removeFirst(marks.count - capacity)
        }
    }
}

/// Everything the field needs to draw one frame, copied out of the model so drawing touches no shared state.
struct BarFieldFrame: Equatable {
    var marks: [BarFieldModel.Mark] = []
    var liveDepthMM: Double = 0
    var trust: LockState = .lost
    var pauseSeconds: Double = 0
    var targets: Targets = .adult
    /// Seconds since the newest finished push arrived. Nil when there is none.
    var sinceLastStroke: Double?
}
