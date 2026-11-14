import CoreGraphics
import Foundation
import ImageIO
import RescueCore
import simd

/// How the native camera buffer is rotated for analysis or display.
enum CaptureRotation: Sendable, CaseIterable {
    case up, right, down, left

    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }

    /// From the rotated image (normalized, origin top-left) back to capture image space.
    func captureNormalized(fromDisplay point: SIMD2<Double>) -> SIMD2<Double> {
        switch self {
        case .up: point
        case .down: [1 - point.x, 1 - point.y]
        case .right: [point.y, 1 - point.x]
        case .left: [1 - point.y, point.x]
        }
    }

    /// Vision reports points in the rotated image with a lower-left origin.
    func captureNormalized(fromVision point: SIMD2<Double>) -> SIMD2<Double> {
        captureNormalized(fromDisplay: [point.x, 1 - point.y])
    }
}

struct WorldRay: Sendable, Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    func hittingHorizontalPlane(y: Float, maxDistance: Float = 30) -> SIMD3<Float>? {
        guard abs(direction.y) > 1e-4 else { return nil }
        let distance = (y - origin.y) / direction.y
        guard distance > 0, distance <= maxDistance else { return nil }
        return origin + direction * distance
    }
}

enum CameraProjection: Sendable, Equatable {
    /// Capture image space. Can fall outside 0...1 when the point is out of frame.
    case inFront(SIMD2<Double>)
    /// Behind the camera a projection flips, so this gives only which way to turn, in image
    /// axes with equal scale on both.
    case behind(SIMD2<Double>)
}

/// A camera at one moment, copied out of an `ARFrame`. Camera axes follow ARKit: x along the
/// image's +x, y along the image's -y, and z pointing back toward the viewer.
struct CameraPose: Sendable, Equatable {
    /// Camera to world.
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    /// Pixels, width then height.
    var imageResolution: SIMD2<Double>

    var imageAspect: Double { imageResolution.x / imageResolution.y }

    var position: SIMD3<Float> { transform.columns.3.xyz }

    /// The bottom of the portrait screen, in the world: capture image +x runs down the view.
    var screenDown: SIMD3<Float> { transform.columns.0.xyz }

    /// World down in capture image axes. Assumes gravity world alignment, where -y is down.
    var gravityInImage: SIMD2<Double> {
        [Double(-transform.columns.0.y), Double(transform.columns.1.y)]
    }

    func ray(throughImagePoint point: SIMD2<Double>) -> WorldRay {
        let u = Float(point.x * imageResolution.x)
        let v = Float(point.y * imageResolution.y)
        let camera = SIMD3<Float>(
            (u - intrinsics.columns.2.x) / intrinsics.columns.0.x,
            -(v - intrinsics.columns.2.y) / intrinsics.columns.1.y,
            -1
        )
        let world = (transform * SIMD4(camera, 0)).xyz
        return WorldRay(origin: position, direction: simd_normalize(world))
    }

