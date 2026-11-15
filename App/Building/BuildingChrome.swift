import SwiftUI

/// The building screens in the team's camera style: the same frosted deck as the command deck and the
/// assess panel, and compact capsule buttons. Tokens only, so they move with DesignSystem.swift.
struct BuildingDeckSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The glass runs down into the home indicator's strip, corners following the display's.
                let shape = ConcentricRectangle(uniformTopCorners: .fixed(DS.Glass.deckRadius), uniformBottomCorners: .concentric(minimum: .fixed(DS.Glass.deckRadius)))
                Color.clear
                    .glassSurface(shape, tint: DS.Glass.deckTint)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .padding(.bottom, DS.Space.deckInset)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .padding(.horizontal, DS.Space.deckInset)
    }
}

extension View {
    func buildingDeck() -> some View { modifier(BuildingDeckSurface()) }
}

/// A compact capsule, as the assess panel's: white for the one thing to do, frosted for the rest.
struct DeckCapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(DS.Fonts.buttonCompact)
            .foregroundStyle(prominent ? DS.Colors.ink : DS.Colors.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: DS.Height.camera)
            .background(prominent ? AnyShapeStyle(DS.Colors.primaryFill) : AnyShapeStyle(DS.Glass.fill), in: Capsule(style: .continuous))
            .overlay {
                if !prominent { Capsule(style: .continuous).strokeBorder(DS.Glass.edge, lineWidth: 1) }
            }
            .contentShape(Capsule(style: .continuous))
            .brightness(configuration.isPressed ? (prominent ? -0.12 : 0.08) : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The round glass control the main screen floats over the camera.
struct FloatingGlassButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: DS.Height.control, height: DS.Height.control)
                .background {
                    if reduceTransparency {
                        Circle().fill(DS.Colors.surfaceRaised)
                    } else {
                        Color.clear.glassEffect(.regular.interactive(), in: Circle())
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A small live dot and a word, as on the assess panel's status.
struct StatusDot: View {
    let text: String
    var color = DS.Colors.ok

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text)
                .dsFont(DS.Fonts.meta)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
        }
    }
}
