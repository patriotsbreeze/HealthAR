import RescueCore
import SwiftUI

/// The operator badge on a screen of its own, like a sheet or the stop confirmation, where it
/// also takes the stage hand's hold. Nothing at all until the panel is used.
struct OperatorBadgeRow: View {
    var operatorUsed = false
    var onOperator: (() -> Void)?

    var body: some View {
        if operatorUsed {
            HStack(spacing: 0) {
                OperatorBadge()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.xs)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .modifier(OperatorGesture(action: onOperator))
        }
    }
}

/// Says the operator panel was used in this run, so a forced beat is never passed off as a real one.
struct OperatorBadge: View {
    static let text = "OPERATOR USED"

    var body: some View {
        Text(Self.text)
            .dsFont(DS.Fonts.badge)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: DS.Height.pill)
            .background(DS.Colors.caution, in: Capsule(style: .continuous))
            .foregroundStyle(DS.Colors.ink)
            .accessibilityLabel("Operator panel was used in this run")
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

struct OperatorGesture: ViewModifier {
    /// The hidden gesture for the operator panel. A stage hand holds it, nobody finds it by accident.
    static let holdSeconds = 1.5

    let action: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let action {
            content
                .onLongPressGesture(minimumDuration: Self.holdSeconds) { action() }
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

/// Time since the start, the agents, the one floating control, and any alerts under them. The link
/// has no pill: the orb shows when the AI can hear, and an alert says when it can't.
struct StatusRail: View {
    let coordinator: AppCoordinator
    @Binding var showsHUD: Bool
    let onAgents: () -> Void
    let onDispatcher: () -> Void
    let onSentinel: () -> Void
    /// The stage hand's hidden hold, on the clock now that the strip is gone.
    var onOperator: (() -> Void)?

    var body: some View {
        let alerts = coordinator.statusAlerts
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.s) {
                ElapsedPill(coordinator: coordinator)
                    .modifier(OperatorGesture(action: onOperator))
                AgentsStrip(coordinator: coordinator, action: onAgents)
                if coordinator.operatorUsed { OperatorBadge() }
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

/// Every agent, one fixed slot each in a fixed order, so the row never moves: only the dot changes,
/// grey when it's off, green when it's running, blue when it's busy this moment. The words are in
/// the agents sheet, which a tap still opens, and in VoiceOver.
private struct AgentsStrip: View {
    let coordinator: AppCoordinator
    let action: () -> Void

    enum Activity: Equatable { case off, running, busy }

    struct Slot: Identifiable, Equatable {
        var id: String { name }
        var symbol: String
        /// A word or two under the icon, so which agent it is never needs guessing.
        var tag: String
        var name: String
        var status: String
        var activity: Activity
    }

    static let slotWidth: CGFloat = 40

    var body: some View {
        Button(action: action) {
            // Vision's statuses change without telling anyone, so it looks again twice a second.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                // Named as a group, so the row reads as the AI agents at work and not as settings.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        ForEach(Self.slots(coordinator)) { slot($0) }
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 7, weight: .bold))
                        Text("AI AGENTS")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(DS.Assessment.tint)
                    .padding(.leading, 2)
                }
            }
            .frame(minHeight: DS.Height.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agents: " + Self.slots(coordinator).map { "\($0.name), \($0.status)" }.joined(separator: "; "))
        .accessibilityHint("Shows what each part of the app is doing")
    }

    private func slot(_ slot: Slot) -> some View {
        VStack(spacing: 1) {
            Image(systemName: slot.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(slot.tag)
                .font(.system(size: 8, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(slot.activity == .off ? DS.Colors.textTertiary : DS.Colors.textPrimary)
        .frame(width: Self.slotWidth, height: 32)
        .glassSurface(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(color(slot.activity))
                    .frame(width: 6, height: 6)
                    .offset(x: -4, y: 4)
            }
            .opacity(slot.activity == .off ? 0.55 : 1)
            .animation(DS.Motion.alert, value: slot.activity)
    }

    private func color(_ activity: Activity) -> Color {
        switch activity {
        case .off: DS.Colors.textTertiary
        case .running: DS.Colors.ok
        case .busy: DS.Assessment.tint
        }
    }

    /// The same five, always, in this order.
    static func slots(_ c: AppCoordinator) -> [Slot] {
        let live = c.liveConnected
        let voice: (String, Activity) = !live ? ("Offline", .off) : c.aiTalking ? ("Talking", .busy) : c.aiListening ? ("Listening", .running) : ("Connected", .running)
        let scene: (String, Activity) = c.assessing ? ("Looking", .busy) : c.sceneRead != nil ? ("Watching", .running) : ("Off", .off)
        let aed: (String, Activity)
        if !c.aedFinderAvailable {
            aed = ("Off", .off)
        } else {
            switch c.vision.aedStatus {
            case .locating: aed = ("Searching", .busy)
            case .located: aed = ("AED found", .running)
            default: aed = ("Standing by", .running)
            }
        }
        return [
            Slot(symbol: "mic.fill", tag: "VOICE", name: "Voice guide", status: voice.0, activity: voice.1),
            Slot(symbol: "checkmark.shield.fill", tag: "SAFETY", name: "Safety checker", status: live ? "Checking" : "Off", activity: live ? .running : .off),
            Slot(symbol: "eye.fill", tag: "SCENE", name: "Scene reader", status: scene.0, activity: scene.1),
            Slot(symbol: "bolt.heart.fill", tag: "AED", name: "AED finder", status: aed.0, activity: aed.1),
            Slot(symbol: "phone.fill", tag: "911", name: "911 agent", status: c.callerAgentActive ? "On call" : "Ready", activity: c.callerAgentActive ? .busy : .off),
        ]
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
    /// The same hidden hold as the main screen's clock, on the badge once there is one.
    var onOperator: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            OperatorBadgeRow(operatorUsed: coordinator.operatorUsed, onOperator: onOperator)
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
