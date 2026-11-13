import Testing
@testable import RescueVision

private let chest = TorsoTarget(center: [0.5, 0.5], radius: 0.05)

private func keypoints(at time: Double) -> TimedTorsoTarget {
    TimedTorsoTarget(target: chest, frameID: 1, capturedAt: time)
}

@Test func hiddenUntilTheStateIsEntered() {
    let ring = RingController()
    #expect(ring.output(latest: keypoints(at: 10), at: 10) == .hidden)
    #expect(!ring.isShowing(at: 10))
}

@Test func showsAFreshTorsoOnceEntered() {
    var ring = RingController()
    ring.enterState(at: 10)
    #expect(ring.output(latest: keypoints(at: 10.1), at: 10.15) == .show(chest))
}

@Test func hiddenWithNoTorso() {
    var ring = RingController()
    ring.enterState(at: 10)
    #expect(ring.output(latest: nil, at: 10.1) == .hidden)
}

/// place_hands used to show it for 3 s. The core times that step out at 5 s, so it now lasts the step.
@Test func showsForTheWholeStep() {
    var ring = RingController()
    ring.enterState(at: 10)
    #expect(ring.output(latest: keypoints(at: 12.9), at: 12.999) == .show(chest))
    #expect(ring.output(latest: keypoints(at: 12.95), at: 13) == .show(chest))
    #expect(ring.output(latest: keypoints(at: 19.9), at: 20) == .show(chest))
    #expect(ring.isShowing(at: 300))
}

@Test func lateAcquisitionStillShows() {
    var ring = RingController()
    ring.enterState(at: 10)
    #expect(ring.output(latest: nil, at: 11.5) == .hidden)
    #expect(ring.output(latest: keypoints(at: 11.9), at: 12) == .show(chest))
}

@Test func keypointsOver200MillisecondsHideIt() {
    var ring = RingController()
    ring.enterState(at: 10)
    #expect(ring.output(latest: keypoints(at: 11), at: 11.2) == .show(chest))
    #expect(ring.output(latest: keypoints(at: 11), at: 11.201) == .hidden)
}

@Test func keypointsFromTheFutureHideIt() {
    var ring = RingController()
    ring.enterState(at: 10)
    #expect(ring.output(latest: keypoints(at: 11.5), at: 11) == .hidden)
}

@Test func leavingHidesItAndReenteringShowsItAgain() {
    var ring = RingController()
    ring.enterState(at: 10)
    ring.leaveState()
    #expect(ring.output(latest: keypoints(at: 10.1), at: 10.2) == .hidden)
    ring.enterState(at: 50)
    #expect(ring.output(latest: keypoints(at: 52.9), at: 52.95) == .show(chest))
    #expect(ring.output(latest: keypoints(at: 53), at: 53.05) == .show(chest))
}

/// The hands guide in compressions has an end, and nothing shows past it however fresh the torso.
@Test func aGuideWithAnEndHidesAtTheEnd() {
    var ring = RingController()
    ring.enterState(at: 10, until: 18)
    #expect(!ring.isShowing(at: 9.99))
    #expect(ring.output(latest: keypoints(at: 17.9), at: 17.99) == .show(chest))
    #expect(ring.output(latest: keypoints(at: 17.95), at: 18) == .hidden)
    #expect(!ring.isShowing(at: 18))
}
