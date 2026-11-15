import CoreGraphics
import Foundation
import RescueCore

/// A tapped injury in the world. Apart from the AED point, since a person places it, it moves on the
/// next tap, and it shows for a limited time.
struct PlacedPin: Sendable, Equatable {
    var world: SIMD3<Float>
    var placedAt: TimeInterval
}

public enum InjuryPinResult: Sendable, Equatable {
    case placed
    /// No surface, no good tracking, or no recent frame. No pin beats a wrong one.
    case notPlaced
    /// A later tap or a break in tracking took this one's place, so nothing about it is news.
    case superseded
}

/// A part of the body to act on, in normalized view coordinates, origin top-left.
public struct BodyZone: Sendable, Equatable {
    public enum Kind: Sendable, Hashable {
        /// Where the hands go, around the ring's center.
        case chest
        /// 1 under the patient's right collarbone, 2 on their left side below the armpit.
        case pad(Int)
        case limb(LimbSegment)
        /// Where to press on a tapped injury, sized to a palm at the pin's distance.
        case pressRing
        /// Between the shoulder blades of a standing patient, for back blows.
        case upperBack
        /// Just above the navel of a standing patient, for abdominal thrusts.
        case upperAbdomen
    }

    public enum Shape: Sendable, Equatable {
        /// Corners going round.
        case polygon([CGPoint])
        /// A rounded segment. `width` is the full width as a fraction of the view's width. A press
        /// ring has `a == b`, which makes it a disc.
        case capsule(a: CGPoint, b: CGPoint, width: Double)
    }

    public var kind: Kind
    public var shape: Shape
    /// View radians, 0 pointing right and positive turning clockwise, as `AEDArrow.angle`. Head to
    /// feet for the chest and pads, `a` to `b` along a limb.
    public var axis: Double
    /// Solid when locked. Dashed while estimating: a torso guessed from head and shoulders, joints
    /// seen only faintly, or Vision's left and right labels disagreeing with the body's geometry.
    public var isLocked: Bool

    public init(kind: Kind, shape: Shape, axis: Double, isLocked: Bool) {
        self.kind = kind
        self.shape = shape
        self.axis = axis
        self.isLocked = isLocked
    }

    /// The middle of the shape, in normalized view coordinates.
    public var center: CGPoint {
        switch shape {
        case let .polygon(points):
            guard !points.isEmpty else { return .zero }
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
        case let .capsule(a, b, _):
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }
}

/// A material in the room the step uses, as located on a frozen frame.
public struct ItemCallout: Sendable, Equatable {
    public var material: Material
    /// Normalized view coordinates, on the same terms as `AEDArrow.position`.
    public var position: CGPoint
    /// Around the item in normalized view coordinates. On screen only, and nil when its corners
    /// couldn't be placed.
    public var box: CGRect?
    public var isOnScreen: Bool
    /// Radians from the view's center toward the item, on the same terms as `AEDArrow.angle`.
    public var angle: Double
    /// Metres from the camera. Coarse.
    public var distance: Double

    public init(material: Material, position: CGPoint, box: CGRect?, isOnScreen: Bool, angle: Double, distance: Double) {
        self.material = material
        self.position = position
        self.box = box
        self.isOnScreen = isOnScreen
        self.angle = angle
        self.distance = distance
    }
}

/// What a 2D overlay draws this frame. Everything is optional, and empty is always valid.
public struct VisionOverlay: Sendable, Equatable {
    public struct Ring: Sendable, Equatable {
        /// Normalized view coordinates, origin top-left.
        public var center: CGPoint
        /// Fraction of the view's width.
        public var radius: Double

        public init(center: CGPoint, radius: Double) {
            self.center = center
            self.radius = radius
        }
    }

    public struct AEDArrow: Sendable, Equatable {
        static let edgeInset = 0.08

        /// Normalized view coordinates. The AED itself when on screen, otherwise a point just
        /// inside the view's edge in the AED's direction.
        public var position: CGPoint
        public var isOnScreen: Bool
        /// Radians from the view's center toward the AED. 0 points right, and positive turns
        /// clockwise on screen, matching SwiftUI's `rotationEffect`.
        public var angle: Double
        /// Metres from the camera. Coarse.
        public var distance: Double

        public init(position: CGPoint, isOnScreen: Bool, angle: Double, distance: Double) {
            self.position = position
            self.isOnScreen = isOnScreen
            self.angle = angle
            self.distance = distance
        }
    }

