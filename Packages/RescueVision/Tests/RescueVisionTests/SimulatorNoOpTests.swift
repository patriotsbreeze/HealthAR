#if os(iOS) && targetEnvironment(simulator)
import RescueCore
import SwiftUI
import Testing
@testable import RescueVision

@Test func simulatorHasNoARAndEverythingNoOps() async {
    let session = VisionSession(locator: FixedLocator(box: nil))
    #expect(!session.isARSupported)
    #expect(session.status == .unsupported)
    session.start()
    session.apply(.overlay(.chestCenter))
    session.apply(.locate(.aed))
    session.beginFrameBurst()
    #expect(session.overlay() == .empty)
    #expect(session.displayMapping == nil)
    session.stop()
    #expect(session.status == .unsupported)
}

@MainActor
@Test func cameraViewIsAPlainViewInTheSimulator() async {
    let session = VisionSession(locator: FixedLocator(box: nil))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    window.rootViewController = UIHostingController(rootView: ARCameraView(session: session))
    window.isHidden = false
    window.layoutIfNeeded()
    for _ in 0..<500 where session.viewportSize.width == 0 {
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(session.viewportSize.width == 393)
    #expect(session.viewportSize.height > 0)
    #expect(session.overlay() == .empty)
    window.isHidden = true
}
#endif
