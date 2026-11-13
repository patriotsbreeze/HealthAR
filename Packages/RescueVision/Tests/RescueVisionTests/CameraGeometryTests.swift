import CoreGraphics
import Testing
import simd
@testable import RescueVision

// MARK: - Gravity

@Test func gravityFollowsTheCamera() {
    #expect(cameraPose().gravityInImage == [0, 1], "level in landscape: down the image")
    #expect(cameraPose(portraitLevel).gravityInImage == [1, 0], "level in portrait: along capture +x")
    #expect(simd_length(cameraPose(lookingStraightDown).gravityInImage) < 1e-6)
}

// MARK: - Rays and projection

@Test func imageCenterRayLooksAlongTheCamera() {
    let ray = cameraPose().ray(throughImagePoint: [0.5, 0.5])
    #expect(isClose(ray.origin, .zero))
    #expect(isClose(ray.direction, [0, 0, -1]))
}

@Test func projectionHasTheRightHandedness() {
    let pose = cameraPose()
    let right = SIMD2<Double>(1460.0 / 1920, 0.5)
    let up = SIMD2<Double>(0.5, 220.0 / 1440)
    #expect(pose.project([1, 0, -2]) == .inFront(right), "world right is image right")
    #expect(pose.project([0, 1, -2]) == .inFront(up), "world up is image up")
}

@Test(arguments: [
    SIMD2<Double>(0.5, 0.5), [0.1, 0.9], [0.8, 0.2], [0.95, 0.95],
])
func rayAndProjectionAreInverses(point: SIMD2<Double>) {
    let pose = cameraPose(transform(rotationY: 35, position: [1, 1.4, -2]))
    let ray = pose.ray(throughImagePoint: point)
    guard case let .inFront(back) = pose.project(ray.origin + ray.direction * 3) else {
        Issue.record("expected in front")
        return
    }
    #expect(isClose(back, point, 1e-4))
}

@Test func pointsBehindTheCameraGiveATurnDirection() {
    let pose = cameraPose()
    #expect(pose.project([2, 0, 3]) == .behind([2, 0]))
    #expect(pose.project([0, 2, 3]) == .behind([0, -2]))
    #expect(pose.project([0, 0, 0]) == .behind([0, 0]))
}

@Test func rayHitsAHorizontalPlaneOnlyAhead() throws {
    let down = WorldRay(origin: [0, 1.5, 0], direction: simd_normalize(SIMD3<Float>(1, -1, 0)))
    let hit = try #require(down.hittingHorizontalPlane(y: 0))
    #expect(isClose(hit, [1.5, 0, 0]))

    #expect(WorldRay(origin: [0, 1.5, 0], direction: [0, 1, 0]).hittingHorizontalPlane(y: 0) == nil, "plane behind")
    #expect(WorldRay(origin: [0, 1.5, 0], direction: [1, 0, 0]).hittingHorizontalPlane(y: 0) == nil, "parallel")
    let shallow = WorldRay(origin: [0, 1.5, 0], direction: simd_normalize(SIMD3<Float>(100, -1, 0)))
    #expect(shallow.hittingHorizontalPlane(y: 0) == nil, "too far to trust")
}

// MARK: - Rotation

@Test(arguments: CaptureRotation.allCases)
func rotationKeepsTheImageSquareAndCorners(rotation: CaptureRotation) {
    var corners: Set<[Double]> = []
    for corner in [SIMD2<Double>(0, 0), [1, 0], [0, 1], [1, 1]] {
        let mapped = rotation.captureNormalized(fromDisplay: corner)
        corners.insert([mapped.x, mapped.y])
    }
    #expect(corners.count == 4)
    #expect(isClose(rotation.captureNormalized(fromDisplay: [0.5, 0.5]), [0.5, 0.5]))
}

@Test func visionPointsFlipTheirOrigin() {
    #expect(CaptureRotation.up.captureNormalized(fromVision: [0.2, 0.9]) == [0.2, 1 - 0.9])
}

@Test func portraitRotationAgreesWithARKitsPortraitTransform() {
    // ARKit's portrait displayTransform with no crop is x' = 1 - y, y' = x.
    let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
    for image in [SIMD2<Double>(0.2, 0.7), [0.9, 0.1], [0.5, 0.25]] {
        let view = CGPoint(x: image.x, y: image.y).applying(transform)
        #expect(isClose(CaptureRotation.right.captureNormalized(fromDisplay: [view.x, view.y]), image))
    }
}

