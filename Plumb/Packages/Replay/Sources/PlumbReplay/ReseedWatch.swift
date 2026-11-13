import Foundation
import PlumbGeometry

/// Notices where the phone placed the hands box again during a recording.
///
/// The phone starts its height estimator afresh whenever the box is placed, but a trace has no line
/// that says so. It does lay a new brightness grid each time, and only then: within one placement the
/// grid's row spacing never changes, so a frame whose spacing differs from the one before is the
/// first of a new placement.
struct ReseedWatch: Sendable {
    private var pitchPx: Double?

    /// True when `frame` is the first of a new placement. Frames without a grid say nothing.
    mutating func isNewPlacement(_ frame: TraceFrame) -> Bool {
        guard let pitch = frame.handsLuma?.pitchPx else { return false }
        defer { pitchPx = pitch }
        guard let previous = pitchPx else { return false }
        return pitch != previous
    }
}
