import ARKit
import CoreVideo
import Foundation
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

/// The guides as the per-frame pipeline places them, driven with made-up frames.
struct GuidePipelineTests {
    static let image = TestScene.image(luma: TestScene.stripes)
    static let metreAway = TestScene.depthMap { _, _ in 1.0 }

    func frame(_ t: TimeInterval, depth: DepthMap? = metreAway, tracking: ARCamera.TrackingState = .normal,
               camera: FrameCamera = TestScene.level) -> FrameInput {
        FrameInput(timestamp: 100 + t, camera: camera, tracking: tracking, depth: depth, image: Self.image)
    }

    func tapped(camera: FrameCamera = TestScene.level, depth: DepthMap = metreAway) -> (FramePipeline, FrameOutcome) {
        let line = FramePipeline(config: CaptureConfig(), method: .alongRay, depthSupported: true)
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        return (line, line.process(frame(0, depth: depth, camera: camera), method: .alongRay))
    }

    @Test func cellCentresMapBackToTheirCells() {
        let cells = DepthCells(intrinsics: TestScene.intrinsics, mapWidth: 256, mapHeight: 192)
        for (column, row) in [(0, 0), (127, 95), (255, 191)] {
            let pixel = cells.pixelCentre(column: column, row: row)
            let back = cells.cell(u: pixel.u, v: pixel.v)
            #expect(back.column == column && back.row == row)
        }
    }

    // MARK: The ring

    @Test func aTapPlacesTheRingOnTheSurfaceAtOnce() throws {
        let (line, outcome) = tapped()
        let ring = try #require(outcome.guides.ring)
        #expect(ring.centre == line.hands?.centre)
        // A wall a metre ahead is far too steep for a chest: the ring lies level.
        #expect(ring.normal == RingPlacement.up)
    }

    @Test func theRingLiesOnALeaningChest() throws {
        let leaning = simd_normalize(SIMD3(0, cos(0.25), sin(0.25)))
        let depth = TestScene.planeDepth(seenBy: TestScene.propped, through: TestScene.floorAhead, normal: leaning)
        let (line, outcome) = tapped(camera: TestScene.propped, depth: depth)
        let ring = try #require(outcome.guides.ring)
        #expect(simd_distance(ring.normal, leaning) < 1e-3)
        let hands = try #require(line.hands)
        #expect(simd_distance(hands.centre, TestScene.floorAhead) < 0.01)
    }

    @Test func aBodySearchSeedGetsItsRingOnTheNextFrameWithDepth() throws {
        let line = FramePipeline(config: CaptureConfig(), method: .alongRay, depthSupported: true)
        let search = try #require(line.process(frame(0), method: .alongRay).bodySearch)
        line.finishSearch(SIMD3(0, 0, -1), generation: search.generation)
        #expect(line.process(frame(0.1, depth: nil), method: .alongRay).guides.ring == nil)
        #expect(line.process(frame(0.2), method: .alongRay).guides.ring?.centre == SIMD3(0, 0, -1))
    }

    @Test func clearingTheHandsClearsTheGuides() {
        let (line, _) = tapped()
        line.clearSeed()
        #expect(line.process(frame(0.1), method: .alongRay).guides == .none)
    }

    // MARK: The line

    @Test func theLineAppearsOnceTheTopOfTheStrokeIsKnown() throws {
        let (line, first) = tapped()
        #expect(first.guides.line == nil)
        var outcome = first
        for index in 1...15 { outcome = line.process(frame(Double(index) / 60), method: .alongRay) }
        let placed = try #require(outcome.guides.line)
        // A level camera: the hands' top is at the box centre, height 0, and the target 5 cm below it.
        let target = SIMD3<Double>(0, -0.05, -1)
        #expect(abs(simd_distance(placed.centre, target) - 0.04) < 1e-6)
        #expect(simd_distance(simd_normalize(SIMD3<Double>.zero - target), simd_normalize(placed.centre - target)) < 1e-6)
        #expect(simd_distance(placed.along, SIMD3(1, 0, 0)) < 1e-6)
    }

    @Test func aNewTapStartsTheTopAfresh() {
        let (line, _) = tapped()
        for index in 1...15 { _ = line.process(frame(Double(index) / 60), method: .alongRay) }
        line.requestTap(at: CGPoint(x: 0.4, y: 0.5))
        let outcome = line.process(frame(16.0 / 60), method: .alongRay)
        #expect(outcome.guides.ring != nil && outcome.guides.line == nil)
    }

