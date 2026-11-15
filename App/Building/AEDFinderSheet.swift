import SwiftUI

/// "Find AED": the building's AED tools on their own, one tap from the main screen, without opening
/// the mock dispatcher. Same section the dispatcher shows: confirm the building, take a photo to place
/// yourself, then the drone flight or the AR guide from there.
struct AEDFinderSheet: View {
    static let title = "Find the AED"
    static let subtitle = "Take a photo where you are, then fly the drone or follow the arrows to the AED."

    let coordinator: AppCoordinator
    let onClose: () -> Void
    var onOperator: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(coordinator: coordinator, onOperator: onOperator)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(Self.title)
                            .dsFont(DS.Fonts.title)
                            .accessibilityAddTraits(.isHeader)
                        Text(Self.subtitle)
                            .dsFont(DS.Fonts.label)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    BuildingBriefSection(coordinator: coordinator)
                }
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Close", action: onClose)
                    .buttonStyle(CommandButtonStyle(kind: .quiet, height: DS.Height.arrest))
                    .padding(DS.Space.m)
                    .background(DS.Colors.surface)
                    .overlay(alignment: .top) { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
            }
        }
        .background(DS.Colors.surface)
        .presentationBackground(DS.Colors.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
