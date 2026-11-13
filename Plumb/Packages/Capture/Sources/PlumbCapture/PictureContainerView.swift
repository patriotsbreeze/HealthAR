import ARKit
import RealityKit
import UIKit

/// Holds the ARView at the camera picture's own shape, centred with black bars beside it. An
/// ARView fills its bounds and crops whatever does not fit, so giving it bounds of the picture's
/// shape is what keeps the picture whole.
///
/// Assumption: the app runs in landscape. In `.landscapeRight` the picture is shown as the sensor
/// delivers it; in `.landscapeLeft` ARView turns it half a turn, and taps are turned back to match.
final class PictureContainerView: UIView {
    /// The view the picture is drawn through.
    let arView: ARView
    /// Gets each tap on the picture as a normalised image point. Taps on the bars are ignored.
    var onTap: (@MainActor (CGPoint) -> Void)?

    init(arView: ARView) {
        self.arView = arView
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(arView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @available(*, unavailable, message: "Built in code only")
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = fit.pictureFrame
    }

    /// Where the picture sits in this view right now.
    private var fit: PictureFit {
        PictureFit(imageSize: imageSize, viewSize: bounds.size,
                   halfTurn: window?.windowScene?.interfaceOrientation == .landscapeLeft)
    }

    /// The running session's image size; before it runs, the 1920 x 1440 (4:3) ARKit uses by default.
    private var imageSize: CGSize {
        arView.session.configuration?.videoFormat.imageResolution ?? CGSize(width: 1920, height: 1440)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let point = fit.imagePoint(fromViewPoint: recognizer.location(in: self)) else { return }
        onTap?(point)
    }
}
