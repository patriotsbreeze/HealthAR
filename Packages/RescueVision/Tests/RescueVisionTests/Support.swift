import CoreGraphics
import CoreVideo
import Foundation
import RescueCore
import Synchronization
import Testing
import simd
@testable import RescueVision

func repoRoot(file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}

func isClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

func isClose(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ tolerance: Double = 1e-6) -> Bool {
    isClose(a.x, b.x, tolerance) && isClose(a.y, b.y, tolerance)
}

func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-3) -> Bool {
    simd_distance(a, b) <= tolerance
}

/// fx = fy = 1000, principal point at the center of a 1920 x 1440 image.
let testIntrinsics = simd_float3x3(columns: (
    SIMD3<Float>(1000, 0, 0),
    SIMD3<Float>(0, 1000, 0),
    SIMD3<Float>(960, 720, 1)
))

func cameraPose(_ transform: simd_float4x4 = matrix_identity_float4x4) -> CameraPose {
    CameraPose(transform: transform, intrinsics: testIntrinsics, imageResolution: [1920, 1440])
}

func transform(rotationY degrees: Float = 0, position: SIMD3<Float> = .zero) -> simd_float4x4 {
    var matrix = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: [0, 1, 0]))
    matrix.columns.3 = SIMD4(position, 1)
    return matrix
}

/// A phone held upright in portrait, looking along world -z. Camera +x points at the ground.
let portraitLevel = simd_float4x4(columns: (
    SIMD4<Float>(0, -1, 0, 0),
    SIMD4<Float>(1, 0, 0, 0),
    SIMD4<Float>(0, 0, 1, 0),
    SIMD4<Float>(0, 0, 0, 1)
))

/// A phone flat above the floor with the back camera looking straight down.
let lookingStraightDown = simd_float4x4(columns: (
    SIMD4<Float>(0, 0, 1, 0),
    SIMD4<Float>(1, 0, 0, 0),
    SIMD4<Float>(0, 1, 0, 0),
    SIMD4<Float>(0, 1.5, 0, 1)
))

/// Portrait aspect-fill of a 1920 x 1440 image in a 393 x 852 view. Image y runs along the
/// view's width and image x down its height.
let portraitMapping = DisplayMapping(
    imageToView: CGAffineTransform(a: 0, b: 1, c: -639.0 / 393, d: 0, tx: 0.5 + 639.0 / 393 / 2, ty: 0),
    viewSize: CGSize(width: 393, height: 852),
    imageAspect: 4.0 / 3
)

/// Builds a person from image-space geometry with equal x and y scale.
/// - Parameter axisDegrees: Shoulder-to-hip direction in image axes. 0 is +x, 90 is +y (down).
func person(
    center: SIMD2<Double> = [0.5, 0.5],
    axisDegrees: Double,
    length: Double = 0.4,
    width: Double = 0.3,
    confidence: Double = 0.9,
    aspect: Double = 1
) -> DetectedPerson {
    let radians = axisDegrees * .pi / 180
    let axis = SIMD2(cos(radians), sin(radians))
    let across = SIMD2(-axis.y, axis.x)
    let centerIso = SIMD2(center.x * aspect, center.y)
    let joint: (SIMD2<Double>) -> DetectedPerson.Joint = { point in
        DetectedPerson.Joint(position: [point.x / aspect, point.y], confidence: confidence)
    }
    return DetectedPerson(
        leftShoulder: joint(centerIso - axis * length / 2 - across * width / 2),
        rightShoulder: joint(centerIso - axis * length / 2 + across * width / 2),
        leftHip: joint(centerIso + axis * length / 2 - across * width / 2),
        rightHip: joint(centerIso + axis * length / 2 + across * width / 2)
    )
}

final class TestClock: Sendable {
    private let time: Mutex<TimeInterval>
    init(_ start: TimeInterval = 100) { time = Mutex(start) }
    var now: TimeInterval { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

func makePixels(width: Int = 64, height: Int = 48, whiteRect: CGRect? = nil) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    precondition(status == kCVReturnSuccess)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<height {
        for x in 0..<width {
            let inside = whiteRect?.contains(CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height))) ?? false
            let value: UInt8 = inside ? 255 : 0
            let pixel = base + y * bytesPerRow + x * 4
            pixel[0] = value
            pixel[1] = value
            pixel[2] = value
            pixel[3] = 255
        }
    }
    return pixels
}

/// The AR side of a session, without ARKit.
final class FakeDriver: CameraDriver {
    private struct Calls {
        var runs = 0
        var pauses = 0
    }

