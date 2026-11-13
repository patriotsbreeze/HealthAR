import Combine
import PlumbContracts
import RealityKit
import UIKit

extension CameraView {
    /// Keeps the camera view's ARView and everything drawn through it: entities placed in the
    /// world, the ring and the target line where the controller places them, the AED marker, and
    /// the pointer to the AED at the picture's edge. Make one, keep it, and pass it to `CameraView`.
    /// Main thread only.
    @MainActor
    public final class Coordinator {
        private weak var arView: ARView?
        /// Where the ring and the line are placed, read before each frame is drawn.
        private weak var controller: CaptureController?
        private var anchors: [ObjectIdentifier: AnchorEntity] = [:]
        private let guides = GuideEntities()
        private var guideState = GuideState.initial
        private var aed: (marker: Entity, foot: SIMD3<Float>)?
        private var pointer: AEDPointerView?
        private var frameUpdates: (any Cancellable)?

        /// Makes a coordinator with no view and nothing placed yet. The guides start visible.
        public init() {
            add(guides.root, atWorldPosition: .zero)
        }

        /// Shows `entity` fixed at `position` in the world: metres, in the session's gravity-aligned
        /// world space, the same space the hands box lives in. Placing an entity again moves it.
        /// Entities placed before the view appears show up when it does.
        public func add(_ entity: Entity, atWorldPosition position: SIMD3<Float>) {
            remove(entity)
            let anchor = AnchorEntity(world: position)
            anchor.addChild(entity)
            anchors[ObjectIdentifier(entity)] = anchor
            arView?.scene.addAnchor(anchor)
        }

        /// Takes `entity` and the anchor holding it out of the world. Does nothing if it was not placed.
        public func remove(_ entity: Entity) {
            guard let anchor = anchors.removeValue(forKey: ObjectIdentifier(entity)) else { return }
            anchor.removeFromParent()
            entity.removeFromParent()
        }

        // MARK: - Guides

        /// Says what the guides should show; call it on every tick. The ring shows on the chest
        /// whenever the hands box is placed and `visible` is true. The target line shows only while
        /// `compressing`: solid when `lock` is `.locked`, dashed when `.estimating`, and not at all
        /// for `.rateOnly` or `.lost`. `visible` false hides both. The AED marker is left alone.
        public func setGuides(lock: LockState, compressing: Bool, visible: Bool = true) {
            guideState = GuideState(lock: lock, compressing: compressing, visible: visible)
            refreshGuides()
        }

        /// Hides the ring and the target line until `setGuides` is next called with `visible` true.
        /// The AED marker and its pointer are left alone.
        public func hideGuides() {
            guideState.visible = false
            refreshGuides()
        }

        // MARK: - The AED

        /// Stands the AED marker at `position`, its foot at that world point in metres, and points
        /// to it from the picture's edge whenever it is out of sight. Showing it again moves it.
        /// A restarted capture session starts a new world, so clear the marker before restarting.
        public func showAED(atWorldPosition position: SIMD3<Float>) {
            clearAED()
            let marker = AEDMarker.make()
            add(marker, atWorldPosition: position)
            aed = (marker, position)
            refreshPointer()
        }

        /// Takes the AED marker and its pointer away. Does nothing when none is shown.
        public func clearAED() {
            if let aed { remove(aed.marker) }
            aed = nil
            pointer?.hide()
        }

        // MARK: - The view

        /// Starts drawing through `view`, with the guides placed by `controller`.
        func attach(_ view: ARView, controller: CaptureController) {
            detach()
            arView = view
            self.controller = controller
            for anchor in anchors.values { view.scene.addAnchor(anchor) }
            let pointer = AEDPointerView(frame: view.bounds)
            pointer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(pointer)
            self.pointer = pointer
            // RealityKit sends this on the main thread before it draws each frame.
            frameUpdates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        /// Stops drawing through `view` if it is the view drawn through now. A view that a newer one
        /// has already replaced was let go of when the newer one was attached.
        func detach(from view: ARView) {
            guard view === arView else { return }
            detach()
        }

        /// Stops drawing through the view; what is placed stays, to show again on the next attach.
        func detach() {
            frameUpdates?.cancel()
            frameUpdates = nil
            pointer?.removeFromSuperview()
            pointer = nil
            for anchor in anchors.values { anchor.removeFromParent() }
            arView = nil
            controller = nil
        }

        private func refresh() {
            refreshGuides()
            refreshPointer()
        }

        private func refreshGuides() {
            guides.apply(controller?.guidePlacement ?? .none, state: guideState)
        }

        /// Projects the AED marker into the view as the camera now stands and shows the pointer
        /// when the marker is out of sight.
        private func refreshPointer() {
            guard let arView, let pointer else { return }
            guard let aed else {
                pointer.hide()
                return
            }
            let camera = arView.cameraTransform
            let placement = EdgePointer.place(toward: aed.foot, marks: AEDMarker.marks(standingAt: aed.foot),
                                              camera: camera.translation,
                                              forward: camera.rotation.act(SIMD3<Float>(0, 0, -1)),
                                              view: arView.bounds, edge: pointer.edge,
                                              project: { arView.project($0) })
            guard let placement else {
                pointer.hide()
                return
            }
            pointer.show(placement, text: EdgePointer.words(distanceM: simd_distance(aed.foot, camera.translation)))
        }
    }
}
