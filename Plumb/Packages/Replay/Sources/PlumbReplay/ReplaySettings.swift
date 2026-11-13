import Foundation
import PlumbContracts
import PlumbGeometry
import PlumbSignal

/// How a trace is replayed. The defaults are what the app runs live.
public struct ReplaySettings: Sendable {
    /// Which height method turns frames into samples. The app's default is along the line of sight.
    public var method: HeightEstimator.Method
    /// Where the distance to the hands comes from.
    public var range: RangeSource
    /// What every height is multiplied by before the analyzer sees it. 1 changes nothing.
    public var gain: Gain
    /// The height estimator's numbers. The app ships the documented defaults.
    public var estimator: HeightEstimator.Config
    /// The compression analyzer's numbers. The app ships the documented defaults.
    public var analyzer: CompressionAnalyzer.Config
    /// The targets the analyzer scales a believable stroke by.
    public var targets: Targets
    /// How often the analyzer is ticked between samples, per second of trace time. The app ticks ten times a second.
    public var ticksPerSecond: Double

    /// Settings for a replay; every argument defaults to what the app runs live.
    public init(method: HeightEstimator.Method = .alongRay, range: RangeSource = .measured, gain: Gain = .unit,
                estimator: HeightEstimator.Config = .init(), analyzer: CompressionAnalyzer.Config = .init(),
                targets: Targets = .adult, ticksPerSecond: Double = 10) {
        self.method = method
        self.range = range
        self.gain = gain
        self.estimator = estimator
        self.analyzer = analyzer
        self.targets = targets
        self.ticksPerSecond = ticksPerSecond
    }
}

/// Where the distance from the camera to the hands comes from.
public enum RangeSource: Sendable, Equatable {
    /// The LiDAR depth recorded in each frame, as on the phone.
    case measured
    /// No LiDAR at all: the hands are taken to be this many metres away on every frame, as a
    /// camera-only phone would have to assume. See `CameraOnly` for exactly what is changed.
    case assumed(metres: Double)
}

/// A multiplier for every height, and the recording it was fitted on, if any.
public struct Gain: Sendable, Equatable {
    /// What each height is multiplied by.
    public var value: Double
    /// The recording the gain was fitted on. A replay of that same recording is never scored with it.
    /// Nil for a gain typed in by hand, whose origin is not known.
    public var fittedOn: TraceFingerprint?

    /// A gain from its value and, when it was fitted here, the recording it came from.
    public init(value: Double, fittedOn: TraceFingerprint? = nil) {
        self.value = value
        self.fittedOn = fittedOn
    }

    /// Leaves every height as measured.
    public static let unit = Gain(value: 1)
}
