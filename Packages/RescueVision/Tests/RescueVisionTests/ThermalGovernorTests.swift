import Foundation
import Testing
@testable import RescueVision

@Test func nominalShedsNothing() {
    let load = ThermalGovernor.load(for: .nominal)
    #expect(load == VisionLoad(uplinkIntervalScale: 1, poseFramesPerSecond: 30, arEnabled: true))
}

@Test func shedsInOrderFramesThenInferenceThenAR() {
    let nominal = ThermalGovernor.load(for: .nominal)
    let fair = ThermalGovernor.load(for: .fair)
    let serious = ThermalGovernor.load(for: .serious)
    let critical = ThermalGovernor.load(for: .critical)

    #expect(fair.uplinkIntervalScale > nominal.uplinkIntervalScale)
    #expect(fair.poseFramesPerSecond == nominal.poseFramesPerSecond)
    #expect(fair.arEnabled)

    #expect(serious.uplinkIntervalScale >= fair.uplinkIntervalScale)
    #expect(serious.poseFramesPerSecond < fair.poseFramesPerSecond)
    #expect(serious.arEnabled)

    #expect(critical.uplinkIntervalScale >= serious.uplinkIntervalScale)
    #expect(critical.poseFramesPerSecond <= serious.poseFramesPerSecond)
    #expect(!critical.arEnabled)
}

@Test func hasNothingThatCouldTouchAudio() {
    let fields = Mirror(reflecting: ThermalGovernor.load(for: .critical)).children.compactMap(\.label)
    #expect(Set(fields) == ["uplinkIntervalScale", "poseFramesPerSecond", "arEnabled"])
}
