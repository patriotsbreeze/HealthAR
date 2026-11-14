import RescueCore
import SwiftUI

/// On every screen, so no view of this app can be mistaken for a real emergency tool.
struct SimulationStrip: View {
    static let text = "SIMULATION, will not call 911"
    static let badge = "OPERATOR USED"
    /// The hidden gesture for the operator panel. A stage hand holds it, nobody finds it by accident.
    static let operatorHoldSeconds = 1.5

    var operatorUsed = false
    /// Nil where there's no operator panel to open.
    var onOperator: (() -> Void)?

    var body: some View {
        strip
            .modifier(OperatorGesture(action: onOperator))
    }

    /// A yellow pill on the camera rather than a band across it: the words are the same, and the
    /// picture shows round them. The whole row still takes the stage hand's hold.
    private var strip: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(Self.text)
                    .dsFont(DS.Fonts.strip)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if operatorUsed {
                    Text(Self.badge)
                        .dsFont(DS.Fonts.badge)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.Colors.ink, in: Capsule())
                        .foregroundStyle(DS.Colors.caution)
                        .accessibilityLabel("Operator panel was used in this run")
                }
            }
            .foregroundStyle(DS.Colors.ink)
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: DS.Height.strip)
            .background(DS.Colors.caution, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, DS.Space.xs)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        // Its words are pinned, so they never shrink to an ellipsis: beside the badge on a 375 pt phone
        // they fit up to this size, and the sheets, outside the main screen's cap, get it too.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

private struct OperatorGesture: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let action {
            content
                .onLongPressGesture(minimumDuration: SimulationStrip.operatorHoldSeconds) { action() }
                .accessibilityAction(named: "Open operator panel") { action() }
        } else {
            content
        }
    }
}

/// A glass pill. Each piece of text over the camera sits on its own dark-tinted chip, so it reads
/// over any scene.
struct Pill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 12)
            .frame(minHeight: DS.Height.pill + 4)
            .glassSurface(Capsule(style: .continuous))
    }
}

/// Time since the start, the link, the one floating control, and any alerts under them.
struct StatusRail: View {
    let coordinator: AppCoordinator
    @Binding var showsHUD: Bool
    let onAgents: () -> Void
    let onDispatcher: () -> Void
    let onSentinel: () -> Void

    var body: some View {
        let alerts = coordinator.statusAlerts
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.s) {
                ElapsedPill(coordinator: coordinator)
                LinkPill(coordinator: coordinator)
                AgentsPill(action: onAgents)
                Spacer(minLength: 0)
                OverflowMenu(coordinator: coordinator, showsHUD: $showsHUD, onDispatcher: onDispatcher, onSentinel: onSentinel)
            }
            .frame(minHeight: DS.Height.rail)
            // One to a line, because a warning cut off to fit a row is no warning.
            ForEach(alerts) { AlertRow(alert: $0) }
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.bottom, alerts.isEmpty ? 0 : DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(DS.Motion.alert, value: alerts)
        .sensoryFeedback(DS.Haptics.alert, trigger: alerts.filter { $0.weight == .act }.count) { old, new in new > old }
    }
}

private struct ElapsedPill: View {
    let coordinator: AppCoordinator

    var body: some View {
        Pill {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let seconds = coordinator.elapsedSeconds
                Text(elapsedText(seconds))
                    .dsFont(DS.Fonts.meta)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .accessibilityLabel("Elapsed \(Int(seconds) / 60) minutes \(Int(seconds) % 60) seconds")
            }
        }
    }
}

private struct LinkPill: View {
    let coordinator: AppCoordinator

    var body: some View {
        Pill {
            // A dot only for a real state, and it never pulses.
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(coordinator.linkLabel)
                .dsFont(DS.Fonts.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(coordinator.liveConnected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        // "AI switching, can't hear" is shown word for word, and past this it would lose "can't hear".
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var dot: Color {
        if coordinator.liveConnected { return DS.Colors.ok }
        return coordinator.liveSwapping ? DS.Colors.caution : DS.Colors.textTertiary
    }
}

/// Opens the agents sheet, so anyone watching can see what each part is doing.
private struct AgentsPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Pill {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text("Agents")
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            // The pill is short, but the tap target isn't.
            .frame(minHeight: DS.Height.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agents")
        .accessibilityHint("Shows what each part of the app is doing")
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// A floating glass control over the camera, with no text behind it.
/// The dispatcher and Someone is with me live here rather than in the deck, so the deck is only the
/// step and the camera keeps the screen. Neither ever is the step, and neither changes the flow's state
/// beyond what a tap on the old buttons did.
private struct OverflowMenu: View {
    let coordinator: AppCoordinator
    @Binding var showsHUD: Bool
    let onDispatcher: () -> Void
    let onSentinel: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Menu {
            Section {
                // Places no call. A teammate's phone plays the dispatcher.
                Button("CALL MOCK DISPATCHER", systemImage: "phone", action: onDispatcher)
                    .accessibilityLabel("Call mock dispatcher. Places no call.")
                // Gone once someone is with them, since saying so twice changes nothing.
                if !coordinator.state.resources.contains(.secondPerson) {
                    Button(RescueControls.title(for: .secondPerson), systemImage: "person.2") { coordinator.perform(.secondPerson) }
                }
            }
            Button("Sentinel", systemImage: "list.bullet.rectangle", action: onSentinel)
            Toggle("Latency display", systemImage: "gauge.with.dots.needle.33percent", isOn: $showsHUD)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: DS.Height.control, height: DS.Height.control)
                .modifier(FloatingSurface(reduceTransparency: reduceTransparency))
                .contentShape(Circle())
        }
        .accessibilityLabel("More")
    }
}

private struct FloatingSurface: ViewModifier {
    let reduceTransparency: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(DS.Colors.surfaceRaised, in: Circle())
        } else {
            content.glassEffect(.regular.interactive(), in: Circle())
        }
    }
}

struct AlertRow: View {
    let alert: StatusAlert

    var body: some View {
        Label {
            Text(alert.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: alert.symbol)
                .foregroundStyle(alert.weight == .act ? DS.Colors.ink : DS.Colors.caution)
        }
        .dsFont(DS.Fonts.label)
        .foregroundStyle(alert.weight == .act ? DS.Colors.ink : DS.Colors.textPrimary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, 6)
        .frame(minHeight: DS.Height.alertRow)
        .background(alert.weight == .act ? DS.Colors.caution : DS.Glass.chipTint, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay {
            if alert.weight == .info {
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(DS.Colors.caution.opacity(0.6), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tops every sheet. A sheet covers the main beat, and the beat has to stay on screen during
/// compressions whatever else is open, so the current step comes along with it.
struct SheetTopBar: View {
    let coordinator: AppCoordinator
    /// The same hidden hold as the main screen's strip. It swaps this sheet for the operator panel.
    var onOperator: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            SimulationStrip(operatorUsed: coordinator.operatorUsed, onOperator: onOperator)
            if coordinator.showsPulse {
                HStack(spacing: DS.Space.m) {
                    BeatPulse(diameter: DS.Pulse.sheet, showsLabel: false)
                    Text(coordinator.instruction)
                        .dsFont(DS.Fonts.label)
                        .lineLimit(2)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.s)
                .background(DS.Colors.surfaceRaised)
            }
        }
    }
}

/// A sheet's section heading. Sentence case, quiet, and never yellow.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .dsFont(DS.Fonts.meta)
            .foregroundStyle(DS.Colors.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// For the rail. "T+" stays on the Sentinel rows, where it marks a time since the start.
func elapsedText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

func clockText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "T+%d:%02d", total / 60, total % 60)
}
