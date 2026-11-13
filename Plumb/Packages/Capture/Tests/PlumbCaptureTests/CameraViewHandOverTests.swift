import RealityKit
import Testing
import UIKit
@testable import PlumbCapture

/// Two screens that both show the camera overlap while one replaces the other. The coordinator must
/// end up drawing through the newer view, whichever order the two views come and go in.
@MainActor
struct CameraViewHandOverTests {
    private func pointers(in view: ARView) -> Int {
        view.subviews.filter { $0 is AEDPointerView }.count
    }

    @Test(.timeLimit(.minutes(1)))
    func theOldViewLeavingDoesNotTakeTheNewOneWithIt() {
        let controller = CaptureController()
        let coordinator = CameraView.Coordinator()
        let old = ARView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), cameraMode: .nonAR,
                         automaticallyConfigureSession: false)
        let new = ARView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), cameraMode: .nonAR,
                         automaticallyConfigureSession: false)
        coordinator.attach(old, controller: controller)
        coordinator.attach(new, controller: controller)
        #expect(pointers(in: old) == 0 && pointers(in: new) == 1)

        coordinator.detach(from: old)
        #expect(pointers(in: new) == 1)
        #expect(new.scene.anchors.count == 1)

        coordinator.detach(from: new)
        #expect(pointers(in: new) == 0)
        #expect(new.scene.anchors.isEmpty)
    }
}
