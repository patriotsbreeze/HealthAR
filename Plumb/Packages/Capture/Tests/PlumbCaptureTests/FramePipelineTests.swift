import ARKit
import CoreVideo
import Foundation
import PlumbContracts
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

/// The per-frame pipeline driven with made-up frames: everything an ARFrame would carry, without ARKit.
struct FramePipelineTests {
    static let image = TestScene.image(luma: TestScene.stripes)
    static let metreAway = TestScene.depthMap { _, _ in 1.0 }

    func frame(_ t: TimeInterval, depth: DepthMap? = metreAway, tracking: ARCamera.TrackingState = .normal,
               camera: FrameCamera = TestScene.level, image: CVPixelBuffer = image) -> FrameInput {
        FrameInput(timestamp: 500 + t, camera: camera, tracking: tracking, depth: depth, image: image)
    }

    func pipeline(_ edit: (inout CaptureConfig) -> Void = { _ in }, depthSupported: Bool = true) -> FramePipeline {
        var config = CaptureConfig()
        edit(&config)
        return FramePipeline(config: config, method: .alongRay, depthSupported: depthSupported)
    }

    /// The world point a tap at the middle of the picture lands on when everything is a metre away.
    let middle = SIMD3<Double>(0, 0, -1)

    // MARK: Seeding by tap

    @Test func aTapSeedsTheHandsAndMeasuresAtOnce() throws {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        let outcome = line.process(frame(0), method: .alongRay)
        let hands = try #require(line.hands)
        #expect(hands.seeding == .tapped)
        #expect(simd_distance(hands.centre, middle) < 1e-6)
        let sample = try #require(outcome.sample)
        #expect(sample.t == 0 && sample.quality > 0.5)
    }

