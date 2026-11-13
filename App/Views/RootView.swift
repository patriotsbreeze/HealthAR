import SwiftUI

struct RootView: View {
    let boot: AppBoot
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        switch boot {
        case .underTest:
            DS.Colors.canvas.ignoresSafeArea()
        case .protocolUnavailable:
            FallbackCard()
        case let .ready(coordinator):
            #if DEBUG
            if StagedLaunch.showsFallback {
                FallbackCard()
            } else {
                rescue(coordinator)
            }
            #else
            rescue(coordinator)
            #endif
        }
    }

    @ViewBuilder private func rescue(_ coordinator: AppCoordinator) -> some View {
        if onboardingDone || skipsOnboarding {
            MainScreen(coordinator: coordinator)
                .onAppear {
                    coordinator.beginRescue()
                    #if DEBUG
                    StagedLaunch.applyStartState(to: coordinator)
                    #endif
                }
        } else {
            OnboardingView(location: coordinator.location) { onboardingDone = true }
        }
    }

    private var skipsOnboarding: Bool {
        #if DEBUG
        StagedLaunch.skipsOnboarding
        #else
        false
        #endif
    }
}

/// Everything that can't work has already failed by the time this shows, so it depends on nothing.
struct FallbackCard: View {
    var body: some View {
        VStack(spacing: 0) {
            SimulationStrip()
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Guide unavailable")
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.caution)
                Text("Call emergency services now.")
                    .dsFont(DS.Fonts.confirm)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Follow the dispatcher's instructions.")
                    .dsFont(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("To call from a locked phone, press and hold the side button and a volume button, then slide Emergency SOS.")
                    .dsFont(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
    }
}
