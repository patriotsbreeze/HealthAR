import CoreGraphics
import Foundation
import RescueCore
import Synchronization
import Testing
import simd
@testable import RescueVision

private func joint(_ position: SIMD2<Double>, _ confidence: Double = 0.9) -> DetectedPerson.Joint {
    DetectedPerson.Joint(position: position, confidence: confidence)
}

/// A rescuer facing the camera, arms down along image +y. `elbowOut` bends the elbows sideways.
private func rescuer(shoulderY: Double = 0.3, wrists: SIMD2<Double> = [0.5, 0.55], elbowOut: Double = 0) -> DetectedPerson {
    let x = wrists.x
    let elbowY = (shoulderY + wrists.y) / 2
    return DetectedPerson(
        leftShoulder: joint([x - 0.06, shoulderY]),
        rightShoulder: joint([x + 0.06, shoulderY]),
        leftHip: joint([x - 0.05, shoulderY - 0.25]),
        rightHip: joint([x + 0.05, shoulderY - 0.25]),
        extras: [
            .leftElbow: joint([x - 0.04 - elbowOut, elbowY]),
            .rightElbow: joint([x + 0.04 + elbowOut, elbowY]),
            .leftWrist: joint([x - 0.015, wrists.y]),
            .rightWrist: joint([x + 0.015, wrists.y]),
        ]
    )
}

private let down = SIMD2<Double>(0, 1)

// MARK: - Form from one frame

@Test func straightArmsReadAsLocked() throws {
    let sample = try #require(CompressionSignal.sample(people: [rescuer()], gravity: down, imageAspect: 1))
    #expect(sample.armsLocked == true)
    #expect(isClose(sample.wrists, [0.5, 0.55]))
}

@Test func bentElbowsReadAsNotLocked() throws {
    let sample = try #require(CompressionSignal.sample(people: [rescuer(elbowOut: 0.08)], gravity: down, imageAspect: 1))
    #expect(sample.armsLocked == false)
}

@Test func armsNotSeenWholeSayNothingAboutLocking() throws {
    var person = rescuer()
    person.extras[.leftElbow] = nil
    person.extras[.rightElbow] = nil
    let sample = try #require(CompressionSignal.sample(people: [person], gravity: down, imageAspect: 1))
    #expect(sample.armsLocked == nil)
}

// MARK: - The cue

@Test func oneCorrectionAtATimeMostImportantFirst() {
    #expect(CompressionFeedback(perMinute: 80, armsLocked: false, handsOnChest: false).cue == .handsToCenter)
    #expect(CompressionFeedback(perMinute: 80, armsLocked: false, handsOnChest: true).cue == .lockElbows)
    #expect(CompressionFeedback(perMinute: 80, armsLocked: true, handsOnChest: true).cue == .pushFaster)
    #expect(CompressionFeedback(perMinute: 140, armsLocked: true, handsOnChest: true).cue == .pushSlower)
    #expect(CompressionFeedback(perMinute: 110, armsLocked: true, handsOnChest: true, beatOffset: 0.3).cue == .followBeat)
    #expect(CompressionFeedback(perMinute: 110, armsLocked: true, handsOnChest: true, beatOffset: -0.1).cue == nil)
}

@Test func onlyEverythingSeenAndRightMatchesTheGhost() {
    #expect(CompressionFeedback(perMinute: 110, armsLocked: true, handsOnChest: true, beatOffset: 0.05).matchesGhost)
    #expect(!CompressionFeedback(perMinute: 110, armsLocked: nil, handsOnChest: true, beatOffset: 0.05).matchesGhost)
    #expect(!CompressionFeedback(perMinute: nil, armsLocked: true, handsOnChest: true, beatOffset: nil).matchesGhost)
    #expect(!CompressionFeedback().matchesGhost)
}

// MARK: - Keeping the ghost's beat

/// Pushes at the beat's own rate, deepest `lag` seconds after each click.
private func onTheBeat(lag: Double, beatStart: Double = 0) -> (CompressionRateEstimator, end: TimeInterval) {
    var estimator = CompressionRateEstimator()
    let interval = GhostRescuer.beatInterval
    var t = 0.0
    while t < 6 {
        let push = 0.5 + 0.5 * cos(2 * .pi * (t - beatStart - lag) / interval)
        estimator.add(CompressionSample(position: 0.4 + 0.04 * push, scale: 0.5), at: t)
        t += 1.0 / 15
    }
    return (estimator, t - 1.0 / 15)
}