    public struct InjuryPin: Sendable, Equatable {
        /// Normalized view coordinates, on the same terms as `AEDArrow.position`.
        public var position: CGPoint
        public var isOnScreen: Bool
        /// Radians from the view's center toward the pin, on the same terms as `AEDArrow.angle`.
        public var angle: Double

        public init(position: CGPoint, isOnScreen: Bool, angle: Double) {
            self.position = position
            self.isOnScreen = isOnScreen
            self.angle = angle
        }
    }

    /// A see-through body drawn from world joints: limbs as segments and a head as a disc.
    public struct Figure: Sendable, Equatable {
        public struct Segment: Sendable, Equatable {
            public var from: CGPoint
            public var to: CGPoint

            public init(from: CGPoint, to: CGPoint) {
                self.from = from
                self.to = to
            }
        }

        /// Normalized view coordinates.
        public var segments: [Segment]
        public var head: CGPoint
        /// The pressed hands, for the rescuer. Nil on the patient.
        public var hands: CGPoint?

        public init(segments: [Segment], head: CGPoint, hands: CGPoint? = nil) {
            self.segments = segments
            self.head = head
            self.hands = hands
        }
    }

    /// The see-through rescuer to follow in compressions, and the practice patient under it when
    /// one was placed on the floor instead of found by pose.
    public struct Ghost: Sendable, Equatable {
        public var rescuer: Figure
        public var patient: Figure?
        /// 0 up to 1 pressed, on the metronome's beat.
        public var push: Double
        /// View points per metre at the chest, for limb widths that shrink with distance.
        public var pointsPerMetre: Double

        public init(rescuer: Figure, patient: Figure? = nil, push: Double, pointsPerMetre: Double) {
            self.rescuer = rescuer
            self.patient = patient
            self.push = push
            self.pointsPerMetre = pointsPerMetre
        }
    }

    /// A camera-aligned body outline, not a depth measurement or a clinical assessment.
    public struct DetectedBody: Sendable, Equatable {
        public var joints: [BodyJoint: CGPoint]

        public init(joints: [BodyJoint: CGPoint]) {
            self.joints = joints.filter { BodyJoint.cprJoints.contains($0.key) }
        }

