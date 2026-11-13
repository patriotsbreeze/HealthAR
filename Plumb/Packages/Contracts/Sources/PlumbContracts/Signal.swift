import Foundation

// The shared vocabulary of the measurement loop.
// Every other package builds against this file. Change it only on purpose.

// MARK: - Samples

/// One reading of how high the rescuer's hands are.
///
/// Millimetres, up positive, relative to a fixed reference chosen when tracking began.
/// Only differences between samples mean anything; the absolute value does not.
public struct HeightSample: Sendable, Codable, Equatable {
    /// Seconds since the session started. Monotonic, taken from the camera frame's own timestamp.
    public var t: TimeInterval
    public var heightMM: Double
    /// 0 is worthless, 1 is fully trusted.
    public var quality: Double

    public init(t: TimeInterval, heightMM: Double, quality: Double = 1) {
        self.t = t
        self.heightMM = heightMM
        self.quality = quality
    }
}

/// How far the measurement can be trusted right now.
public enum LockState: String, Sendable, Codable, CaseIterable {
    /// Depth and rate are both trusted. Depth may be judged and coached.
    case locked
    /// A signal is there but depth is not trusted. Draw it, never judge it.
    case estimating
    /// Only the rhythm is trusted.
    case rateOnly
    /// No usable signal.
    case lost
}

// MARK: - What the analyzer reports

/// One chest compression, reported shortly after its deepest point.
public struct Compression: Sendable, Codable, Equatable, Identifiable {
    public var id: Int { index }
    /// 1 for the first compression of the session.
    public var index: Int
    /// When the hands left the top of the stroke.
    public var tTop: TimeInterval
    /// When the hands were deepest.
    public var tBottom: TimeInterval
    /// Top of stroke minus deepest point, in millimetres. Always positive.
    public var depthMM: Double
    /// Seconds since the previous compression's deepest point. Nil for the first after a pause.
    public var intervalS: Double?
    /// Trust at the moment it was measured.
    public var lock: LockState

    public init(index: Int, tTop: TimeInterval, tBottom: TimeInterval, depthMM: Double,
                intervalS: Double?, lock: LockState) {
        self.index = index
        self.tTop = tTop
        self.tBottom = tBottom
        self.depthMM = depthMM
        self.intervalS = intervalS
        self.lock = lock
    }
}

/// Rolling summary of the session so far. Cheap to copy; published a few times a second.
public struct Metrics: Sendable, Codable, Equatable {
    public var t: TimeInterval
    public var lock: LockState
    /// Compressions counted this session.
    public var count: Int
    /// Compressions per minute over the last few strokes. Nil until two intervals exist.
    public var ratePerMin: Double?
    /// Typical depth of the last few strokes, in millimetres. Nil until one exists or when not trusted.
    public var depthMM: Double?
    /// Robust spread of the last few depths, in millimetres.
    public var depthSpreadMM: Double?
    public var secondsSinceLastCompression: Double?
    /// True once compressions have started and then stopped for longer than the pause threshold.
    public var isPaused: Bool
    /// Length of the current pause in seconds, measured from the last compression. 0 when not paused.
    public var pauseSeconds: Double
    /// Share of the time since the first compression spent compressing, 0...1.
    public var handsOnFraction: Double?
    public var firstCompressionAt: TimeInterval?

    public init(t: TimeInterval = 0, lock: LockState = .lost, count: Int = 0, ratePerMin: Double? = nil,
                depthMM: Double? = nil, depthSpreadMM: Double? = nil,
                secondsSinceLastCompression: Double? = nil, isPaused: Bool = false,
                pauseSeconds: Double = 0, handsOnFraction: Double? = nil,
                firstCompressionAt: TimeInterval? = nil) {
        self.t = t
        self.lock = lock
        self.count = count
        self.ratePerMin = ratePerMin
        self.depthMM = depthMM
        self.depthSpreadMM = depthSpreadMM
        self.secondsSinceLastCompression = secondsSinceLastCompression
        self.isPaused = isPaused
        self.pauseSeconds = pauseSeconds
        self.handsOnFraction = handsOnFraction
        self.firstCompressionAt = firstCompressionAt
    }

    public static let empty = Metrics()
}

/// Where the hands are inside the stroke happening now. Updated on every sample, for the live bar.
public struct LiveStroke: Sendable, Codable, Equatable {
    public var t: TimeInterval
    /// How far below the current top of stroke the hands are, in millimetres. Never negative.
    public var currentDepthMM: Double
    public var lock: LockState

    public init(t: TimeInterval = 0, currentDepthMM: Double = 0, lock: LockState = .lost) {
        self.t = t
        self.currentDepthMM = currentDepthMM
        self.lock = lock
    }
}

/// Discrete things the analyzer noticed.
public enum SignalEvent: Sendable, Codable, Equatable {
    case compression(Compression)
    /// Compressions stopped. `at` is the time of the last compression, not the time it was noticed.
    case pauseStarted(at: TimeInterval)
    case pauseEnded(at: TimeInterval, duration: Double)
    case lockChanged(LockState, at: TimeInterval)
}

// MARK: - Coaching

/// Everything the app can ever tell the rescuer. A closed set, chosen by rules, never by a model.
public enum Cue: String, Sendable, Codable, CaseIterable {
    case pushNow
    case pushHarder
    case faster
    case slower
    case good
}

/// Guideline targets for an adult.
public struct Targets: Sendable, Codable, Equatable {
    public var depthMinMM: Double
    public var depthMaxMM: Double
    public var rateMinPerMin: Double
    public var rateMaxPerMin: Double
    /// Tempo of the beat the app plays.
    public var beatPerMin: Double

    public init(depthMinMM: Double = 50, depthMaxMM: Double = 60, rateMinPerMin: Double = 100,
                rateMaxPerMin: Double = 120, beatPerMin: Double = 110) {
        self.depthMinMM = depthMinMM
        self.depthMaxMM = depthMaxMM
        self.rateMinPerMin = rateMinPerMin
        self.rateMaxPerMin = rateMaxPerMin
        self.beatPerMin = beatPerMin
    }

    public static let adult = Targets()
}