@Test(arguments: [0.0, 0.1, -0.1, 0.15])
func theOffsetFromTheBeatIsMeasuredInBeats(lag: Double) throws {
    let (estimator, end) = onTheBeat(lag: lag)
    let offset = try #require(estimator.beatOffset(at: end, beatStart: 0, interval: GhostRescuer.beatInterval))
    #expect(abs(offset - lag / GhostRescuer.beatInterval) < 0.05, "read \(offset) for \(lag / GhostRescuer.beatInterval)")
}

@Test func noRhythmHasNoOffset() {
    var estimator = CompressionRateEstimator()
    var t = 0.0
    while t < 6 {
        estimator.add(CompressionSample(position: 0.4, scale: 0.5), at: t)
        t += 1.0 / 15
    }
    #expect(estimator.beatOffset(at: t - 1.0 / 15, beatStart: 0, interval: GhostRescuer.beatInterval) == nil)
}

// MARK: - The coach

@Test func elbowLockingIsJudgedOverRecentFramesNotOne() {
    var coach = CompressionCoach()
    for i in 0..<12 {
        let sample = CompressionSample(position: 0.4, scale: 0.5, armsLocked: i != 5)
        coach.add(sample, at: Double(i) * 0.05, chest: nil, imageAspect: 1)
    }
    #expect(coach.feedback(at: 0.6, beatStart: nil, interval: GhostRescuer.beatInterval)?.armsLocked == true)
    for i in 12..<24 {
        coach.add(CompressionSample(position: 0.4, scale: 0.5, armsLocked: false), at: Double(i) * 0.05, chest: nil, imageAspect: 1)
    }
    #expect(coach.feedback(at: 1.2, beatStart: nil, interval: GhostRescuer.beatInterval)?.armsLocked == false)
}

@Test func handsAreOnTheChestWithinTwelveCentimetres() {
    var coach = CompressionCoach()
    // 0.5 image heights per metre, so 12 cm is 0.06.
    let chest = (point: SIMD2<Double>(0.5, 0.55), perMetre: 0.5)
    coach.add(CompressionSample(position: 0.4, scale: 0.5, wrists: [0.55, 0.55]), at: 0, chest: chest, imageAspect: 1)
    #expect(coach.feedback(at: 0, beatStart: nil, interval: 1)?.handsOnChest == true)
    coach.add(CompressionSample(position: 0.4, scale: 0.5, wrists: [0.58, 0.55]), at: 0.1, chest: chest, imageAspect: 1)
    #expect(coach.feedback(at: 0.1, beatStart: nil, interval: 1)?.handsOnChest == false)
}

@Test func nobodySeenLatelyGivesNoFeedback() {
    var coach = CompressionCoach()
    #expect(coach.feedback(at: 0, beatStart: 0, interval: 1) == nil)
    coach.add(CompressionSample(position: 0.4, scale: 0.5, armsLocked: true), at: 0, chest: nil, imageAspect: 1)
    #expect(coach.feedback(at: 0.1, beatStart: 0, interval: 1) != nil)
    #expect(coach.feedback(at: 1, beatStart: 0, interval: 1) == nil)
}

// MARK: - Pose in compressions

@Test func compressionsWantTheRescuersPoseOnlyWhileTheGhostIsUp() {
    #expect(PoseDemand.demand(target: nil, enteredAt: 0, handsGuide: nil, pinLive: false, holdsLimb: false, coaching: false, now: 10) == .none)
    #expect(PoseDemand.demand(target: nil, enteredAt: 0, handsGuide: nil, pinLive: false, holdsLimb: false, coaching: true, now: 10) == .rescuer)
    // The hands guide comes first: it is finding the patient the ghost kneels by.
    #expect(PoseDemand.demand(target: nil, enteredAt: 0, handsGuide: 9..<17, pinLive: false, holdsLimb: false, coaching: true, now: 10) == .lying(since: 9))
    #expect(PoseDemand.demand(target: .aedDevice, enteredAt: 0, handsGuide: nil, pinLive: false, holdsLimb: false, coaching: true, now: 10) == .none)
    #expect(PoseDemand.rescuer.framesPerSecond(load: ThermalGovernor.load(for: .nominal), now: 0) <= PoseDemand.rescuerCap)
}

// MARK: - In a session

private let chest = SIMD3<Float>(0, -0.8, -1.5)
private let floor = chest - SIMD3<Float>(0, GhostRescuer.chestHeight, 0)

/// Who pose sees, which the test moves as it goes.
private final class Scene: Sendable {
    private let people = Mutex<[DetectedPerson]>([])
    var now: [DetectedPerson] { people.withLock { $0 } }
    func set(_ new: [DetectedPerson]) { people.withLock { $0 = new } }
}