    func project(_ world: SIMD3<Float>) -> CameraProjection {
        let camera = (transform.inverse * SIMD4(world, 1)).xyz
        guard camera.z < -0.01 else { return .behind([Double(camera.x), Double(-camera.y)]) }
        let u = intrinsics.columns.0.x * camera.x / -camera.z + intrinsics.columns.2.x
        let v = intrinsics.columns.1.y * -camera.y / -camera.z + intrinsics.columns.2.y
        return .inFront([Double(u) / imageResolution.x, Double(v) / imageResolution.y])
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

/// The current frame's `displayTransform`, so a 2D overlay can draw on the camera image.
public struct DisplayMapping: Sendable, Equatable {
    /// Capture image space to normalized view coordinates, origin top-left.
    public var imageToView: CGAffineTransform
    public var viewSize: CGSize
    /// Width over height of the camera buffer.
    public var imageAspect: Double

    public init(imageToView: CGAffineTransform, viewSize: CGSize, imageAspect: Double) {
        self.imageToView = imageToView
        self.viewSize = viewSize
        self.imageAspect = imageAspect
    }

    /// Normalized view coordinates.
    public func viewPoint(fromImage point: SIMD2<Double>) -> CGPoint {
        CGPoint(x: point.x, y: point.y).applying(imageToView)
    }

    /// View points.
    public func screenPoint(fromImage point: SIMD2<Double>) -> CGPoint {
        let view = viewPoint(fromImage: point)
        return CGPoint(x: view.x * viewSize.width, y: view.y * viewSize.height)
    }

    /// Capture image space, from view points. Nil if the transform can't be inverted, which
    /// `inverted()` wouldn't say: it hands back the original.
    func imagePoint(fromScreen point: CGPoint) -> SIMD2<Double>? {
        let determinant = imageToView.a * imageToView.d - imageToView.b * imageToView.c
        guard determinant != 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let view = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        let image = view.applying(imageToView.inverted())
        return [image.x, image.y]
    }

    /// A vector measured in image heights, in view points. The display transform is
    /// anisotropic in normalized space, so distances have to go through this.
    func viewVector(fromImageHeights vector: SIMD2<Double>) -> SIMD2<Double> {
        let x = vector.x / imageAspect
        let y = vector.y
        return [
            (x * imageToView.a + y * imageToView.c) * viewSize.width,
            (x * imageToView.b + y * imageToView.d) * viewSize.height,
        ]
    }

    func ring(for target: TorsoTarget) -> VisionOverlay.Ring {
        let radius = simd_length(viewVector(fromImageHeights: [target.radius, 0]))
        return VisionOverlay.Ring(center: viewPoint(fromImage: target.center), radius: radius / viewSize.width)
    }

    /// Every joint in front of the camera, or no ghost: half a body drawn from a flipped
    /// projection would point the wrong way.
    func ghost(_ anchor: GhostAnchor, push: Double, practice: Bool, camera: CameraPose) -> VisionOverlay.Ghost? {
        guard let rescuer = figure(GhostRescuer.joints(anchor, push: push), bones: GhostJoint.bones, head: .head, hands: .hands, camera: camera)
        else { return nil }
        var patient: VisionOverlay.Figure?
        if practice {
            guard let body = figure(PracticePatient.joints(anchor), bones: PracticePatient.Joint.bones, head: .head, hands: nil, camera: camera)
            else { return nil }
            patient = body
        }
        // Measured along the body at the chest, over a span short enough to stay in front of the camera.
        let span: Float = 0.3
        guard case let .inFront(a) = camera.project(anchor.chest),
              case let .inFront(b) = camera.project(anchor.chest + anchor.headward * span) else { return nil }
        let points = simd_length(viewVector(fromImageHeights: [(b.x - a.x) * imageAspect, b.y - a.y]))
        return VisionOverlay.Ghost(rescuer: rescuer, patient: patient, push: push, pointsPerMetre: points / Double(span))
    }

    private func figure<J: Hashable>(
        _ joints: [J: SIMD3<Float>],
        bones: [(J, J)],
        head: J,
        hands: J?,
        camera: CameraPose
    ) -> VisionOverlay.Figure? {
        var view: [J: CGPoint] = [:]
        for (joint, world) in joints {
            guard case let .inFront(image) = camera.project(world) else { return nil }
            view[joint] = viewPoint(fromImage: image)
        }
        guard let headPoint = view[head] else { return nil }
        let segments = bones.compactMap { a, b in
            view[a].flatMap { from in view[b].map { VisionOverlay.Figure.Segment(from: from, to: $0) } }
        }
        return VisionOverlay.Figure(segments: segments, head: headPoint, hands: hands.flatMap { view[$0] })
    }

    func arrow(to world: SIMD3<Float>, camera: CameraPose) -> VisionOverlay.AEDArrow {
        let distance = Double(simd_distance(world, camera.position))
        var direction: SIMD2<Double>
        switch camera.project(world) {
        case let .inFront(image):
            let view = viewPoint(fromImage: image)
            direction = [(view.x - 0.5) * viewSize.width, (view.y - 0.5) * viewSize.height]
            if (0...1).contains(view.x), (0...1).contains(view.y) {
                return VisionOverlay.AEDArrow(
                    position: view,
                    isOnScreen: true,
                    angle: atan2(direction.y, direction.x),
                    distance: distance
                )
            }
        case let .behind(turn):
            direction = viewVector(fromImageHeights: turn)
            // Directly behind has no left or right, so point down the screen.
            if simd_length(direction) < 1e-6 { direction = [0, 1] }
        }

        // Keep the arrowhead a little inside the edge so it isn't clipped.
        let halfWidth = viewSize.width * (0.5 - VisionOverlay.AEDArrow.edgeInset)
        let halfHeight = viewSize.height * (0.5 - VisionOverlay.AEDArrow.edgeInset)
        let scale = min(
            direction.x == 0 ? .infinity : halfWidth / abs(direction.x),
            direction.y == 0 ? .infinity : halfHeight / abs(direction.y)
        )
        return VisionOverlay.AEDArrow(
            position: CGPoint(
                x: 0.5 + direction.x * scale / viewSize.width,
                y: 0.5 + direction.y * scale / viewSize.height
            ),
            isOnScreen: false,
            angle: atan2(direction.y, direction.x),
            distance: distance
        )
    }

    func pin(at world: SIMD3<Float>, camera: CameraPose) -> VisionOverlay.InjuryPin {
        let mark = arrow(to: world, camera: camera)
        return VisionOverlay.InjuryPin(position: mark.position, isOnScreen: mark.isOnScreen, angle: mark.angle)
    }

    /// View radians of a direction measured in image heights.
    func viewAngle(ofImageHeights vector: SIMD2<Double>) -> Double {
        let view = viewVector(fromImageHeights: vector)
        return atan2(view.y, view.x)
    }

    func zone(_ rect: OrientedRect, kind: BodyZone.Kind, isLocked: Bool) -> BodyZone {
        BodyZone(
            kind: kind,
            shape: .polygon(rect.corners(imageAspect: imageAspect).map(viewPoint(fromImage:))),
            axis: viewAngle(ofImageHeights: rect.axis),
            isLocked: isLocked
        )
    }

    func zone(_ capsule: LimbCapsule) -> BodyZone {
        let a = viewPoint(fromImage: capsule.from)
        let b = viewPoint(fromImage: capsule.to)
        let width = simd_length(viewVector(fromImageHeights: [capsule.radius * 2, 0])) / viewSize.width
        return BodyZone(
            kind: .limb(capsule.segment),
            shape: .capsule(a: a, b: b, width: width),
            axis: atan2((b.y - a.y) * viewSize.height, (b.x - a.x) * viewSize.width),
            isLocked: capsule.isLocked
        )
    }

    func outline(_ outline: BodyOutline) -> VisionOverlay.Outline {
        let widthFraction = { (imageHeights: Double) in
            simd_length(viewVector(fromImageHeights: [imageHeights, 0])) / viewSize.width
        }
        return VisionOverlay.Outline(
            torso: outline.torso.map(viewPoint(fromImage:)),
            torsoLocked: outline.torsoLocked,
            head: outline.head.map {
                VisionOverlay.Outline.Head(center: viewPoint(fromImage: $0.center), radius: widthFraction($0.radius), isLocked: $0.isLocked)
            },
            limbs: outline.limbs.map {
                VisionOverlay.Outline.Limb(
                    from: viewPoint(fromImage: $0.from), to: viewPoint(fromImage: $0.to), width: widthFraction($0.radius * 2), isLocked: $0.isLocked
                )
            }
        )
    }

    /// About a palm across, wherever the pin is.
    static let pressRingRadius: Float = 0.05

    /// Nil unless the pin is on screen. Off screen, the pin's own arrow says which way to turn.
    func pressRing(at world: SIMD3<Float>, camera: CameraPose) -> BodyZone? {
        guard case let .inFront(image) = camera.project(world) else { return nil }
        let center = viewPoint(fromImage: image)
        guard (0...1).contains(center.x), (0...1).contains(center.y) else { return nil }
        // A point a palm's radius to the side, square to the camera, gives the ring's size there.
        let side = simd_normalize(camera.transform.columns.0.xyz) * Self.pressRingRadius
        guard case let .inFront(edge) = camera.project(world + side) else { return nil }
        let rim = screenPoint(fromImage: edge)
        let middle = screenPoint(fromImage: image)
        let radius = hypot(rim.x - middle.x, rim.y - middle.y)
        return BodyZone(
            kind: .pressRing,
            shape: .capsule(a: center, b: center, width: 2 * radius / viewSize.width),
            axis: 0,
            isLocked: true
        )
    }

    func item(_ material: Material, placed: PlacedObject, camera: CameraPose) -> ItemCallout {
        let mark = arrow(to: placed.world, camera: camera)
        var box: CGRect?
        if mark.isOnScreen, let corners = placed.corners {
            let points = corners.compactMap { corner -> CGPoint? in
                guard case let .inFront(image) = camera.project(corner) else { return nil }
                return viewPoint(fromImage: image)
            }
            if points.count == corners.count, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
               let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
                box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
        }
        return ItemCallout(
            material: material,
            position: mark.position,
            box: box,
            isOnScreen: mark.isOnScreen,
            angle: mark.angle,
            distance: mark.distance
        )
    }
}
