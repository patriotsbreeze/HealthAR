import SwiftUI

/// Shown once, before any rescue. This is the only place the app asks for a permission.
struct OnboardingView: View {
    let location: LocationService
    let onFinish: () -> Void

    @State private var isRequesting = false
    @State private var didRequest = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    card(
                        symbol: "sos.circle.fill", tint: DS.Colors.critical,
                        "In a real emergency",
                        "Do not use this app. Press and hold the side button and a volume button, then slide Emergency SOS. Or call from the Phone app."
                    )
                    card(
                        symbol: "exclamationmark.triangle.fill", tint: DS.Colors.caution,
                        "This build is a simulation",
                        "It will not call 911, and it has no clinical validation. Compressions go on a manikin only, never on a person."
                    )
                    card(
                        symbol: "hand.raised.fill", tint: DS.Colors.textPrimary,
                        "Permissions",
                        "Camera and microphone let the guide see and hear the scene. Location fills in the mock caller script. Everything still works if you say no, and you won't be asked again during a rescue."
                    )
                }
                .padding(DS.Space.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: DS.Space.s) {
                Button(didRequest ? "Permissions asked" : "Allow camera, microphone, location") {
                    request()
                }
                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.arrest))
                .disabled(isRequesting || didRequest)
                Button("Start simulation", action: onFinish)
                    .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.arrest))
                    .disabled(isRequesting)
            }
            .padding(DS.Space.l)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
    }

    private func card(symbol: String, tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: DS.Height.control, height: DS.Height.control)
                .background(DS.Colors.surfaceRaised, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .dsFont(DS.Fonts.prompt)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .dsFont(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func request() {
        isRequesting = true
        Task {
            await Permissions.requestCameraAndMic()
            location.requestPermission()
            isRequesting = false
            didRequest = true
        }
    }
}