private func makeSession(clock: TestClock, scene: Scene) -> VisionSession {
    let session = VisionSession(
        locator: FixedLocator(box: nil),
        driver: FakeDriver(surface: { _ in floor }),
        detect: { _, _ in scene.now },
        clock: { clock.now },
        runsPump: false
    )
    session.viewportSize = portraitMapping.viewSize
    return session
}

@discardableResult
private func frame(_ session: VisionSession) async -> Bool {
    guard let captured = session.ingest(pixels: makePixels(), pose: cameraPose(), tracking: .normal, imageToView: portraitMapping.imageToView)
    else { return false }
    await session.process(captured)
    return true
}

/// Where the ghost's hands land in the test camera's image.
private func chestInImage() throws -> SIMD2<Double> {
    guard case let .inFront(point) = cameraPose().project(chest) else { throw CancellationError() }
    return point
}

@Test func nothingWatchesTheRescuerUntilTheGhostIsUp() async {
    let clock = TestClock()
    let scene = Scene()
    let session = makeSession(clock: clock, scene: scene)
    session.apply(.overlay(nil))
    session.setGhostBeat(on: true)
    #expect(await !frame(session), "no ghost placed, so no pixels in compressions")
    #expect(session.compressionFeedback() == nil)
}

@Test func aRescuerOnTheBeatWithLockedArmsMatchesTheGhost() async throws {
    let clock = TestClock()
    let scene = Scene()
    let session = makeSession(clock: clock, scene: scene)
    session.apply(.overlay(nil))
    await frame(session)
    #expect(await session.placePracticePatient())
    session.setGhostBeat(on: true)
    let beatStart = clock.now
    let hands = try chestInImage()

    var matched = false
    for _ in 0..<(6 * 15) {
        clock.advance(1.0 / 15)
        let push = GhostRescuer.push(sinceBeatStart: clock.now - beatStart, beatInterval: GhostRescuer.beatInterval)
        // Shoulders and wrists ride down together on a locked-arm push.
        scene.set([rescuer(shoulderY: hands.y - 0.25 + 0.01 * push, wrists: [hands.x, hands.y + 0.01 * push])])
        #expect(await frame(session), "the rescuer's pose is wanted while the ghost is up")
        if let feedback = session.compressionFeedback(), feedback.matchesGhost { matched = true }
    }
    let feedback = try #require(session.compressionFeedback())
    #expect(feedback.handsOnChest == true)
    #expect(feedback.armsLocked == true)
    #expect(abs((feedback.perMinute ?? 0) - 110) <= 5)
    #expect(abs(feedback.beatOffset ?? 1) < CompressionFeedback.beatTolerance)
    #expect(matched)
    #expect(session.ghostPlacement()?.tone == .matching)
}

@Test func aSlowRescuerIsToldToPushFasterAndTheGhostSaysSo() async throws {
    let clock = TestClock()
    let scene = Scene()
    let session = makeSession(clock: clock, scene: scene)
    session.apply(.overlay(nil))
    await frame(session)
    #expect(await session.placePracticePatient())
    session.setGhostBeat(on: true)
    let start = clock.now
    let hands = try chestInImage()
    for _ in 0..<(6 * 15) {
        clock.advance(1.0 / 15)
        let push = 0.5 + 0.5 * cos(2 * .pi * (clock.now - start) * 80 / 60)
        scene.set([rescuer(shoulderY: hands.y - 0.25 + 0.01 * push, wrists: [hands.x, hands.y + 0.01 * push])])
        await frame(session)
    }
    #expect(session.compressionFeedback()?.cue == .pushFaster)
    #expect(session.ghostPlacement()?.tone == .correcting)
}

@Test func theGhostsPlacementPutsItsModelOnTheChest() async throws {
    let clock = TestClock()
    let session = makeSession(clock: clock, scene: Scene())
    session.apply(.overlay(nil))
    await frame(session)
    #expect(await session.placePracticePatient())
    #expect(session.ghostPlacement() == nil, "still until the beat")
    session.setGhostBeat(on: true)
    let placement = try #require(session.ghostPlacement())
    #expect(isClose(placement.transform.columns.3.xyz, chest))
    #expect(isClose(placement.transform.columns.1.xyz, [0, 1, 0]))
    #expect(placement.practice)
    #expect(placement.tone == .neutral, "nobody seen compressing yet")
    #expect(isClose(placement.push, 1))
    session.apply(.overlay(.aedDevice))
    #expect(session.ghostPlacement() == nil)
}

@Test func theGhostModelShipsWithThePackage() {
    #expect(Bundle.module.url(forResource: "Ghost", withExtension: "usdz") != nil)
}