// MARK: - Display mapping

@Test func imageCenterMapsToViewCenter() {
    let point = portraitMapping.viewPoint(fromImage: [0.5, 0.5])
    #expect(isClose(point.x, 0.5))
    #expect(isClose(point.y, 0.5))
    let screen = portraitMapping.screenPoint(fromImage: [0.5, 0.5])
    #expect(isClose(screen.x, 393.0 / 2))
    #expect(isClose(screen.y, 852.0 / 2))
}

@Test func ringRadiusUsesTheAspectFillScale() {
    // Aspect-fill scale is 852 / 1920 points per pixel. 0.1 image heights is 144 pixels.
    let ring = portraitMapping.ring(for: TorsoTarget(center: [0.5, 0.5], radius: 0.1))
    #expect(isClose(ring.radius, 144 * (852.0 / 1920) / 393, 1e-6))
}

@Test func ringRadiusIsCircularWhicheverWayTheImageTurns() {
    let mapping = portraitMapping
    let radiusFromX = mapping.ring(for: TorsoTarget(center: [0.5, 0.5], radius: 0.1)).radius * 393
    // Measure along image y instead: 0.1 image heights along y moves 0.1 in normalized y.
    let a = mapping.screenPoint(fromImage: [0.5, 0.5])
    let b = mapping.screenPoint(fromImage: [0.5, 0.6])
    #expect(isClose(hypot(a.x - b.x, a.y - b.y), radiusFromX, 1e-6))
}

// MARK: - AED arrow

@Test func arrowSitsOnTheAEDWhenItIsOnScreen() {
    let arrow = portraitMapping.arrow(to: [0, 0, -2], camera: cameraPose())
    #expect(arrow.isOnScreen)
    #expect(isClose(arrow.position.x, 0.5, 1e-4))
    #expect(isClose(arrow.position.y, 0.5, 1e-4))
    #expect(isClose(arrow.distance, 2, 1e-4))
}

@Test func arrowClampsToTheEdgeWhenInFrontButOffScreen() {
    // Far along image +x, which runs down the portrait view.
    let arrow = portraitMapping.arrow(to: [10, 0, -2], camera: cameraPose())
    #expect(!arrow.isOnScreen)
    #expect(isClose(arrow.position.x, 0.5, 1e-3))
    #expect(isClose(arrow.position.y, 1 - VisionOverlay.AEDArrow.edgeInset, 1e-3))
    #expect(isClose(arrow.angle, .pi / 2, 1e-3))
}

@Test func arrowPointsTheShortWayRoundWhenBehind() {
    let turnDown = portraitMapping.arrow(to: [1, 0, 2], camera: cameraPose())
    #expect(!turnDown.isOnScreen)
    #expect(isClose(turnDown.angle, .pi / 2, 1e-3))

    let turnUp = portraitMapping.arrow(to: [-1, 0, 2], camera: cameraPose())
    #expect(isClose(turnUp.angle, -.pi / 2, 1e-3))
    #expect(isClose(turnUp.position.y, VisionOverlay.AEDArrow.edgeInset, 1e-3))

    // Camera +y is image -y, which on a portrait view is screen right.
    let turnRight = portraitMapping.arrow(to: [0, 1, 2], camera: cameraPose())
    #expect(isClose(turnRight.angle, 0, 1e-3))
    #expect(isClose(turnRight.position.x, 1 - VisionOverlay.AEDArrow.edgeInset, 1e-3))
}

@Test func arrowStillPointsWhenDirectlyBehind() {
    let arrow = portraitMapping.arrow(to: [0, 0, 2], camera: cameraPose())
    #expect(!arrow.isOnScreen)
    #expect(arrow.angle.isFinite)
    #expect(arrow.position.x.isFinite && arrow.position.y.isFinite)
    #expect(isClose(arrow.distance, 2, 1e-4))
}

@Test(arguments: stride(from: 0.0, to: 360.0, by: 15.0).map { $0 })
func arrowStaysInsideTheViewAllTheWayRound(degrees: Double) {
    let radians = Float(degrees) * .pi / 180
    let world = SIMD3<Float>(4 * cos(radians), 0.5, 4 * sin(radians))
    let arrow = portraitMapping.arrow(to: world, camera: cameraPose())
    #expect((0...1).contains(arrow.position.x))
    #expect((0...1).contains(arrow.position.y))
}
