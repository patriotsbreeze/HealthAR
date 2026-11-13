import Foundation
import PlumbContracts
import Testing
@testable import PlumbUI

@MainActor
@Suite struct BarFieldModelTests {
    static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    static let bar = StrokeBar(depthMM: 52, reached: true, trust: .locked)

    @Test func startsEmptyAndUntrusted() {
        let model = BarFieldModel()
        #expect(model.marks.isEmpty)
        #expect(model.bars.isEmpty)
        #expect(model.liveDepthMM == 0)
        #expect(model.trust == .lost)
        #expect(model.pauseSeconds == 0)
        #expect(model.lastStrokeAt == nil)
        #expect(model.targets == .adult)
    }

    @Test func keepsOnlyTheNewestEntries() {
        let model = BarFieldModel(capacity: 5)
        for depth in 0..<12 {
            model.append(StrokeBar(depthMM: Double(depth), reached: false, trust: .locked))
        }
        #expect(model.marks.count == 5)
        #expect(model.bars.map(\.depthMM) == [7, 8, 9, 10, 11])
    }

    @Test func aPushDuringAPauseFilesThePauseFirst() {
        let model = BarFieldModel()
        model.append(Self.bar)
        model.setPause(seconds: 2.5)
        model.setPause(seconds: 4)
        model.append(Self.bar)
        #expect(model.marks == [.stroke(Self.bar), .pause(seconds: 4), .stroke(Self.bar)])
        #expect(model.pauseSeconds == 0)
    }

    @Test func endingAPauseFilesItOnce() {
        let model = BarFieldModel()
        model.append(Self.bar)
        model.setPause(seconds: 6)
        model.setPause(seconds: 0)
        model.setPause(seconds: 0)
        model.append(Self.bar)
        #expect(model.marks == [.stroke(Self.bar), .pause(seconds: 6), .stroke(Self.bar)])
    }

    @Test func thePauseCountIsCarriedForwardBetweenReportsButOnlyBriefly() {
        let model = BarFieldModel()
        model.setPause(seconds: 2, at: Self.start)
        #expect(model.pauseSeconds(at: Self.start) == 2)
        #expect(abs(model.pauseSeconds(at: Self.start.addingTimeInterval(0.4)) - 2.4) < 1e-9)
        let coast = Theme.metrics.pauseCoastSeconds
        #expect(model.pauseSeconds(at: Self.start.addingTimeInterval(30)) == 2 + coast)
        // A clock that reads earlier than the report never shortens the pause.
        #expect(model.pauseSeconds(at: Self.start.addingTimeInterval(-1)) == 2)
    }

    @Test func noPauseMeansNoCount() {
        let model = BarFieldModel()
        #expect(model.pauseSeconds(at: Self.start) == 0)
    }

    @Test func theFrameCarriesHowLongAgoTheNewestPushArrived() {
        let model = BarFieldModel()
        #expect(model.frame(at: Self.start).sinceLastStroke == nil)
        model.append(Self.bar, at: Self.start)
        #expect(model.lastStrokeAt == Self.start)
        let since = model.frame(at: Self.start.addingTimeInterval(0.25)).sinceLastStroke
        #expect(abs((since ?? 0) - 0.25) < 1e-9)
        #expect(model.frame(at: Self.start.addingTimeInterval(-5)).sinceLastStroke == 0)
    }

    @Test func theFrameIsACopyOfTheModel() {
        let model = BarFieldModel(targets: Targets(depthMinMM: 45))
        model.append(Self.bar, at: Self.start)
        model.liveDepthMM = 31
        model.trust = .estimating
        let frame = model.frame(at: Self.start)
        #expect(frame.marks == [.stroke(Self.bar)])
        #expect(frame.liveDepthMM == 31)
        #expect(frame.trust == .estimating)
        #expect(frame.targets.depthMinMM == 45)
        #expect(frame.pauseSeconds == 0)
    }

    @Test func aLiveStrokeSetsDepthAndTrustTogether() {
        let model = BarFieldModel()
        model.update(LiveStroke(t: 3, currentDepthMM: 27.5, lock: .locked))
        #expect(model.liveDepthMM == 27.5)
        #expect(model.trust == .locked)
    }

    @Test func resetEmptiesEverythingButTheTargets() {
        let model = BarFieldModel(targets: Targets(depthMinMM: 45))
        model.append(Self.bar)
        model.setPause(seconds: 3)
        model.liveDepthMM = 20
        model.trust = .locked
        model.reset()
        #expect(model.marks.isEmpty)
        #expect(model.pauseSeconds == 0)
        #expect(model.liveDepthMM == 0)
        #expect(model.trust == .lost)
        #expect(model.lastStrokeAt == nil)
        #expect(model.targets.depthMinMM == 45)
    }
}
