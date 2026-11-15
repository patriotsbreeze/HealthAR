import CoreGraphics
import Foundation
import simd

/// A see-through rescuer kneeling at the patient's side, pushing on the metronome's beat, for the
/// person compressing to match. Placed in the world once from the chest pose found at the start of
/// compressions, then drawn from the camera's pose alone, so it takes no pixels while it shows.
/// It sends nothing and gates nothing. Manikin only, like every mark on the body.
public enum GhostJoint: String, CaseIterable, Sendable, Hashable {
    case head, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    /// Both hands stacked on the chest.
    case hands
    case pelvis
    case leftKnee, rightKnee
    case leftFoot, rightFoot

    /// What the painter joins. The head draws as a disc on `head`.
    public static let bones: [(GhostJoint, GhostJoint)] = [
        (.neck, .pelvis),
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .hands),
        (.rightShoulder, .rightElbow), (.rightElbow, .hands),
        (.pelvis, .leftKnee), (.leftKnee, .leftFoot),
        (.pelvis, .rightKnee), (.rightKnee, .rightFoot),
    ]
}

/// Where and how to draw the 3D ghost this frame. Model space is the one tools/make_ghost_model.py
/// builds in: +x toward the patient's head, +y up, +z toward the rescuer's side, origin on the chest.
public struct GhostPlacement: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        /// Nobody seen compressing yet, or not enough to say.
        case neutral
        /// Hands, elbows, rate and beat all match the ghost.
        case matching
        /// Something to correct, which the band names.
        case correcting
    }

    /// Model space to world, unpressed.
    public var transform: simd_float4x4
    /// 0 up to 1 pressed.
    public var push: Double
    /// Fill the patient in, for practice with nobody there. On a body found by pose only its outline
    /// is drawn, round the real one.
    public var practice: Bool
    /// The patient model's size against the body found. 1 for practice.
    public var patientScale: Float
    public var tone: Tone

    /// The model's upper body moves this far down on a full push.
    public static let depth = GhostRescuer.depth
    /// See-through, never strong enough to hide the person compressing, and a little stronger on the click.
    public static let opacity: Float = 0.45
    public static let pushOpacity: Float = 0.1
    public static let patientOpacity: Float = 0.35
    public static let outlineOpacity: Float = 0.85
}

/// Where to draw the stacked hands on the chest: hand space, from tools/make_ghost_model.py, to world.
/// Heel of the lower hand on the chest, +z toward the rescuer, fingers away from them.
public struct HandsPlacement: Sendable, Equatable {
    public var transform: simd_float4x4

    /// Blue glass, see-through so the chest shows under them. Each hand is one closed skin, so nothing
    /// inside it shows through.
    public static let opacity: Float = 0.6
}

/// Where the ghost kneels, in world coordinates with gravity along -y.
struct GhostAnchor: Sendable, Equatable {
    var chest: SIMD3<Float>
    /// Level, from the chest toward the patient's head.
    var headward: SIMD3<Float>
    /// Level, from the chest toward where the ghost kneels.
    var side: SIMD3<Float>
    /// The body found, against the model's adult: shoulders to hips over the model's. 1 when unmeasured.
    var bodyScale: Float = 1

    /// The patient model's shoulders to hips, in metres.
    static let modelTorso: Float = 0.57
    /// A child-size manikin to a large adult. Outside this the measurement is more likely wrong than the body.
    static let bodyScales: ClosedRange<Float> = 0.6...1.25

    static let up = SIMD3<Float>(0, 1, 0)

