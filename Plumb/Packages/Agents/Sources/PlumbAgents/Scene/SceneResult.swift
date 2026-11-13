import Foundation
import PlumbContracts

/// One camera frame handed to the scene finder, with the means to test points in it.
public struct SceneCapture: Sendable {
    /// The requested region of the frame as a JPEG.
    public var jpeg: Data
    /// Measures the depth around a point given relative to the whole frame. Nil when it cannot.
    public var probe: @Sendable (ScenePoint) async -> SceneProbe?

    /// Creates a capture from one frame's JPEG and that frame's depth probe.
    public init(jpeg: Data, probe: @escaping @Sendable (ScenePoint) async -> SceneProbe?) {
        self.jpeg = jpeg
        self.probe = probe
    }
}

/// One of the model's guesses together with what the sensors made of it.
public struct SceneProposal: Sendable, Equatable {
    /// Where the model pointed, relative to the whole frame.
    public var point: ScenePoint
    /// 1 for the first look, 2 for the zoomed second look.
    public var round: Int
    /// What the depth sensor made of the point.
    public var verdict: SceneVerdict

    /// Creates a proposal from a point, the look it came from and its verdict.
    public init(point: ScenePoint, round: Int, verdict: SceneVerdict) {
        self.point = point
        self.round = round
        self.verdict = verdict
    }
}

/// Everything one search produced, for the log and the "show working" view.
public struct SceneResult: Sendable, Equatable {
    /// What was looked for.
    public var label: String
    /// Every guess with its verdict: first look then second look, nearest first within each.
    public var proposals: [SceneProposal]
    /// The guess the sensors agreed with, if any.
    public var accepted: SceneProposal?
    /// How many frames were sent to the model: 0, 1 or 2.
    public var looks: Int
    /// One plain sentence when a frame or the model was unavailable.
    public var failure: String?

    /// Creates a result. The defaults describe a search that has not looked yet.
    public init(label: String, proposals: [SceneProposal] = [], accepted: SceneProposal? = nil,
                looks: Int = 0, failure: String? = nil) {
        self.label = label
        self.proposals = proposals
        self.accepted = accepted
        self.looks = looks
        self.failure = failure
    }

    /// One `.found` entry per verdict, in the same order as `proposals`.
    public var logBodies: [LogEntry.Body] {
        proposals.map {
            .found(label: label, distanceM: $0.verdict.distanceM, accepted: $0.verdict.accepted,
                   reason: $0.verdict.reason)
        }
    }
}
