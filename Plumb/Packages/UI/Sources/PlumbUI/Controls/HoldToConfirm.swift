import SwiftUI

/// A plain-word control that must be pressed and held. While held, a fill runs along its own baseline.
///
/// Used for "New rescue", which confirms only when the fill completes, and for "Hold to ask",
/// which acts for as long as it is held.
public struct HoldToConfirm: View {
    private let title: String
    private let holdSeconds: Double
    private let onBegan: () -> Void
    private let onEnded: () -> Void
    private let onConfirmed: () -> Void

    @State private var held = HoldPress()
    @State private var confirmation: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.plumbUnit) private var unit
    @Environment(\.plumbSurface) private var surface

    /// A control showing `title` that reports a press, its release and, if held long enough, its confirmation.
    /// - Parameters:
    ///   - holdSeconds: how long the control must be held for the fill to complete.
    ///   - onBegan: called the moment it is pressed.
    ///   - onEnded: called when it is let go, whether or not it confirmed, and also when it leaves the
    ///     screen or the app leaves the foreground while still held, so every press that began ends.
    ///   - onConfirmed: called once if it is still held when the fill completes.
    public init(_ title: String,
                holdSeconds: Double = Theme.metrics.holdSeconds,
                onBegan: @escaping () -> Void = {},
                onEnded: @escaping () -> Void = {},
                onConfirmed: @escaping () -> Void = {}) {
        self.title = title
        self.holdSeconds = holdSeconds
        self.onBegan = onBegan
        self.onEnded = onEnded
        self.onConfirmed = onConfirmed
    }

    /// The words, the line under them that fills, and the press that drives it.
    public var body: some View {
        Text(title)
            .font(Theme.Face.text(.body, unit: unit))
            .foregroundStyle(surface.mark.color)
            .lineLimit(1)
            .fixedSize()
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                baseline
            }
            .frame(minHeight: Theme.metrics.controlHeight * unit)
            .contentShape(Rectangle())
            .gesture(press)
            // SwiftUI drops a gesture whose view goes away, or whose app leaves the foreground, without
            // calling its end. A press still held ends here instead, so nothing it started is left running.
            .onDisappear { end() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { end() }
            }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityHint("Press and hold")
            .accessibilityAddTraits(.isButton)
            // Assistive technologies cannot hold, so their one action runs the whole press.
            .accessibilityAction {
                onBegan()
                onConfirmed()
                onEnded()
            }
    }

    /// A resting hairline shows where the fill will run, which is the only hint that this control is held.
    private var baseline: some View {
        let metrics = Theme.metrics
        return ZStack {
            BaselineRule()
                .stroke(surface.quiet.color.opacity(metrics.ruleOpacity), lineWidth: metrics.ruleWidth * unit)
            BaselineRule()
                .trim(from: 0, to: held.isHeld ? 1 : 0)
                .stroke(surface.mark.color, lineWidth: metrics.holdFillWidth * unit)
                .animation(.linear(duration: held.isHeld ? holdSeconds : metrics.fadeSeconds), value: held.isHeld)
        }
        .frame(height: metrics.holdFillWidth * unit)
        .alignmentGuide(.firstTextBaseline) { $0[.top] }
        .offset(y: metrics.holdBaselineDrop * unit)
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in begin() }
            .onEnded { _ in end() }
    }

    private func begin() {
        guard held.begin() else { return }
        onBegan()
        confirmation = Task {
            try? await Task.sleep(for: .seconds(holdSeconds))
            guard !Task.isCancelled else { return }
            onConfirmed()
        }
    }

    private func end() {
        confirmation?.cancel()
        confirmation = nil
        guard held.end() else { return }
        onEnded()
    }
}

/// Whether a `HoldToConfirm` is held, kept apart from the view so the rule can be tested: a press begins
/// once however long the finger stays down, and ends once, whether the finger comes up, the control
/// leaves the screen or the app leaves the foreground, whichever comes first.
struct HoldPress: Equatable {
    private(set) var isHeld = false

    /// The finger is down. True when this begins a press.
    mutating func begin() -> Bool {
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    /// The press is over, for whatever reason. True when a press was going and this ends it.
    mutating func end() -> Bool {
        guard isHeld else { return false }
        isHeld = false
        return true
    }
}

/// A level line across the middle of its frame. Trimmed from the leading end to show a hold filling.
private struct BaselineRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