    @Test func aTapWaitsForNormalTracking() {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0, tracking: .limited(.initializing)), method: .alongRay)
        #expect(line.hands == nil)
        _ = line.process(frame(0.1), method: .alongRay)
        #expect(line.hands?.seeding == .tapped)
    }

    @Test func aTapIsDroppedWithoutDepthSupport() {
        let line = pipeline(depthSupported: false)
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0), method: .alongRay)
        #expect(line.hands == nil)
    }

    @Test func clearingForgetsTheHands() {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0), method: .alongRay)
        line.clearSeed()
        let outcome = line.process(frame(0.1), method: .alongRay)
        #expect(line.hands == nil && outcome.sample == nil)
    }

    /// Each change of the box is told on the frame that makes it, before that frame's sample, so
    /// samples of the old box and the new one can be told apart downstream.
    @Test func everyChangeOfTheBoxIsToldBeforeItsFirstSample() throws {
        let line = pipeline()
        var told: [(seeding: CaptureStatus.Seeding, samplesBefore: Int)] = []
        var samples = 0
        line.seedChanged = { told.append(($0, samples)) }
        func step(_ t: TimeInterval, tracking: ARCamera.TrackingState = .normal) -> FrameOutcome {
            let outcome = line.process(frame(t, tracking: tracking), method: .alongRay)
            if outcome.sample != nil { samples += 1 }
            return outcome
        }
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        // Not yet: the tap waits for a frame with normal tracking.
        _ = step(0, tracking: .limited(.initializing))
        #expect(told.isEmpty)
        for index in 1...3 { _ = step(Double(index) / 30) }
        #expect(samples == 3)
        line.requestTap(at: CGPoint(x: 0.4, y: 0.5))
        _ = step(4.0 / 30)
        line.clearSeed()
        let search = try #require(step(5.0 / 30).bodySearch)
        line.finishSearch(middle, generation: search.generation)
        line.restart()
        #expect(told.map(\.seeding) == [.tapped, .tapped, .unseeded, .automatic, .unseeded])
        // The first tap is told before any sample, the second after the first box's three.
        #expect(told.map(\.samplesBefore).prefix(2) == [0, 3])
    }

    // MARK: Seeding by body search

    @Test func searchesWhileUnseededAtMostOneAtATime() throws {
        let line = pipeline()
        let first = try #require(line.process(frame(0), method: .alongRay).bodySearch)
        #expect(first.image !== Self.image)
        // Still in flight a second later: no second search.
        #expect(line.process(frame(1), method: .alongRay).bodySearch == nil)
        line.finishSearch(nil, generation: first.generation)
        #expect(line.process(frame(1.1), method: .alongRay).bodySearch != nil)
    }

    @Test func searchesNoMoreThanFiveTimesASecond() throws {
        let line = pipeline()
        var started: [TimeInterval] = []
        for index in 0..<60 {
            let t = Double(index) / 60
            if let search = line.process(frame(t), method: .alongRay).bodySearch {
                started.append(t)
                line.finishSearch(nil, generation: search.generation)
            }
        }
        #expect(started.count == 5)
        #expect(zip(started, started.dropFirst()).allSatisfy { $1 - $0 >= 0.2 - 1e-9 })
    }

    @Test func aSearchResultSeedsTheHands() throws {
        let line = pipeline()
        let search = try #require(line.process(frame(0), method: .alongRay).bodySearch)
        line.finishSearch(middle, generation: search.generation)
        #expect(line.hands == HandsRegion(centre: middle, seeding: .automatic))
    }

    @Test func aStaleSearchResultCannotUndoATap() throws {
        let line = pipeline()
        let search = try #require(line.process(frame(0), method: .alongRay).bodySearch)
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0.1), method: .alongRay)
        line.finishSearch(SIMD3(0.5, 0, -1), generation: search.generation)
        #expect(line.hands?.seeding == .tapped)
    }

    @Test func aSearchFromBeforeARestartIsDropped() throws {
        // Its world point belongs to the world the restart threw away.
        let line = pipeline()
        let search = try #require(line.process(frame(0), method: .alongRay).bodySearch)
        line.restart()
        line.finishSearch(middle, generation: search.generation)
        #expect(line.hands == nil)
        let halted = pipeline()
        let other = try #require(halted.process(frame(0), method: .alongRay).bodySearch)
        halted.halt()
        halted.finishSearch(middle, generation: other.generation)
        #expect(halted.hands == nil)
    }

    @Test func searchesAgainOnlyAfterTwoSecondsWithoutAValidReading() {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0), method: .alongRay)
        // Readings keep coming: no search.
        for index in 1...90 {
            #expect(line.process(frame(Double(index) / 30), method: .alongRay).bodySearch == nil)
        }
        // The hands patch turns unreadable (nothing but low confidence): a search after two seconds.
        let unsure = TestScene.depthMap(confidence: 0) { _, _ in 1.0 }
        var searchedAt: TimeInterval?
        for index in 91...200 where searchedAt == nil {
            let t = Double(index) / 30
            if line.process(frame(t, depth: unsure), method: .alongRay).bodySearch != nil { searchedAt = t }
        }
        #expect(searchedAt.map { $0 >= 3 + 2 - 1e-9 && $0 < 3 + 2 + 0.05 } == true)
    }

    // MARK: Measuring

    @Test func traceFramesCarryTheHandsPatchesAndTheReference() throws {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0), method: .alongRay)
        let hands = try #require(line.hands)
        let first = try #require(line.measure(hands, camera: TestScene.level, depth: Self.metreAway, image: Self.image,
                                              t: 0, trackingNormal: true))
        #expect(abs(first.handsU - 960) < 1 && abs(first.handsV - 720) < 1)
        #expect(first.hands?.width == 28 && first.hands?.height == 47)
        #expect(first.handsLuma?.width == 32 && first.handsLuma?.height == 96)
        #expect(first.handsLumaU == first.handsU && first.handsLumaV == first.handsV)
        // A box 24 cm tall at a metre is 348 pixels; 96 rows of it.
        #expect(abs((first.handsLuma?.pitchPx ?? 0) - 0.24 * 1450 / 96) < 1e-6)
        #expect(first.reference == nil)

        for index in 1...20 { _ = line.process(frame(Double(index) / 30), method: .alongRay) }
        let later = try #require(line.measure(hands, camera: TestScene.level, depth: Self.metreAway, image: Self.image,
                                              t: 21.0 / 30, trackingNormal: true))
        let reference = try #require(line.reference)
        #expect(abs(reference.y - hands.centre.y) < 1e-12)
        #expect(abs(simd_distance(reference, hands.centre) - 0.25) < 1e-9)
        #expect(later.reference != nil && later.referenceU != nil)
        #expect(later.handsLuma?.pitchPx == first.handsLuma?.pitchPx)
    }

    @Test func theBrightnessGridFollowsGravityNotTheImageAxes() throws {
        // Brightness rises steadily to the right of the image and is the same down any column.
        let acrossImage = TestScene.image { u, _ in UInt8(u / 8) }
        for (roll, rowsRunAcrossU) in [(0.0, true), (Double.pi / 2, false)] {
            let camera = FrameCamera(intrinsics: TestScene.intrinsics,
                                     pose: .aimed(from: .zero, tiltDownRadians: 0, rollRadians: roll))
            let line = pipeline()
            line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
            _ = line.process(frame(0, camera: camera, image: acrossImage), method: .alongRay)
            let hands = try #require(line.hands)
            let traced = try #require(line.measure(hands, camera: camera, depth: Self.metreAway, image: acrossImage,
                                                   t: 0, trackingNormal: true))
            let luma = try #require(traced.handsLuma)
            let rows = (0..<luma.height).map { Array(luma.pixels[($0 * luma.width)..<(($0 + 1) * luma.width)]) }
            let spreadInRows = rows.map { Int($0.max()!) - Int($0.min()!) }.max()!
            let firstColumn = rows.map(\.first!), lastColumn = rows.map(\.last!)
            if rowsRunAcrossU {
                // Upright: a row runs across the image, so it spans the gradient; every row is alike.
                #expect(spreadInRows > 15 && firstColumn == Array(repeating: firstColumn[0], count: rows.count))
            } else {
                // Rolled a quarter turn: world-up runs along u, so each row sits at one u and rows climb.
                #expect(spreadInRows <= 1)
                #expect(abs(Int(firstColumn.first!) - Int(firstColumn.last!)) > 30)
                #expect(firstColumn == lastColumn)
            }
        }
    }

    @Test func theBrightnessGridKeepsItsSpacingAndFollowsTheBox() throws {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0), method: .alongRay)
        let hands = try #require(line.hands)
        let before = try #require(line.measure(hands, camera: TestScene.level, depth: Self.metreAway,
                                               image: Self.image, t: 0, trackingNormal: true))
        // The camera slides 5 cm left and 10 cm nearer: the box moves in the picture and looks bigger.
        let moved = FrameCamera(intrinsics: TestScene.intrinsics,
                                pose: .looking(from: SIMD3(-0.05, 0, -0.1), along: SIMD3(0, 0, -1)))
        let after = try #require(line.measure(hands, camera: moved, depth: Self.metreAway, image: Self.image,
                                              t: 0.1, trackingNormal: true))
        #expect(after.handsLuma?.pitchPx == before.handsLuma?.pitchPx)
        #expect(after.handsLumaU == after.handsU && after.handsLumaV == after.handsV)
        // Poses are stored as Float, so a thousandth of a pixel is as close as it gets.
        #expect(abs((after.handsLumaU ?? 0) - (960 + 1450 * 0.05 / 0.9)) < 1e-3)
    }

    @Test func theReferenceIsTheSteadierSide() throws {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        // The right half of the picture wobbles by a centimetre from frame to frame.
        for index in 0...20 {
            let wobble = Float(index % 2) * 0.01
            let depth = TestScene.depthMap { column, _ in column > 150 ? 1.0 + wobble : 1.0 }
            _ = line.process(frame(Double(index) / 30, depth: depth), method: .alongRay)
        }
        let reference = try #require(line.reference)
        #expect(reference.x < 0)
    }

    @Test func nothingIsMeasuredWithoutTracking() {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(0), method: .alongRay)
        #expect(line.process(frame(0.1, tracking: .notAvailable), method: .alongRay).sample == nil)
        let limited = line.process(frame(0.2, tracking: .limited(.excessiveMotion)), method: .alongRay)
        // Limited tracking still measures, at the estimator's capped quality.
        #expect(limited.sample.map { $0.quality <= 0.3 } == true)
    }

    @Test func switchingMethodTakesEffectOnTheNextFrame() {
        let line = pipeline()
        _ = line.process(frame(0), method: .imagePlane)
        #expect(line.estimator.method == .imagePlane)
    }

    // MARK: Status

    @Test func statusComesAboutFiveTimesASecondWithTheFrameRate() throws {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        var statuses: [CaptureStatus] = []
        for index in 0...60 {
            if let status = line.process(frame(Double(index) / 30), method: .alongRay).status { statuses.append(status) }
        }
        // Two seconds of frames. A snapshot is due once 0.2 s have passed, which rounding in the
        // frame times can push to the next frame, so 8 to 10 of them.
        #expect((8...10).contains(statuses.count))
        let last = try #require(statuses.last)
        #expect(abs(last.framesPerSecond - 30) < 1e-6)
        #expect(last.seeding == .tapped && last.depthSupported && last.tracking == "normal")
        #expect(last.handsValidFraction == 1)
        #expect(last.handsRect.map { abs($0.midX - 0.5) < 0.01 && abs($0.midY - 0.5) < 0.01 } == true)
        #expect(last.referenceRect != nil)
        #expect(last.rangeM.map { abs($0 - 1) < 0.01 } == true)
    }

    // MARK: Scene snapshots

    @Test func aSnapshotWaitsForDepthAndNormalTrackingThenCopiesOnceForAll() throws {
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        var answers: [SnapshotCopy?] = []
        _ = line.requestSnapshot { answers.append($0) }
        _ = line.requestSnapshot { answers.append($0) }
        _ = line.process(frame(0, tracking: .limited(.initializing)), method: .alongRay)
        _ = line.process(frame(0.1, depth: nil), method: .alongRay)
        #expect(answers.isEmpty)
        let raised = FrameCamera(intrinsics: TestScene.intrinsics,
                                 pose: .looking(from: SIMD3(0, 0.2, 0), along: SIMD3(0, 0, -1)))
        let copied = line.process(frame(0.2, camera: raised), method: .alongRay)
        _ = line.process(frame(0.3), method: .alongRay)
        // The same frame still seeds and measures.
        #expect(line.hands?.seeding == .tapped && copied.sample != nil)
        #expect(answers.count == 2)
        let first = try #require(answers[0]), second = try #require(answers[1])
        // One copy, of the pipeline's own, shared by both requests.
        #expect(first.image === second.image && first.image !== Self.image)
        #expect(first.depth == Self.metreAway && first.camera == raised && abs(first.timestamp - 500.2) < 1e-9)
    }

    @Test func aSnapshotRequestThatTimesOutIsAnsweredWithNil() {
        let line = pipeline()
        var answers: [SnapshotCopy?] = []
        let request = line.requestSnapshot { answers.append($0) }
        // A second of frames while tracking is still starting: nothing to copy.
        for index in 0..<30 {
            _ = line.process(frame(Double(index) / 30, tracking: .limited(.initializing)), method: .alongRay)
        }
        #expect(answers.isEmpty)
        line.expireSnapshot(request)
        #expect(answers.count == 1 && answers[0] == nil)
        // Answered once only: neither a good frame nor a second expiry answers it again.
        _ = line.process(frame(1), method: .alongRay)
        line.expireSnapshot(request)
        #expect(answers.count == 1)
    }

    @Test func aSnapshotIsRefusedAtOnceWithoutDepthSupport() {
        let line = pipeline(depthSupported: false)
        var answers: [SnapshotCopy?] = []
        _ = line.requestSnapshot { answers.append($0) }
        #expect(answers.count == 1 && answers[0] == nil)
    }

    @Test func haltingAnswersWaitingSnapshotsWithNil() {
        let line = pipeline()
        var answers: [SnapshotCopy?] = []
        _ = line.requestSnapshot { answers.append($0) }
        line.halt()
        _ = line.process(frame(0), method: .alongRay)
        #expect(answers.count == 1 && answers[0] == nil)
    }

    @Test func restartingAnswersWaitingSnapshotsWithNil() {
        // Asked of the world the restart throws away, so the new world's first frame cannot answer it.
        let line = pipeline()
        var answers: [SnapshotCopy?] = []
        _ = line.requestSnapshot { answers.append($0) }
        line.restart()
        #expect(answers.count == 1 && answers[0] == nil)
        _ = line.process(frame(0), method: .alongRay)
        #expect(answers.count == 1)
    }

    /// The time limit catches a request that is never answered. How long the answer takes is not
    /// checked against the wall clock: other tests can hold the main thread for seconds.
    @MainActor @Test(.timeLimit(.minutes(1))) func aControllerWithNoFramesAnswersNil() async {
        // Without LiDAR (the simulator) the request is refused at once; with it, no session is
        // running, so no frame comes and the timeout answers.
        var config = CaptureConfig()
        config.snapshotTimeoutS = 0.2
        let controller = CaptureController(config: config)
        let shot = await controller.snapshot()
        #expect(shot == nil)
    }

    // MARK: Recording

    @Test func recordsEveryMeasuredFrameUntilStopped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        try line.startRecording(to: url, header: TraceHeader(createdAt: Date(), device: "test", note: "pipeline"))
        #expect(line.isRecording)
        for index in 0..<10 { _ = line.process(frame(Double(index) / 30), method: .alongRay) }
        line.stopRecording()
        #expect(!line.isRecording)
        _ = line.process(frame(1), method: .alongRay)
        let (header, frames) = try TraceFile.decode(Data(contentsOf: url))
        #expect(header.note == "pipeline")
        #expect(frames.count == 10)
        #expect(frames.first?.t == 0 && frames.first?.hands != nil && frames.first?.handsLuma != nil)
    }

    @Test func restartingEndsTheRecordingAndForgetsTheHands() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = pipeline()
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        try line.startRecording(to: url, header: TraceHeader(createdAt: Date(), device: "test", note: ""))
        _ = line.process(frame(0), method: .alongRay)
        line.restart()
        #expect(!line.isRecording && line.hands == nil)
        // The clock starts again from the next frame.
        _ = line.process(frame(40), method: .alongRay)
        #expect(line.latestT == 0)
    }
}