    /// The ghost kneels on the patient's far side from the camera, facing it, so its body never
    /// stands between the phone and the chest. From a phone held over the chest no side reads as
    /// far, so the rescuer is taken to be at the bottom of the screen, `cameraDown`, where the person
    /// holding it kneels. Nil overhead without it.
    init?(chest: SIMD3<Float>, shoulders: SIMD3<Float>?, hips: SIMD3<Float>? = nil, camera: SIMD3<Float>, cameraDown: SIMD3<Float>? = nil) {
        var away = Self.level(chest - camera)
        let height = abs(camera.y - chest.y)
        // Steeper than about 70 degrees down, the camera's position says little about which side is which.
        if simd_length(away) < max(0.05, 0.35 * height), let down = cameraDown.map(Self.level), simd_length(down) > 0.1 {
            away = down
        }
        guard simd_length(away) > 0.05 else { return nil }
        let awayUnit = simd_normalize(away)
        var headward = shoulders.map { Self.level($0 - chest) } ?? .zero
        // Shoulders too close to the chest to say which way the body lies: lie it across the view.
        if simd_length(headward) < 0.03 { headward = simd_cross(Self.up, awayUnit) }
        headward = simd_normalize(headward)
        let side = Self.level(awayUnit - simd_dot(awayUnit, headward) * headward)
        guard simd_length(side) > 1e-3 else { return nil }
        self.chest = chest
        self.headward = headward
        self.side = simd_normalize(side)
        if let shoulders, let hips {
            let torso = simd_distance(shoulders, hips) / Self.modelTorso
            bodyScale = min(Self.bodyScales.upperBound, max(Self.bodyScales.lowerBound, torso))
        }
    }

    /// A practice patient placed on the floor: lying across the view, chest at manikin height.
    init?(floor: SIMD3<Float>, camera: SIMD3<Float>, cameraDown: SIMD3<Float>? = nil) {
        self.init(chest: floor + Self.up * GhostRescuer.chestHeight, shoulders: nil, camera: camera, cameraDown: cameraDown)
    }

    private static func level(_ v: SIMD3<Float>) -> SIMD3<Float> { [v.x, 0, v.z] }
}

enum GhostRescuer {
    /// AHA 2025 asks for at least 5 cm. Drawn at 5, since the ghost shows the rhythm, not a depth to beat.
    static let depth: Float = 0.05
    /// A manikin's chest above the floor it lies on. A coarse figure, only for where the knees go.
    static let chestHeight: Float = 0.2
    /// The metronome's, so the ghost presses on the click.
    static let beatInterval = 60.0 / 110

    /// The share of each beat spent pressing down into the click, and coming back up after it. What's
    /// left, around the half beat, is a moment at the top with the chest fully recoiled.
    static let pressShare = 0.28
    static let recoilShare = 0.42
    /// How far the upper body tips forward over the hands at the bottom of a push.
    static let lean: Float = 5 * .pi / 180

