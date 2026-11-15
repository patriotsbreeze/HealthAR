import SwiftUI

/// "Find AED": the building's AED tools on their own, one tap from the main screen, without opening
/// the mock dispatcher. Rabinowitz Hall is taken as where you are, so it goes straight to the ways
/// there: the AR guide, the drone flight, and a photo to start from where you stand.
struct AEDFinderSheet: View {
    static let title = "Find the AED"

    let coordinator: AppCoordinator
    let onClose: () -> Void
    var onOperator: (() -> Void)?
    /// Full height first: the photo, the spots to pick from and the buttons don't fit in half.
    @State private var detent = PresentationDetent.large

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(coordinator: coordinator, onOperator: onOperator)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text(Self.title)
                        .dsFont(DS.Fonts.title)
                        .accessibilityAddTraits(.isHeader)
                    BuildingBriefSection(coordinator: coordinator, aedMode: true)
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
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