    /// Heights seen before pushing starts are hands hovering or coming down, not the top of a
    /// stroke. Each start, and each start again after a pause, forgets them, and the line waits for
    /// tops seen since. Pushing going on, or stopping, forgets nothing.
    @Test func startingToPushStartsTheTopAfresh() {
        let (line, _) = tapped()
        var t = 0.0
        func frames(_ count: Int) -> FrameOutcome {
            var outcome = FrameOutcome()
            for _ in 0..<count {
                t += 1.0 / 60
                outcome = line.process(frame(t), method: .alongRay)
            }
            return outcome
        }
        #expect(frames(15).guides.line != nil)
        line.setCompressing(true)
        #expect(frames(1).guides.line == nil)
        #expect(frames(15).guides.line != nil)
        line.setCompressing(true)
        #expect(frames(1).guides.line != nil)
        line.setCompressing(false)
        #expect(frames(1).guides.line != nil)
        line.setCompressing(true)
        #expect(frames(1).guides.line == nil)
        #expect(frames(15).guides.line != nil)
    }

    @Test func noLineWithoutTrackingButTheRingStays() {
        let (line, _) = tapped()
        for index in 1...15 { _ = line.process(frame(Double(index) / 60), method: .alongRay) }
        let lost = line.process(frame(16.0 / 60, tracking: .notAvailable), method: .alongRay)
        #expect(lost.guides.line == nil && lost.guides.ring != nil)
    }

    @Test func unreadableHandsLetTheLineFade() {
        let (line, _) = tapped()
        for index in 1...15 { _ = line.process(frame(Double(index) / 60), method: .alongRay) }
        let unsure = TestScene.depthMap(confidence: 0) { _, _ in 1.0 }
        var outcome = FrameOutcome()
        for index in 16...130 { outcome = line.process(frame(Double(index) / 60, depth: unsure), method: .alongRay) }
        #expect(outcome.guides.line == nil)
    }

    // MARK: Seeding by taps alone

    @Test func withoutAutomaticSeedingNoSearchStartsAndNoneLands() throws {
        let line = FramePipeline(config: CaptureConfig(), method: .alongRay, depthSupported: true)
        let search = try #require(line.process(frame(0), method: .alongRay).bodySearch)
        line.automaticSeeding = false
        // The search still running when it was turned off lands nowhere.
        line.finishSearch(SIMD3(0, 0, -1), generation: search.generation)
        #expect(line.hands == nil)
        for index in 1...30 { #expect(line.process(frame(Double(index) / 30), method: .alongRay).bodySearch == nil) }
        // Taps still seed.
        line.requestTap(at: CGPoint(x: 0.5, y: 0.5))
        _ = line.process(frame(1.1), method: .alongRay)
        #expect(line.hands?.seeding == .tapped)
    }

    @MainActor @Test func theControllerSeedsAutomaticallyUntilToldNot() {
        let controller = CaptureController()
        #expect(controller.automaticSeeding)
        controller.automaticSeeding = false
        #expect(!controller.automaticSeeding)
        #expect(controller.guidePlacement == .none)
    }

    // MARK: Occlusion

    @Test func peopleOcclusionOnlyAlongsideTheDepthMap() {
        let everything: (ARConfiguration.FrameSemantics) -> Bool = { _ in true }
        #expect(CaptureController.frameSemantics(peopleOcclusion: true, supports: everything)
            == [.sceneDepth, .personSegmentationWithDepth])
        #expect(CaptureController.frameSemantics(peopleOcclusion: false, supports: everything) == [.sceneDepth])
        let depthOnly: (ARConfiguration.FrameSemantics) -> Bool = { $0 == .sceneDepth }
        #expect(CaptureController.frameSemantics(peopleOcclusion: true, supports: depthOnly) == [.sceneDepth])
        let peopleOnly: (ARConfiguration.FrameSemantics) -> Bool = { !$0.contains(.sceneDepth) }
        #expect(CaptureController.frameSemantics(peopleOcclusion: true, supports: peopleOnly) == [])
        #expect(CaptureController.frameSemantics(peopleOcclusion: true, supports: { _ in false }) == [])
    }
}
