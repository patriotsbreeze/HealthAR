import SwiftUI

/// Entry point. One window, landscape, the rescue screen first: there is no onboarding.
@main
struct PlumbApp: App {
    @State private var rescue = RescueController(feed: FeedChoice.make())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(rescue: rescue)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
                .statusBarHidden()
                .task { await rescue.begin() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { rescue.leftForeground() }
                }
        }
    }
}