    private let calls = Mutex(Calls())
    private let surface: @Sendable (WorldRay) -> SIMD3<Float>?
    let isSupported: Bool

    init(isSupported: Bool = true, surface: @escaping @Sendable (WorldRay) -> SIMD3<Float>? = { _ in nil }) {
        self.isSupported = isSupported
        self.surface = surface
    }

    var runs: Int { calls.withLock { $0.runs } }
    var pauses: Int { calls.withLock { $0.pauses } }

    func run() { calls.withLock { $0.runs += 1 } }
    func pause() { calls.withLock { $0.pauses += 1 } }
    func surfacePoint(along ray: WorldRay) async -> SIMD3<Float>? { surface(ray) }
}

/// Holds its answer until released, the way a slow cloud call does.
final class GatedLocator: ObjectLocating {
    private struct State {
        var calls = 0
        var labels: [String] = []
        var waiters: [CheckedContinuation<NormalizedBox?, Never>] = []
    }

    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    var labels: [String] { state.withLock { $0.labels } }

    func locate(jpeg: Data, label: String) async -> NormalizedBox? {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.calls += 1
                $0.labels.append(label)
                $0.waiters.append(continuation)
            }
        }
    }

    func release(_ box: NormalizedBox?) {
        let waiters = state.withLock { state -> [CheckedContinuation<NormalizedBox?, Never>] in
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: box) }
    }
}

struct FixedLocator: ObjectLocating {
    var box: NormalizedBox?
    func locate(jpeg: Data, label: String) async -> NormalizedBox? { box }
}

/// Answers several materials in one call, the way the app's multi-label locator does.
final class MultiLocator: ObjectLocating {
    private let asked = Mutex<[[Material]]>([])
    private let answers: Mutex<[Material: NormalizedBox]>

    init(_ boxes: [Material: NormalizedBox]) { answers = Mutex(boxes) }

    /// Each call's materials, in the order asked.
    var calls: [[Material]] { asked.withLock { $0 } }
    func answer(_ boxes: [Material: NormalizedBox]) { answers.withLock { $0 = boxes } }

    func locate(jpeg: Data, label: String) async -> NormalizedBox? {
        Issue.record("the single-label path should not be used")
        return nil
    }

    func locate(jpeg: Data, materials: [Material]) async -> [Material: NormalizedBox] {
        asked.withLock { $0.append(materials) }
        return answers.withLock { $0 }.filter { materials.contains($0.key) }
    }
}

/// A whole body, built like `person`: arms down the sides from the shoulders, legs on from the
/// hips, all along the body's axis, and a nose beyond the shoulders.
func fullPerson(
    center: SIMD2<Double> = [0.5, 0.5],
    axisDegrees: Double,
    length: Double = 0.4,
    width: Double = 0.3,
    confidence: Double = 0.9,
    limbConfidence: Double? = nil,
    aspect: Double = 1
) -> DetectedPerson {
    var body = person(center: center, axisDegrees: axisDegrees, length: length, width: width, confidence: confidence, aspect: aspect)
    let radians = axisDegrees * .pi / 180
    let axis = SIMD2(cos(radians), sin(radians))
    let across = SIMD2(-axis.y, axis.x)
    let iso: (SIMD2<Double>) -> SIMD2<Double> = { [$0.x * aspect, $0.y] }
    let joint: (SIMD2<Double>) -> DetectedPerson.Joint = { point in
        DetectedPerson.Joint(position: [point.x / aspect, point.y], confidence: limbConfidence ?? confidence)
    }
    let leftShoulder = iso(body.leftShoulder.position)
    let rightShoulder = iso(body.rightShoulder.position)
    let leftElbow = leftShoulder + axis * length * 0.6 - across * width * 0.15
    let rightElbow = rightShoulder + axis * length * 0.6 + across * width * 0.15
    let leftKnee = iso(body.leftHip.position) + axis * length
    let rightKnee = iso(body.rightHip.position) + axis * length
    body.extras = [
        .nose: joint((leftShoulder + rightShoulder) / 2 - axis * length * 0.35),
        .leftElbow: joint(leftElbow),
        .leftWrist: joint(leftElbow + axis * length * 0.55),
        .rightElbow: joint(rightElbow),
        .rightWrist: joint(rightElbow + axis * length * 0.55),
        .leftKnee: joint(leftKnee),
        .leftAnkle: joint(leftKnee + axis * length * 0.9),
        .rightKnee: joint(rightKnee),
        .rightAnkle: joint(rightKnee + axis * length * 0.9),
    ]
    return body
}

func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
