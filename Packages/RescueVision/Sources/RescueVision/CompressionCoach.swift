import Foundation
import simd

/// EXPERIMENTAL. How the person compressing compares with the ghost: hands on the chest, elbows
/// locked, rate, and keeping the ghost's beat. From on-phone pose of the rescuer only, sent nowhere,
/// and it gates nothing. Rate only, never depth, and silent on anything it can't see.
public struct CompressionFeedback: Sendable, Equatable {
    /// One correction at a time, the most important first.
    public enum Cue: String, Sendable, Equatable, CaseIterable {
        case handsToCenter
        case lockElbows
        case pushFaster
        case pushSlower
        case followBeat
    }

    public var perMinute: Double?
    public var armsLocked: Bool?
    public var handsOnChest: Bool?
    /// Beats the rescuer trails the ghost by, from -0.5 to 0.5.
    public var beatOffset: Double?

    /// Off the ghost's beat by more than this, in beats, a correction shows.
    public static let beatTolerance = 0.2

    public init(perMinute: Double? = nil, armsLocked: Bool? = nil, handsOnChest: Bool? = nil, beatOffset: Double? = nil) {
        self.perMinute = perMinute
        self.armsLocked = armsLocked
        self.handsOnChest = handsOnChest
        self.beatOffset = beatOffset
    }

    public var cue: Cue? {
        if handsOnChest == false { return .handsToCenter }
        if armsLocked == false { return .lockElbows }
        if let perMinute {
            switch CompressionRate(perMinute: perMinute, confidence: 1).verdict {
            case .tooSlow: return .pushFaster
            case .tooFast: return .pushSlower
            case .inRange: break
            }
        }
        if let beatOffset, abs(beatOffset) > Self.beatTolerance { return .followBeat }
        return nil
    }

    /// Everything seen and nothing to correct. Seeing less than all of it is never a match.
    public var matchesGhost: Bool {
        cue == nil && perMinute != nil && armsLocked == true && handsOnChest == true && beatOffset != nil
    }
}

/// Collects rescuer frames and turns them into feedback.
struct CompressionCoach: Sendable {
    /// Hands this far from the ghost's, along the floor, aren't on the centre of the chest.
    static let handsTolerance = 0.12
    /// Locked on this share of the last frames, so one jittery elbow doesn't flash a correction.
    static let lockedShare = 0.6
    static let lockWindow = 12
    /// Form from a frame older than this says nothing about now.
    static let maxFormAge: TimeInterval = 0.6

    private var rate = CompressionRateEstimator()
    private var locks: [Bool] = []
    private var lastHands: (onChest: Bool, at: TimeInterval)?
    private var lastSampleAt = -TimeInterval.infinity

    mutating func reset() {
        rate.reset()
        locks.removeAll()
        lastHands = nil
        lastSampleAt = -.infinity
    }

    /// - Parameter chest: The ghost's hands in this frame's capture image, and image heights per metre there.
    mutating func add(_ sample: CompressionSample, at time: TimeInterval, chest: (point: SIMD2<Double>, perMetre: Double)?, imageAspect: Double) {
        rate.add(sample, at: time)
        lastSampleAt = time
        if let locked = sample.armsLocked {
            locks.append(locked)
            if locks.count > Self.lockWindow { locks.removeFirst(locks.count - Self.lockWindow) }
        }
        if let chest, chest.perMetre > 0 {
            let offset = (sample.wrists - chest.point) * SIMD2(imageAspect, 1)
            lastHands = (simd_length(offset) / chest.perMetre <= Self.handsTolerance, time)
        }
    }

    func feedback(at now: TimeInterval, beatStart: TimeInterval?, interval: TimeInterval) -> CompressionFeedback? {
        guard now - lastSampleAt <= Self.maxFormAge else { return nil }
        let locked = locks.isEmpty ? nil : Double(locks.filter { $0 }.count) / Double(locks.count) >= Self.lockedShare
        let hands = lastHands.flatMap { now - $0.at <= Self.maxFormAge ? $0.onChest : nil }
        return CompressionFeedback(
            perMinute: rate.estimate(at: now)?.perMinute,
            armsLocked: locked,
            handsOnChest: hands,
            beatOffset: beatStart.flatMap { rate.beatOffset(at: now, beatStart: $0, interval: interval) }
        )
    }
}
