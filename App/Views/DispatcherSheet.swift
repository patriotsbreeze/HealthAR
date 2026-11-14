import RescueCore
import SwiftUI

/// The mock dispatcher. It places no call: a teammate's phone plays the dispatcher, and Read Aloud is
/// one-way. The engine keeps running behind it. On the arrest path its timeouts and prompts carry on
/// as normal, and an awake step waits until the sheet closes.
struct DispatcherSheet: View {
    let coordinator: AppCoordinator
    let onClose: () -> Void
    var onOperator: (() -> Void)?

    var body: some View {
        let script = coordinator.callerScript
        let location = coordinator.location.current

        VStack(spacing: 0) {
            SheetTopBar(coordinator: coordinator, onOperator: onOperator)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Mock dispatcher")
                            .dsFont(DS.Fonts.title)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        // A simulation caveat, so it reads in the strip's color.
                        Text("No call is placed. Read this to the person playing the dispatcher.")
                            .dsFont(DS.Fonts.label)
                            .foregroundStyle(DS.Colors.caution)
                    }
                    field("Location") {
                        Text(script.locationLine).dsFont(DS.Fonts.prompt)
                        if location?.address != nil {
                            if location?.confirmed == true {
                                Label("Address confirmed", systemImage: "checkmark.circle.fill")
                                    .dsFont(DS.Fonts.label)
                                    .foregroundStyle(DS.Colors.ok)
                            } else {
                                Button("Confirm address") { coordinator.location.confirmAddress() }
                                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake))
                                Text("Read Aloud leaves out the address until you confirm it.")
                                    .dsFont(DS.Fonts.caption)
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                        }
                    }
                    BuildingBriefSection(coordinator: coordinator)
                    field("Situation") {
                        Text(script.situation).dsFont(DS.Fonts.prompt)
                    }
                    field("Done so far") {
                        Text(script.actions.isEmpty ? "Nothing recorded yet" : script.actions.joined(separator: ", "))
                            .dsFont(DS.Fonts.body)
                    }
                    field("On scene") {
                        Text(script.resources.isEmpty ? "Nothing recorded yet" : script.resources.joined(separator: ", "))
                            .dsFont(DS.Fonts.body)
                    }
                }
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The fields scroll clear of the buttons, under a rule, so a heading never sits on them.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: DS.Space.betweenButtons) {
                    Button("Read Aloud") { coordinator.readAloud(script.readAloud) }
                        .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.arrest))
                        .accessibilityHint("An on-device voice says it is an AI assistant, then reads the script.")
                    Button("Close", action: onClose)
                        .buttonStyle(CommandButtonStyle(kind: .quiet, height: DS.Height.arrest))
                }
                .padding(DS.Space.m)
                .background(DS.Colors.surface)
                .overlay(alignment: .top) { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
            }
            .scrollIndicatorsFlash(onAppear: true)
        }
        .background(DS.Colors.surface)
        .presentationBackground(DS.Colors.surface)
        .presentationDetents([.medium, .large])
        // The grabber would sit on the strip's words. The sheet still drags.
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            content()
        }
    }
}
