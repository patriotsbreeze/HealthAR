#if os(iOS)
import ARKit
import CoreVideo
import RealityKit
import SwiftUI

/// Wraps `ARSession` with gravity-aligned world tracking. The delegate only copies values and
/// hands off the pixel buffer, so `ARFrame`s are never retained.
final class ARController: NSObject, ARSessionDelegate, CameraDriver, @unchecked Sendable {
    let session = ARSession()
    /// Set once, before the session runs.
    weak var sink: VisionSession?

    private let queue = DispatchQueue(label: "healthai.vision.ar-delegate", qos: .userInteractive)
    /// Only touched on `queue`.
    private var floorY: Float?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func run() {
        guard isSupported else { return }
        queue.async { [self] in
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = .horizontal
            // Lights the ghost with the room's own light.
            configuration.environmentTexturing = .automatic
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            floorY = nil
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func pause() {
        queue.async { [self] in session.pause() }
    }

    /// Raycast first. With nothing to hit, fall back to the lowest plane seen, which puts an AED
    /// on a wall somewhere beyond the wall but in the right direction.
    func surfacePoint(along ray: WorldRay) async -> SIMD3<Float>? {
        await raycast(ray, fallsBackToFloor: true)
    }

    func surfaceHit(along ray: WorldRay) async -> SIMD3<Float>? {
        await raycast(ray, fallsBackToFloor: false)
    }

    private func raycast(_ ray: WorldRay, fallsBackToFloor: Bool) async -> SIMD3<Float>? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let query = ARRaycastQuery(
                    origin: ray.origin,
                    direction: ray.direction,
                    allowing: .estimatedPlane,
                    alignment: .any
                )
                if let hit = session.raycast(query).first {
                    continuation.resume(returning: hit.worldTransform.columns.3.xyz)
                } else if fallsBackToFloor {
                    continuation.resume(returning: floorY.flatMap { ray.hittingHorizontalPlane(y: $0) })
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let sink else { return }
        let camera = frame.camera
        let viewport = sink.viewportSize
        // Only frame.displayTransform knows the crop, and the frame can't be kept, so read it now.
        sink.ingest(
            pixels: frame.capturedImage,
            pose: CameraPose(
                transform: camera.transform,
                intrinsics: camera.intrinsics,
                imageResolution: [Double(camera.imageResolution.width), Double(camera.imageResolution.height)]
            ),
            tracking: TrackingQuality(camera.trackingState),
            imageToView: viewport.width > 0 && viewport.height > 0
                ? frame.displayTransform(for: .portrait, viewportSize: viewport)
                : nil
        )
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { noteFloor(in: anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { noteFloor(in: anchors) }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        sink?.driverFailed()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sink?.forgetWorld()
    }

    private func noteFloor(in anchors: [ARAnchor]) {
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            floorY = min(floorY ?? y, y)
        }
    }
}

extension TrackingQuality {
    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal: self = .normal
        case .limited: self = .limited
        case .notAvailable: self = .notAvailable
        }
    }
}

/// The camera feed behind the overlay. Reports its size to the session, which needs it for the
/// display mapping. Where AR isn't supported it is a plain black view.
public struct ARCameraView: UIViewRepresentable {
    private let vision: VisionSession

    public init(session: VisionSession) {
        vision = session
    }

    public func makeUIView(context: Context) -> UIView {
        let host = HostView()
        host.backgroundColor = .black
        host.vision = vision
        guard let session = vision.arSession else { return host }

        let arView = ARView(frame: host.bounds, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = session
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain]
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(arView)
        host.ghost = GhostRenderer(arView: arView, vision: vision)
        return host
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}

    private final class HostView: UIView {
        var vision: VisionSession?
        var ghost: GhostRenderer?

        override func layoutSubviews() {
            super.layoutSubviews()
            vision?.viewportSize = bounds.size
        }
    }
}

extension VisionSession {
    fileprivate var arSession: ARSession? {
        guard isARSupported, let controller = driver as? ARController else { return nil }
        return controller.session
    }
}
#endif
