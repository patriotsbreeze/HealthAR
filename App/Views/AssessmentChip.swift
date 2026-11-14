import RescueLive
import SwiftUI

/// The AI's one-glance read of the scene, beside the listening orb. Shut, it's two lines: what the
/// camera shows and what it might be. A tap drops down the live log: each time the voice AI described
/// the view and why it mattered, its tool calls, and what was heard and said, newest first. It never
/// says what to do next; the deck does that.
struct AssessmentChip: View {
    static let pendingText = "Assessing the situation…"
    static let failedText = "Can't reach the AI. Trying again…"
    static let footnote = "AI read, not a diagnosis. The protocol picks each step."

    let assessment: SituationAssessment?
    /// What the voice AI saw, did, heard and said, newest first.
    var log: [AppCoordinator.AssessmentLogEntry] = []
    /// Who made the scene lines, so a frame's quick look isn't taken for the live view.
    var source: String?
    let assessing: Bool
    var failed = false
    /// Open by default: the log drops down by itself once there's a line in it. A tap only puts it away.
    @State private var collapsed = false
    private var isOpen: Bool { !collapsed && !log.isEmpty }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button { if !log.isEmpty { collapsed.toggle() } } label: {
                summary
                    .padding(.horizontal, DS.Space.s + 2)
                    .padding(.vertical, 6)
                    .frame(minHeight: DS.Height.control)
                    .frostedGlass(RoundedRectangle(cornerRadius: DS.Assessment.radius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: DS.Assessment.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: DS.Assessment.maxWidth, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(log.isEmpty ? "" : (isOpen ? "Hides the live log." : "Shows the live log."))
            if isOpen {
                // Its own pane under the pill, dropping down from it, so the pill stays two lines.
                details(assessment)
                    .padding(DS.Space.s)
                    .frame(maxWidth: DS.Assessment.panelWidth, alignment: .leading)
                    .frostedGlass(RoundedRectangle(cornerRadius: DS.Assessment.radius, style: .continuous))
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: isOpen)
        .animation(DS.Motion.alert, value: assessment)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            ThinkingMark(active: assessing, reduceMotion: reduceMotion)
            if let assessment {
                VStack(alignment: .leading, spacing: 1) {
                    if let emergency = assessment.emergency {
                        // Red, and first, because it's the one line that should stop someone.
                        Label(emergency, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(TightLabel(iconColor: DS.Colors.critical))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Colors.critical)
                            .lineLimit(2)
                            .transition(.opacity)
                    }
                    Label {
                        Text(assessment.sees ?? assessment.headline)
                    } icon: {
                        if assessment.sees != nil { Image(systemName: "eye") }
                    }
                    .labelStyle(TightLabel())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                    Text("\(assessment.prediction) · \(assessment.confidence.rawValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                .contentTransition(.opacity)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(DS.Glass.fill, in: Circle())
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            } else {
                Text(failed && !assessing ? Self.failedText : Self.pendingText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private func details(_ assessment: SituationAssessment?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(source == AppCoordinator.AssessmentSource.live.rawValue ? DS.Colors.ok : DS.Assessment.tint)
                    .frame(width: 6, height: 6)
                Text("Live log")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                if let source {
                    Text(source)
                        .font(.system(size: 9))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            if let watch = assessment?.watchFor {
                Label(watch, systemImage: "exclamationmark.triangle")
                    .labelStyle(TightLabel())
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(log) { LogRow(entry: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: DS.Assessment.openMaxHeight)
            .animation(DS.Motion.alert, value: log)
            Text(Self.footnote)
                .font(.system(size: 9))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var accessibilityText: String {
        guard let assessment else { return failed && !assessing ? Self.failedText : Self.pendingText }
        let sees = (assessment.emergency.map { "Possible emergency: \($0). " } ?? "") + (assessment.sees.map { "Sees: \($0). " } ?? "")
        return "AI read: \(sees)\(assessment.headline). \(assessment.prediction), \(assessment.confidence.rawValue) confidence. Not a diagnosis."
    }
}

/// An icon and its words close together, the icon skipped when there isn't one.
private struct TightLabel: LabelStyle {
    var iconColor = DS.Assessment.tint

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.font(.system(size: 12, weight: .semibold)).foregroundStyle(iconColor)
            configuration.title
        }
    }
}

/// A small sparkle that breathes while a read is on its way, and sits still once it's in.
private struct ThinkingMark: View {
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = active && !reduceMotion ? (1 - cos(2 * .pi * time / 1.4)) / 2 : 1
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Assessment.tint)
                .opacity(0.45 + 0.55 * pulse)
                .scaleEffect(0.9 + 0.1 * pulse)
        }
        .frame(width: 16)
        .accessibilityHidden(true)
    }
}

/// Frosted glass: a blur of the camera behind, washed with the AI's sky, lit along the top edge,
/// floating on a soft shadow. Reduce Transparency gets the solid surface instead.
private struct FrostedGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(DS.Colors.surface, in: shape)
                .overlay(shape.strokeBorder(DS.Colors.hairline, lineWidth: 1))
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        // A dark floor, so white type reads over a bright scene.
                        shape.fill(DS.Assessment.glassFloor)
                        shape.fill(LinearGradient(
                            colors: [DS.Assessment.tint.opacity(0.18), DS.Assessment.tint.opacity(0.02)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        // The sheen: light catching the top of the pane.
                        shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
                    }
                    .environment(\.colorScheme, .dark)
                }
                .overlay(shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.08), DS.Assessment.tint.opacity(0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                ))
                .shadow(color: .black.opacity(0.30), radius: 18, y: 10)
                .shadow(color: DS.Assessment.tint.opacity(0.18), radius: 10)
        }
    }
}

private extension View {
    func frostedGlass<S: InsettableShape>(_ shape: S) -> some View { modifier(FrostedGlass(shape: shape)) }
}

/// One line of the live log: when, what kind, and the words, with the AI's reason under a scene line.
private struct LogRow: View {
    let entry: AppCoordinator.AssessmentLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(elapsedText(entry.at))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary)
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text)
                    .font(entry.kind == .tool ? .system(size: 10, weight: .regular, design: .monospaced) : nil)
                    .lineLimit(2)
                    .foregroundStyle(entry.kind == .alert ? DS.Colors.critical : [.saw, .call].contains(entry.kind) ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .fontWeight(entry.kind == .alert ? .semibold : nil)
                if let detail = entry.detail {
                    Text(detail).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(entry.text). \(entry.detail ?? "")")
    }

    private var symbol: String {
        switch entry.kind {
        case .alert: "exclamationmark.triangle.fill"
        case .call: "phone.fill"
        case .saw: "eye"
        case .tool: "wrench.and.screwdriver"
        case .heard: "person.wave.2"
        case .said: "waveform"
        case .look: "camera.viewfinder"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .alert: DS.Colors.critical
        case .call: DS.Colors.textPrimary
        case .saw, .look: DS.Assessment.tint
        case .tool: DS.Colors.textPrimary
        case .heard, .said: DS.Colors.textSecondary
        }
    }

    private var label: String {
        switch entry.kind {
        case .alert: "Possible emergency"
        case .call: "911 call, simulated"
        case .saw: "Saw"
        case .tool: "Tool call"
        case .heard: "Heard"
        case .said: "Said"
        case .look: "Quick look"
        }
    }
}
