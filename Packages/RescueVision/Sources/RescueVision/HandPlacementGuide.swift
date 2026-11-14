import Foundation
import Vision
import simd

/// The heel of one hand the camera sees, in capture image space.
struct SeenHand: Sendable, Equatable {
    var heel: SIMD2<Double>
    var confidence: Double
}

struct TimedHands: Sendable {
    var hands: [SeenHand]
    var capturedAt: TimeInterval
}

typealias HandFrameDetector = @Sendable (CapturedFrame, CaptureRotation) async -> [SeenHand]

/// Finds the rescuer's hands, which body pose misses when only the arms are in frame.
struct VisionHandDetector: Sendable {
    private let request: DetectHumanHandPoseRequest = {
        var request = DetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// The heel of the hand, which goes on the sternum, sits about this far from the wrist toward
    /// the middle knuckle.
    static let heelAlongPalm = 0.25
    static let minConfidence: Float = 0.3

    func detect(_ frame: CapturedFrame, rotation: CaptureRotation) async -> [SeenHand] {
        guard let observations = try? await request.perform(on: frame.pixels, orientation: rotation.cgOrientation) else { return [] }
        return observations.compactMap { hand in
            guard let wrist = hand.joint(for: .wrist), let knuckle = hand.joint(for: .middleMCP),
                  min(wrist.confidence, knuckle.confidence) >= Self.minConfidence else { return nil }
            let from = rotation.captureNormalized(fromVision: [wrist.location.x, wrist.location.y])
            let to = rotation.captureNormalized(fromVision: [knuckle.location.x, knuckle.location.y])
            return SeenHand(
                heel: simd_mix(from, to, SIMD2(repeating: Self.heelAlongPalm)),
                confidence: Double(min(wrist.confidence, knuckle.confidence))
            )
        }
    }
}

/// Which way the rescuer's hand should slide to reach the estimated sternum region, in the
/// patient's own frame, so it reads the same from either side of the body.
public struct HandGuidance: Sendable, Equatable {
    public enum Move: Sendable, Equatable {
        case onTarget, towardHead, towardFeet, towardMiddle
    }

    public var move: Move
    /// Rough, from torso proportions. Never a measurement.
    public var centimetres: Int

    public var text: String {
        switch move {
        case .onTarget: "Right spot. Lock your arms and push straight down"
        case .towardHead: "Slide your hands about \(centimetres) cm toward the head"
        case .towardFeet: "Slide your hands about \(centimetres) cm toward the feet"
        case .towardMiddle: "Move your hands about \(centimetres) cm to the middle of the chest"
        }
    }

    public static let noHandText = "Put the heel of your hand on the ring"
}

/// UNVALIDATED DEMO ESTIMATE, built on TorsoMap's, which is itself unvalidated.
enum HandPlacementGuide {
    /// TorsoMap's ring is about a palm, roughly 7 cm across its radius.
    static let ringRadiusCentimetres = 7.0
    /// Inside this share of the ring counts as on the spot, about 3.5 cm.
    static let onTargetShare = 0.5

    static func guide(hand: SIMD2<Double>, target: TorsoTarget, torso: TorsoKeypoints, imageAspect: Double) -> HandGuidance? {
        guard imageAspect > 0, target.radius > 0 else { return nil }
        let isotropic: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        let headwardRaw = isotropic(TorsoMap.bilinear(torso, u: 0.5, v: 0) - TorsoMap.bilinear(torso, u: 0.5, v: 1))
        guard simd_length(headwardRaw) > 1e-6 else { return nil }
        let headward = simd_normalize(headwardRaw)
        let across = SIMD2(-headward.y, headward.x)
        // Where the hand still has to go, in image heights.
        let offset = isotropic(target.center - hand)
        let toCentimetres = ringRadiusCentimetres / target.radius
        if simd_length(offset) <= target.radius * onTargetShare {
            return HandGuidance(move: .onTarget, centimetres: 0)
        }
        let along = simd_dot(offset, headward), side = simd_dot(offset, across)
        if abs(side) > abs(along) {
            return HandGuidance(move: .towardMiddle, centimetres: rounded(abs(side) * toCentimetres))
        }
        return HandGuidance(move: along > 0 ? .towardHead : .towardFeet, centimetres: rounded(abs(along) * toCentimetres))
    }

    /// The hand nearest the ring is the one being placed; with hands stacked, both sit there anyway.
    static func nearest(_ hands: [SeenHand], to target: TorsoTarget, imageAspect: Double) -> SeenHand? {
        let isotropic: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * imageAspect, $0.y] }
        return hands.min { simd_length(isotropic($0.heel - target.center)) < simd_length(isotropic($1.heel - target.center)) }
    }

    private static func rounded(_ centimetres: Double) -> Int { max(1, Int(centimetres.rounded())) }
}