    /// The push from the beat: deepest on the click, back up by the half beat, as the click says. A
    /// quick drive down, a slower release, and a beat at the top, rather than an even bob.
    static func push(sinceBeatStart elapsed: TimeInterval, beatInterval: TimeInterval) -> Double {
        guard elapsed >= 0, beatInterval > 0 else { return 0 }
        let phase = (elapsed / beatInterval).truncatingRemainder(dividingBy: 1)
        if phase < recoilShare { return 1 - smoothstep(phase / recoilShare) }
        if phase < 1 - pressShare { return 0 }
        return smoothstep((phase - (1 - pressShare)) / pressShare)
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// Model space, the upper body at rest to the upper body at `push`: tipped forward from the hips
    /// with the arms locked, so the shoulders come over the hands, and the hands driven straight down
    /// `depth` into the chest. The hands are the model's origin, so tipping about them and then
    /// dropping keeps them from sliding across the chest.
    static func upperBody(push: Double) -> simd_float4x4 {
        let pressed = Float(min(1, max(0, push)))
        // +z is toward the rescuer, so a turn about +x the negative way brings the shoulders over the patient.
        var pose = simd_float4x4(simd_quatf(angle: -lean * pressed, axis: [1, 0, 0]))
        pose.columns.3 = SIMD4(0, -depth * pressed, 0, 1)
        return pose
    }

    /// An adult kneeling with locked arms, shoulders straight over the hands, hinging at the hips.
    /// `push` runs from 0, up, to 1, pressed.
    static func joints(_ anchor: GhostAnchor, push: Double) -> [GhostJoint: SIMD3<Float>] {
        let up = GhostAnchor.up
        let side = anchor.side
        let head = anchor.headward
        let floor = anchor.chest - up * chestHeight
        let pressed = Float(min(1, max(0, push)))

        let hands = anchor.chest + up * (0.01 - depth * pressed)
        // Locked arms, so the shoulders ride down with the hands.
        let shoulderMid = hands + up * 0.58 + side * 0.03
        let leftShoulder = shoulderMid + head * 0.19
        let rightShoulder = shoulderMid - head * 0.19
        let neck = shoulderMid + up * 0.06 + side * 0.02
        // Looking down at the hands.
        let headPoint = neck + up * 0.13 - side * 0.05
        // The floor point is straight below the chest, so these are offsets from the patient's side.
        let pelvis = floor + side * 0.45 + up * 0.48
        let knee = floor + side * 0.32 + up * 0.05
        let foot = floor + side * 0.75 + up * 0.04

        return [
            .head: headPoint,
            .neck: neck,
            .leftShoulder: leftShoulder,
            .rightShoulder: rightShoulder,
            .leftElbow: (leftShoulder + hands + head * 0.04) / 2,
            .rightElbow: (rightShoulder + hands - head * 0.04) / 2,
            .hands: hands,
            .pelvis: pelvis,
            .leftKnee: knee + head * 0.14,
            .rightKnee: knee - head * 0.14,
            .leftFoot: foot + head * 0.14,
            .rightFoot: foot - head * 0.14,
        ]
    }
}

/// An imaginary adult lying face up, for practice with no one on the floor. Drawn under the ghost
/// rescuer from the same anchor, so the ghost's hands land on its chest.
enum PracticePatient {
    enum Joint: Hashable, CaseIterable {
        case head, neck
        case leftShoulder, rightShoulder, leftHand, rightHand
        case pelvis, leftHip, rightHip, leftKnee, rightKnee, leftFoot, rightFoot

        static let bones: [(Joint, Joint)] = [
            (.neck, .pelvis),
            (.leftShoulder, .rightShoulder),
            (.leftShoulder, .leftHand), (.rightShoulder, .rightHand),
            (.leftHip, .rightHip),
            (.leftHip, .leftKnee), (.leftKnee, .leftFoot),
            (.rightHip, .rightKnee), (.rightKnee, .rightFoot),
        ]
    }

    /// Body centre this far above the floor, a little under the chest.
    static let bodyHeight: Float = 0.1

    static func joints(_ anchor: GhostAnchor) -> [Joint: SIMD3<Float>] {
        let up = GhostAnchor.up
        let along = anchor.headward
        let across = anchor.side
        // The sternum is a little below the shoulders, so the body runs from there.
        let spine = anchor.chest - up * (GhostRescuer.chestHeight - bodyHeight)
        let shoulders = spine + along * 0.15
        let pelvis = spine - along * 0.38
        return [
            .head: shoulders + along * 0.27,
            .neck: shoulders + along * 0.08,
            .leftShoulder: shoulders + across * 0.2,
            .rightShoulder: shoulders - across * 0.2,
            .leftHand: pelvis + across * 0.27,
            .rightHand: pelvis - across * 0.27,
            .pelvis: pelvis,
            .leftHip: pelvis + across * 0.12,
            .rightHip: pelvis - across * 0.12,
            .leftKnee: pelvis - along * 0.45 + across * 0.13,
            .rightKnee: pelvis - along * 0.45 - across * 0.13,
            .leftFoot: pelvis - along * 0.9 + across * 0.14 - up * 0.04,
            .rightFoot: pelvis - along * 0.9 - across * 0.14 - up * 0.04,
        ]
    }
}