        /// Only connect endpoints measured on this person. Missing joints leave gaps.
        public var segments: [Figure.Segment] {
            let edges: [(BodyJoint, BodyJoint)] = [
                (.leftShoulder, .rightShoulder),
                (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
                (.leftHip, .rightHip),
                (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
                (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
                (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
                (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
                (.neck, .nose),
            ]
            return edges.compactMap { a, b in
                guard let from = joints[a], let to = joints[b] else { return nil }
                return Figure.Segment(from: from, to: to)
            }
        }
    }

    public var bodies: [DetectedBody] = []
    /// The patient pose found lying down, drawn see-through under the step's mark, so the helper sees
    /// the phone has the right person and the marks sit on them. Where things are, never what to do.
    public struct Outline: Sendable, Equatable {
        public struct Limb: Sendable, Equatable {
            public var from: CGPoint
            public var to: CGPoint
            /// Full width, as a fraction of the view's width.
            public var width: Double
            public var isLocked: Bool

            public init(from: CGPoint, to: CGPoint, width: Double, isLocked: Bool) {
                self.from = from
                self.to = to
                self.width = width
                self.isLocked = isLocked
            }
        }

        public struct Head: Sendable, Equatable {
            public var center: CGPoint
            /// A fraction of the view's width.
            public var radius: Double
            public var isLocked: Bool

            public init(center: CGPoint, radius: Double, isLocked: Bool) {
                self.center = center
                self.radius = radius
                self.isLocked = isLocked
            }
        }

        /// Shoulders then hips, going round. Normalized view coordinates, like every point here.
        public var torso: [CGPoint]
        public var torsoLocked: Bool
        public var head: Head?
        public var limbs: [Limb]

        public init(torso: [CGPoint], torsoLocked: Bool, head: Head? = nil, limbs: [Limb] = []) {
            self.torso = torso
            self.torsoLocked = torsoLocked
            self.head = head
            self.limbs = limbs
        }
    }

    /// Detected CPR joints in normalized view coordinates, origin top-left.
    public var joints: [CGPoint] = []
    public var ring: Ring?
    public var outline: Outline?
    public var aedArrow: AEDArrow?
    public var ghost: Ghost?
    /// The AR view draws realistic hands on the chest, so the flat ghost hands stay off.
    public var handsIn3D = false
    /// A fresh, depth-fitted Blender template replaces the flat patient outlines.
    public var patientIn3D = false
    public var chestEstimateLabel: String?
    /// Palm-sized uncertainty region, never a claim to have identified a bone.
    public var sternumEstimate: Ring?
    /// Guides the rescuer's hand onto the sternum region while hands are being placed.
    public var handGuide: HandGuide?
    public var injuryPin: InjuryPin?
    /// The camera is live and nothing is placed, and nothing else would say a tap does anything.
    public var showsInjuryHint: Bool
    /// Body parts to act on, in a fixed order: chest, pads 1 then 2, limb, press ring.
    public var zones: [BodyZone]
    /// Materials the step uses, in `Material.allCases` order. Never the AED, which has `aedArrow`.
    public var items: [ItemCallout]

    public init(
        ring: Ring? = nil,
        aedArrow: AEDArrow? = nil,
        injuryPin: InjuryPin? = nil,
        showsInjuryHint: Bool = false,
        zones: [BodyZone] = [],
        items: [ItemCallout] = [],
        ghost: Ghost? = nil,
        outline: Outline? = nil
    ) {
        self.ghost = ghost
        self.outline = outline
        self.ring = ring
        self.aedArrow = aedArrow
        self.injuryPin = injuryPin
        self.showsInjuryHint = showsInjuryHint
        self.zones = zones
        self.items = items
    }

    public static let empty = VisionOverlay()

    public struct HandGuide: Sendable, Equatable {
        /// Where the hand should go, in normalized view coordinates.
        public var target: Ring
        /// The heel of the rescuer's hand, normalized view coordinates, when one is seen.
        public var hand: CGPoint?
        /// Nil until a hand is seen.
        public var guidance: HandGuidance?

        public init(target: Ring, hand: CGPoint? = nil, guidance: HandGuidance? = nil) {
            self.target = target
            self.hand = hand
            self.guidance = guidance
        }

        public var text: String { guidance?.text ?? HandGuidance.noHandText }
        public var onTarget: Bool { guidance?.move == .onTarget }
    }

    /// The guide keeps the ring this long after the patient was last seen, because the rescuer's
    /// hands hide the chest as they reach it.
    static let handGuideHold: TimeInterval = 2
    /// A hand is only followed while it is this fresh.
    static let maxHandAge: TimeInterval = 0.5

    /// With no camera frame this recent, nothing on screen can be trusted to line up.
    static let maxCameraAge: TimeInterval = 0.5
    /// The pin doesn't follow a limb that moves, so it doesn't stay up for long on trust.
    static let pinSeconds: TimeInterval = 20
    /// Pads and limbs run at a capped pose rate, so they get a little longer than the ring's 0.2 s.
    static let maxZoneAge: TimeInterval = 0.35
    /// Allow on-device inference latency without holding old dots indefinitely.
    static let maxJointAge: TimeInterval = 0.75

    /// - Parameters:
    ///   - pose: Body regions from the latest pose frame. The chest zone shows only with the ring,
    ///     from the same frame.
    ///   - items: Materials to point at: wanted by the step and seen often enough.
    ///   - handsGuide: The coordinator's window at the start of compressions, which has no overlay
    ///     of its own.
    static func compose(
        target: OverlayTarget?,
        ring: RingController.Output,
        camera: FrameRecord?,
        mapping: DisplayMapping?,
        aedPoint: SIMD3<Float>?,
        carriedAED: SIMD3<Float>? = nil,
        injuryPin: PlacedPin? = nil,
        pose: TimedPose? = nil,
        jointPose: TimedPose? = nil,
        posing: Bool = true,
        items: [Material: PlacedObject] = [:],
        handsGuide: Bool = false,
        ghost: (anchor: GhostAnchor, push: Double, practice: Bool)? = nil,
        now: TimeInterval
    ) -> VisionOverlay {
        guard let camera, let mapping, now - camera.timestamp <= maxCameraAge else { return .empty }
        let regions = pose?.regions
        let zoneFresh = pose.map { (0...maxZoneAge).contains($0.age(at: now)) } ?? false
        // The same gate as the ring's, so the hands and their axis come and go together.
        let chestFresh = pose.map { (0...RingController.maxKeypointAge).contains($0.age(at: now)) } ?? false
        let chest = chestFresh ? regions : nil

        var overlay: VisionOverlay
        switch target {
        case .chestCenter:
            overlay = hands(ring: ring, regions: chest, mapping: mapping)
        case .aedDevice:
            guard let aedPoint, camera.tracking == .normal else { overlay = .empty; break }
            overlay = VisionOverlay(aedArrow: mapping.arrow(to: aedPoint, camera: camera.pose))
        case .injurySite:
            if let injuryPin, now - injuryPin.placedAt < pinSeconds {
                if camera.tracking == .normal {
                    overlay = VisionOverlay(injuryPin: mapping.pin(at: injuryPin.world, camera: camera.pose))
                    if let press = mapping.pressRing(at: injuryPin.world, camera: camera.pose) {
                        overlay.zones.append(press)
                    }
                } else {
                    overlay = .empty
                }
            } else {
                overlay = VisionOverlay(showsInjuryHint: true)
            }
            // From the image alone, so it doesn't wait on world tracking, and it is drawn first.
            if zoneFresh, let limb = regions?.limb {
                overlay.zones.insert(mapping.zone(limb), at: 0)
            }
        case nil:
            if handsGuide {
                // The guide is the step's one mark while it lasts. The carried AED's arrow waits.
                overlay = hands(ring: ring, regions: chest, mapping: mapping)
            } else if let carriedAED, camera.tracking == .normal {
                overlay = VisionOverlay(aedArrow: mapping.arrow(to: carriedAED, camera: camera.pose))
            } else {
                overlay = .empty
            }
        case .upperBack, .upperAbdomen:
            overlay = .empty
            if zoneFresh, let regions {
                let isBack = target == .upperBack
                if let rect = isBack ? regions.upperBack : regions.upperAbdomen {
                    overlay.zones = [mapping.zone(rect, kind: isBack ? .upperBack : .upperAbdomen, isLocked: regions.uprightLocked)]
                }
                if let outline = regions.outline { overlay.outline = mapping.outline(outline) }
            }
        case .padZones:
            overlay = .empty
            if zoneFresh, let regions, let one = regions.padOne, let two = regions.padTwo {
                overlay.zones = [
                    mapping.zone(one, kind: .pad(1), isLocked: regions.padsLocked),
                    mapping.zone(two, kind: .pad(2), isLocked: regions.padsLocked),
                ]
            }
        }

        // Only on a step with no target of its own, which is compressions, beside whatever else it draws.
        if target == nil, camera.tracking == .normal, let ghost {
            overlay.ghost = mapping.ghost(ghost.anchor, push: ghost.push, practice: ghost.practice, camera: camera.pose)
        }

        // The patient under the step's mark, on the steps that look for someone lying down. From the
        // same frame and the same freshness gate as that mark, so the two never disagree.
        let looksForLying = target == .chestCenter || target == .padZones || (target == nil && handsGuide)
        if looksForLying, overlay.ghost == nil, let outline = (target == .padZones ? (zoneFresh ? regions : nil) : chest)?.outline {
            overlay.outline = mapping.outline(outline)
        }

        // Only while the step has pose running: a frame left over from a step that stopped looking, as
        // the hands guide ending, mustn't hang a body on screen after the camera's done with it.
        let detectedJoints = posing ? (jointPose ?? pose) : nil
        if let detectedJoints, (0...maxJointAge).contains(detectedJoints.age(at: now)) {
            overlay.bodies = detectedJoints.skeletons.map { skeleton in
                DetectedBody(joints: skeleton.joints.mapValues { mapping.viewPoint(fromImage: $0) })
            }
            if overlay.bodies.isEmpty {
                overlay.joints = detectedJoints.joints.map { mapping.viewPoint(fromImage: $0) }
            } else {
                overlay.joints = overlay.bodies.flatMap { body in BodyJoint.cprJoints.compactMap { body.joints[$0] } }
            }
        }

        // World points, so only with tracking that holds the world steady.
        if camera.tracking == .normal {
            overlay.items = Material.allCases.compactMap { material in
                guard !material.isFixed, let placed = items[material] else { return nil }
                return mapping.item(material, placed: placed, camera: camera.pose)
            }
        }
        return overlay
    }

    private static func hands(ring: RingController.Output, regions: BodyRegions?, mapping: DisplayMapping) -> VisionOverlay {
        guard case let .show(chest) = ring else { return .empty }
        var overlay = VisionOverlay(ring: mapping.ring(for: chest))
        if let zone = regions?.chest {
            overlay.zones = [mapping.zone(zone, kind: .chest, isLocked: regions?.chestLocked ?? false)]
        }
        return overlay
    }
}
