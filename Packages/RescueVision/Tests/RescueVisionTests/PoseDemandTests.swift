import Foundation
import RescueCore
import Testing
@testable import RescueVision

private func demand(
    _ target: OverlayTarget?,
    handsGuide: Range<TimeInterval>? = nil,
    pinLive: Bool = false,
    holdsLimb: Bool = false,
    now: TimeInterval = 20
) -> PoseDemand {
    PoseDemand.demand(target: target, enteredAt: 10, handsGuide: handsGuide, pinLive: pinLive, holdsLimb: holdsLimb, now: now)
}

@Test func theChestAndPadStepsWantTheLyingPatientForTheWholeStep() {
    #expect(demand(.chestCenter) == .lying(since: 10))
    #expect(demand(.padZones) == .lying(since: 10))
    #expect(demand(.chestCenter, now: 500) == .lying(since: 10))
}

@Test func aLimbStepWantsPoseOnlyWithAPinOrAHeldLimb() {
    #expect(demand(.injurySite) == .none, "no tap yet, no pixels")
    #expect(demand(.injurySite, pinLive: true) == .nearPin)
    #expect(demand(.injurySite, holdsLimb: true) == .nearPin, "a locked limb outlasts the pin")
}

@Test func noOtherStepWantsPose() {
    #expect(demand(.aedDevice) == .none)
    #expect(demand(nil) == .none)
    #expect(demand(nil, pinLive: true, holdsLimb: true) == .none)
    #expect(demand(.aedDevice, handsGuide: 0..<100) == .none, "the guide is only for a step with no mark")
}

@Test func theHandsGuideWantsTheLyingPatientInsideItsWindowOnly() {
    let window: Range<TimeInterval> = 30..<38
    #expect(demand(nil, handsGuide: window, now: 29.99) == .none)
    #expect(demand(nil, handsGuide: window, now: 30) == .lying(since: 30))
    #expect(demand(nil, handsGuide: window, now: 37.99) == .lying(since: 30))
    #expect(demand(nil, handsGuide: window, now: 38) == .none)
    #expect(demand(nil, handsGuide: window, now: 90) == .none)
}

@Test func lyingRunsFullRateToLockThenCaps() {
    let nominal = ThermalGovernor.load(for: .nominal)
    let lying = PoseDemand.lying(since: 10)
    #expect(lying.framesPerSecond(load: nominal, now: 10) == 30)
    #expect(lying.framesPerSecond(load: nominal, now: 12.99) == 30)
    #expect(lying.framesPerSecond(load: nominal, now: 13) == 15)
    #expect(lying.framesPerSecond(load: ThermalGovernor.load(for: .serious), now: 10) == 15, "heat still wins")
}

@Test func nearAPinRunsAtTenAtMost() {
    #expect(PoseDemand.nearPin.framesPerSecond(load: ThermalGovernor.load(for: .nominal), now: 0) == 10)
    #expect(PoseDemand.nearPin.framesPerSecond(load: VisionLoad(uplinkIntervalScale: 1, poseFramesPerSecond: 5, arEnabled: true), now: 0) == 5)
    #expect(PoseDemand.none.framesPerSecond(load: ThermalGovernor.load(for: .nominal), now: 0) == 0)
}
