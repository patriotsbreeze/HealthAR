import SwiftUI

/// The rescue screen: the camera picture on the left at its own 4:3 shape, the coach panel on the right.
///
/// Nothing is ever drawn over the picture. Before the first push this same screen is the start state:
/// give the panel a `startPrompt` and an empty model.
public struct RescueScreen<Camera: View>: View {
    private let panel: CoachPanel
    private let camera: Camera

    /// A rescue screen from a ready-made panel and the camera's view.
    /// - Parameters:
    ///   - panel: the right-hand panel.
    ///   - camera: the live picture. It is given a 4:3 frame and should fit inside it without cropping.
    public init(panel: CoachPanel, @ViewBuilder camera: () -> Camera) {
        self.panel = panel
        self.camera = camera()
    }

    /// The picture and the panel side by side, edge to edge.
    public var body: some View {
        GeometryReader { proxy in
            let plan = ScreenPlan(size: proxy.size, panelReferenceWidth: Theme.metrics.panelWidth)
            HStack(spacing: 0) {
                camera
                    .frame(width: plan.pictureSize.width, height: plan.pictureSize.height)
                    .clipped()
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                panel
                    .frame(width: plan.panelWidth)
            }
            .environment(\.plumbUnit, plan.unit)
        }
        .background(Theme.Palette.ground.color)
        // The picture runs to the screen's edges; the panel keeps its own margins.
        .ignoresSafeArea()
    }
}
