import SwiftUI

/// The chest check: the camera picture on the left at its own 4:3 shape, a dark panel on the right with the
/// status or the command, a moving line of chest height, one line of context, and two plain-word controls.
///
/// Someone lies on a mat in view; the line rises and falls with their chest and goes flat when it is held still.
/// The screen keeps no state: the app hands it the words and the trace from each reading. Nothing is drawn
/// over the picture. It also serves as the idle screen between rescues.
public struct ChestScreen<Camera: View>: View {
    private let panel: ChestPanel
    private let camera: Camera

    /// A chest screen showing the values it is given.
    /// - Parameters:
    ///   - status: what the check reports, such as "Chest movement seen". Shown large while there is no command.
    ///   - command: the command, drawn in the accent in upper case, or nil. The check only ever gives "Start pushing",
    ///     and once given the app keeps passing it until a person resets the check.
    ///   - context: one small line, such as "Tap the chest on the picture", or nil for none.
    ///   - trace: chest height in millimetres, evenly spaced in time, oldest first and newest last. Nil where nothing
    ///     was measured. Drawn edge to edge about zero at a fixed scale.
    ///   - band: the threshold band in the same millimetres, drawn faintly behind the line, or nil for none.
    ///   - bandShare: share of the width, counted from the right, that the band covers. 0...1.
    ///   - onStartPushing: "Start pushing" was pressed.
    ///   - onBack: "Back" was pressed.
    ///   - camera: the live picture. It is given a 4:3 frame and should fit inside it without cropping.
    ///     Tapping the chest on it is how the app learns where to measure.
    public init(status: String,
                command: String?,
                context: String?,
                trace: [Double?],
                band: ClosedRange<Double>?,
                bandShare: Double,
                onStartPushing: @escaping () -> Void,
                onBack: @escaping () -> Void,
                @ViewBuilder camera: () -> Camera) {
        panel = ChestPanel(status: status, command: command, context: context, trace: trace, band: band,
                           bandShare: bandShare, onStartPushing: onStartPushing, onBack: onBack)
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
