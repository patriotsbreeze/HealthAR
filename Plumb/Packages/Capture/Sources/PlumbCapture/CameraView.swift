import ARKit
import RealityKit
import SwiftUI
import UIKit

/// Shows the live camera picture whole, letterboxed and never cropped, and reports taps on it as
/// normalised image points ready for `CaptureController.seed(atNormalizedImagePoint:)`.
///
/// Draws with a RealityKit ARView bound to the controller's session; the view never configures or
/// runs the session itself. Over the picture it draws the ring and the target line where the
/// controller places them, and the AED marker; the coordinator says which show. Main thread only,
/// like every SwiftUI view.
@MainActor
public struct CameraView: UIViewRepresentable {
    private let controller: CaptureController
    private let coordinator: Coordinator
    private let onTap: @MainActor (CGPoint) -> Void

    /// Shows `controller`'s camera. Pass a `coordinator` you keep to drive the guides and the AED
    /// marker and to place entities in the world; without one the view makes its own. `onTap`
    /// gets the tapped point, 0...1 across the camera image from its top-left.
    public init(controller: CaptureController, coordinator: Coordinator? = nil,
                onTap: @escaping @MainActor (CGPoint) -> Void) {
        self.controller = controller
        self.coordinator = coordinator ?? Coordinator()
        self.onTap = onTap
    }

    /// Hands SwiftUI the coordinator given at init, so the caller and the view share it.
    public func makeCoordinator() -> Coordinator {
        coordinator
    }

    /// Builds the ARView inside a container that keeps it at the picture's shape.
    public func makeUIView(context: Context) -> UIView {
        // No automatic configuration: the controller alone decides how the session runs. Render
        // options are left at their defaults, which draw people in front of virtual content
        // whenever the controller runs people segmentation.
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.session = controller.session
        let container = PictureContainerView(arView: arView)
        container.onTap = onTap
        context.coordinator.attach(arView, controller: controller)
        return container
    }

    /// Picks up a new tap handler when SwiftUI rebuilds the view.
    public func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? PictureContainerView)?.onTap = onTap
    }

    /// Lets go of the ARView when the view leaves the screen. Two screens that both show the camera
    /// can overlap while one replaces the other, so only the view the coordinator still draws
    /// through is let go; one already replaced by a newer view has nothing left to undo.
    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let container = uiView as? PictureContainerView else { return }
        coordinator.detach(from: container.arView)
    }
}
