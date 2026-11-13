import Foundation
import PlumbContracts
import PlumbGeometry
import Testing
@testable import PlumbReplay

/// A rig whose plate travels exactly 50 mm at 110 a minute, replayed as the phone would measure it.
@Suite struct ReplayAccuracyTests {
    /// How many pushes the rig really made.
    private let truePushes = SyntheticSession.truth([.pause(1.5), SyntheticSegment(duration: 8, ratePerMin: 110,
                                                                                   depthMM: 50)]).bottoms.count

    /// Along the line of sight the height is the LiDAR range itself, and the plate's travel comes
    /// back almost exactly. Stated tolerance: the median within 1 mm of 50, every push within 2 mm,
    /// the rate within 1 a minute of 110, and every push counted.
    @Test func alongTheLineOfSightTheTravelAndRateComeBack() throws {
        let result = try Replay.run(Traces.standard)
        let summary = result.summary
        #expect(summary.count == truePushes)
        #expect(summary.lockedCount == summary.count)
        #expect(abs(try #require(summary.depthMedianMM) - 50) <= 1)
        #expect(result.strokes.allSatisfy { abs($0.depthMM - 50) <= 2 }, "\(result.strokes.map(\.depthMM))")
        #expect(abs(try #require(summary.ratePerMin) - 110) <= 1)
        #expect(abs(try #require(summary.rangeMedianM) - Rig().rangeM) <= 0.03)
    }

    /// The picture slide counts the same pushes at the same rate, but reads short: at 50 mm and a
    /// 40 degree tilt by about 7 percent. The phone hands the estimator the fixed pixel of the box
    /// centre, while the estimator turns the slide into millimetres as if that pixel followed the
    /// hands down. Stated tolerance: the median 0 to 6 mm short of 50, rate within 1 a minute.
    @Test func thePictureSlideCountsTheSameButReadsShort() throws {
        let result = try Replay.run(Traces.standard, settings: .init(method: .imagePlane))
        let summary = result.summary
        #expect(summary.count == truePushes)
        let depth = try #require(summary.depthMedianMM)
        #expect(depth >= 44 && depth <= 50, "\(depth)")
        #expect(abs(try #require(summary.ratePerMin) - 110) <= 1)
    }

    /// The analyzer reports a push once the hands have come back up a little from the bottom.
    @Test func everyPushIsReportedShortlyAfterItsDeepestPoint() throws {
        let summary = try Replay.run(Traces.standard).summary
        let median = try #require(summary.delayMedianS)
        #expect(median > 0 && median < 0.2)
        #expect(try #require(summary.delayLongestS) < 0.25)
    }

    /// A rig seen steadily is locked within about a second and stays locked.
    @Test func aSteadyRigIsLockedMostOfTheTime() throws {
        let share = try #require(try Replay.run(Traces.standard).summary.lockedShare)
        #expect(share > 0.8 && share <= 1)
    }

    /// The file the phone writes, one frame at a time, replays exactly as the frames it was written from.
    @Test func aTraceWrittenByTheRecorderReplaysTheSame() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "written.jsonl")
        let read = try RecordedTrace(contentsOf: URL(fileURLWithPath: path))
        #expect(read.fingerprint == Traces.standard.fingerprint)
        #expect(read.header == Traces.standard.header)
        #expect(try Replay.run(read).strokes == Replay.run(Traces.standard).strokes)
    }

    /// A phone that stops mid-write leaves a cut-off last line; the rest still replays.
    @Test func aRecordingCutOffMidLineStillReplays() throws {
        let folder = try TemporaryFolder()
        let path = try folder.write(Traces.standard, as: "cut.jsonl")
        let whole = try Data(contentsOf: URL(fileURLWithPath: path))
        let read = try RecordedTrace(data: whole.dropLast(200))
        #expect(read.frames.count == Traces.standard.frames.count - 1)
        #expect(try Replay.run(read).summary.count > 0)
    }

    /// When the phone places the hands box again, it starts its estimator afresh. The replay sees the
    /// new brightness grid, does the same, and the pushes after it are measured as well as before.
    @Test func placingTheBoxAgainStartsTheEstimatorAfresh() throws {
        let first = Rig().frames(following: Rig.pushes(seconds: 5))
        let restart = (first.last?.t ?? 0) + 1.0 / 60
        let second = Rig(boxShiftM: SIMD3(0.03, 0, 0.02))
            .frames(following: Rig.pushes(seconds: 5, startT: restart))
        let trace = try RecordedTrace(header: Traces.header, frames: first + second)
        let result = try Replay.run(trace)
        #expect(result.placementCount == 1)
        let after = result.strokes.filter { $0.t > restart }
        #expect(after.count >= 7)
        #expect(after.allSatisfy { abs($0.depthMM - 50) <= 2 }, "\(after.map(\.depthMM))")
    }

    /// Every frame of the trace goes in; frames that give a height are counted apart.
    @Test func theCountsAddUp() throws {
        let result = try Replay.run(Traces.standard)
        #expect(result.frameCount == Traces.standard.frames.count)
        #expect(result.sampleCount > result.frameCount * 9 / 10 && result.sampleCount <= result.frameCount)
        #expect(result.span == Traces.standard.frames.first!.t...Traces.standard.frames.last!.t)
        #expect(result.strokes.map(\.index) == Array(1...result.strokes.count))
    }
}
