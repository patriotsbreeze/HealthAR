import RescueCore
import SwiftUI

/// For stage use, and for the two seeded beats. Any use is marked on the strip for the rest of the
/// run, since a rehearsal only counts when this stayed closed.
struct OperatorPanel: View {
    let coordinator: AppCoordinator
    @Binding var showsHUD: Bool
    /// One tap to Sentinel for the seeded beats, now that the main screen keeps it in its menu.
    var onSentinel: () -> Void = {}

    private let columns = [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible(), spacing: DS.Space.s)]

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(coordinator: coordinator)
            Label("Operator panel active", systemImage: "exclamationmark.triangle.fill")
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.caution)
                .frame(maxWidth: .infinity, minHeight: DS.Height.alertRow)
                .background(DS.Colors.surfaceRaised)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    let failures = coordinator.engine.bundle.moduleFailures
                    if !failures.isEmpty {
                        section("Dropped at load") {
                            ForEach(failures, id: \.id) { failure in
                                Text("\(failure.id): \(failure.reason)")
                                    .dsFont(DS.Fonts.label)
                                    .foregroundStyle(DS.Colors.caution)
                            }
                            note("The arrest path runs as shipped. A dropped flow takes its button with it.")
                        }
                    }
                    section("Seeded beats") {
                        HStack(spacing: DS.Space.s) {
                            Button("Seed bad AI line") { coordinator.seedBadLine() }
                                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                                .disabled(!coordinator.canSeedBadLine)
                            // Hand placement moves on by itself in 5 s, so no scrolling to get there.
                            Button("Force hand placement") { coordinator.forceHandPlacement() }
                                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                                .disabled(coordinator.definition?.overlay == .chestCenter)
                        }
                        note("During hand placement, speaks \"\(AppCoordinator.seededLine)\" Where the AI can talk to someone awake, speaks \"\(AppCoordinator.seededAwakeLine)\" Either way it runs the real validator.")
                        HStack(spacing: DS.Space.s) {
                            Button("Seed stop report") { coordinator.seedStopReport() }
                                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                            Button("Show Sentinel", action: onSentinel)
                                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                        }
                        note("Sends a real report_finding(breathing_normally). The safety gate rejects it, and it shows on the Sentinel panel.")
                    }
                    section("Audio keywords") {
                        HStack(spacing: DS.Space.s) {
                            Button("AED talking") { coordinator.seedKeyword(.aedTalking) }
                                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                            Button("Dispatcher talking") { coordinator.seedKeyword(.dispatcherTalking) }
                                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                        }
                        note("Pauses audio for a moment and changes no state. Dispatcher talking also closes the mic for a while.")
                    }
                    section("Force state") {
                        Text("Current: \(coordinator.state.stateID)")
                            .dsFont(DS.Fonts.meta)
                            .foregroundStyle(DS.Colors.textSecondary)
                        LazyVGrid(columns: columns, spacing: DS.Space.s) {
                            ForEach(coordinator.engine.bundle.definition.states, id: \.id) { state in
                                Button(state.id.replacingOccurrences(of: "_", with: " ")) { coordinator.force(stateID: state.id) }
                                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake, font: DS.Fonts.buttonCompact))
                                    .disabled(state.id == coordinator.state.stateID || OperatorForce.refuses(engine: coordinator.engine, state: coordinator.state, target: state.id))
                            }
                        }
                    }
                    section("Run") {
                        Toggle("Show latency display", isOn: $showsHUD)
                            .dsFont(DS.Fonts.prompt)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .tint(DS.Colors.ok)
                        Button("Restart rescue") { coordinator.restartRescue() }
                            .buttonStyle(CommandButtonStyle(kind: .criticalOutline, height: DS.Height.awake))
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Colors.surface)
        .presentationBackground(DS.Colors.surface)
        .presentationDetents([.medium, .large])
        // The grabber would sit on the strip's words. The sheet still drags.
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: title)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .dsFont(DS.Fonts.caption)
            .foregroundStyle(DS.Colors.textSecondary)
    }
}
