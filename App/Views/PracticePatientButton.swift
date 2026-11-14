import SwiftUI

/// Lays an imaginary patient on the floor in the middle of the camera band, so the ghost rescuer has
/// someone to kneel beside when nobody can lie down. Manikin practice only: it draws, and nothing else.
struct PracticePatientButton: View {
    static let placeLabel = "Practice patient"
    static let removeLabel = "Remove practice patient"

    let placed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(placed ? Self.removeLabel : Self.placeLabel, systemImage: placed ? "xmark" : "figure.fall")
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: 44)
                .background(DS.Colors.surface.opacity(0.85), in: Capsule())
                .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityHint(placed ? "Takes the practice patient away." : "Point the camera at the floor first.")
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}
