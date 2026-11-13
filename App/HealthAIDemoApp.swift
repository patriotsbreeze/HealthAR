import SwiftUI

@main
struct HealthAIDemoApp: App {
    @State private var boot = AppBoot.make()

    var body: some Scene {
        WindowGroup {
            RootView(boot: boot)
                .preferredColorScheme(.dark)
                // No system blue anywhere: menus, toggles and links take the text color.
                .tint(DS.Colors.textPrimary)
        }
    }
}
