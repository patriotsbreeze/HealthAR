import Foundation
import Testing
import simd
@testable import RescueVision

/// Deterministic noise, so a failure reproduces.
private struct Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    /// Uniform in -1...1.
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// A rescuer pushing at `rate` a minute, seen by pose at `fps` with timing jitter and joint noise.
/// Amplitude and noise are in arm lengths: a 5 cm push on a 60 cm arm is about 0.08. `shape` maps phase 0..<1 to a push from 0 (up) to 1 (down).
private func feed(
    rate: Double,
    seconds: Double = 6,
    fps: Double = 15,
    amplitude: Double = 0.08,
    noise: Double = 0.01,
    drift: Double = 0,
    seed: UInt64 = 1,
    shape: (Double) -> Double = { 0.5 - 0.5 * cos(2 * .pi * $0) }
) -> (CompressionRateEstimator, end: TimeInterval) {
    var estimator = CompressionRateEstimator()
    var random = Noise(seed: seed)
    let scale = 0.5
    var t = 0.0
    var end = 0.0
    while t < seconds {
        let time = t + random.next() * 0.01
        let phase = (time * rate / 60).truncatingRemainder(dividingBy: 1)
        let position = 0.4 + drift * time + amplitude * scale * shape(phase) + noise * scale * random.next()
        estimator.add(CompressionSample(position: position, scale: scale), at: time)
        end = time
        t += 1 / fps
    }
    return (estimator, end)
}

@Test(arguments: [90.0, 110.0, 130.0])
func pacedRateReadsWithinFive(rate: Double) throws {
    let (estimator, end) = feed(rate: rate)
    let reading = try #require(estimator.estimate(at: end))
    #expect(abs(reading.perMinute - rate) <= 5, "read \(reading.perMinute) for \(rate)")
}

@Test(arguments: [10.0, 15.0, 30.0])
func rateHoldsAcrossPoseFrameRates(fps: Double) throws {
    let (estimator, end) = feed(rate: 110, fps: fps)
    let reading = try #require(estimator.estimate(at: end))
    #expect(abs(reading.perMinute - 110) <= 5)
}

@Test func aSharpPushAndSlowReleaseStillReads() throws {
    // Down in the first fifth of the cycle, back up over the rest.
    let (estimator, end) = feed(rate: 110) { $0 < 0.2 ? $0 / 0.2 : 1 - ($0 - 0.2) / 0.8 }
    let reading = try #require(estimator.estimate(at: end))
    #expect(abs(reading.perMinute - 110) <= 5)
}

@Test func aFastRateNeverReadsAsHalfItself() throws {
    let (estimator, end) = feed(rate: 150)
    let reading = try #require(estimator.estimate(at: end))
    #expect(abs(reading.perMinute - 150) <= 5)
    #expect(reading.verdict == .tooFast)
}

@Test func aHelpersSlowDriftIsIgnored() throws {
    let (estimator, end) = feed(rate: 110, drift: 0.02)
    let reading = try #require(estimator.estimate(at: end))
    #expect(abs(reading.perMinute - 110) <= 5)
}

@Test func stillnessIsSilent() {
    let (estimator, end) = feed(rate: 110, amplitude: 0)
    #expect(estimator.estimate(at: end) == nil)
}

@Test func tooLittleHistoryIsSilent() {
    let (estimator, end) = feed(rate: 110, seconds: 2)
    #expect(estimator.estimate(at: end) == nil)
}

@Test func aStaleReadingIsSilent() {
    let (estimator, end) = feed(rate: 110)
    #expect(estimator.estimate(at: end + 1) == nil)
}

@Test func aGapStartsOver() {
    var (estimator, end) = feed(rate: 110)
    estimator.add(CompressionSample(position: 0.4, scale: 0.5), at: end + 1)
    #expect(estimator.estimate(at: end + 1) == nil)
}

@Test func resetClearsHistory() {
    var (estimator, end) = feed(rate: 110)
    estimator.reset()
    #expect(estimator.estimate(at: end) == nil)
}

@Test func verdictFollowsTheGuidelineBand() {
    #expect(CompressionRate(perMinute: 95, confidence: 1).verdict == .tooSlow)
    #expect(CompressionRate(perMinute: 100, confidence: 1).verdict == .inRange)
    #expect(CompressionRate(perMinute: 120, confidence: 1).verdict == .inRange)
    #expect(CompressionRate(perMinute: 125, confidence: 1).verdict == .tooFast)
}

// MARK: - Choosing the rescuer

private func joint(_ position: SIMD2<Double>, _ confidence: Double = 0.9) -> DetectedPerson.Joint {
    DetectedPerson.Joint(position: position, confidence: confidence)
}

/// Shoulders at `shoulderY`, wrists `armLength` further along image +y. Gravity below is +y.
private func kneeling(x: Double, shoulderY: Double = 0.3, armLength: Double = 0.25, wristConfidence: Double = 0.9) -> DetectedPerson {
    DetectedPerson(
        leftShoulder: joint([x - 0.05, shoulderY]),
        rightShoulder: joint([x + 0.05, shoulderY]),
        leftHip: joint([x - 0.04, shoulderY - 0.25]),
        rightHip: joint([x + 0.04, shoulderY - 0.25]),
        extras: [
            .leftWrist: joint([x - 0.02, shoulderY + armLength], wristConfidence),
            .rightWrist: joint([x + 0.02, shoulderY + armLength], wristConfidence),
        ]
    )
}

/// Lying across the image, arms along the body.
private let patient = DetectedPerson(
    leftShoulder: joint([0.3, 0.7]),
    rightShoulder: joint([0.3, 0.8]),
    leftHip: joint([0.6, 0.7]),
    rightHip: joint([0.6, 0.8]),
    extras: [.leftWrist: joint([0.55, 0.68]), .rightWrist: joint([0.55, 0.82])]
)

private let down = SIMD2<Double>(0, 1)

@Test func theRescuerIsChosenOverThePatient() throws {
    let sample = try #require(CompressionSignal.sample(people: [patient, kneeling(x: 0.5)], gravity: down, imageAspect: 1))
    #expect(isClose(sample.scale, 0.25))
    #expect(isClose(sample.position, 0.3 + 0.25 / 2))
}

@Test func thePatientAloneGivesNoSample() {
    #expect(CompressionSignal.sample(people: [patient], gravity: down, imageAspect: 1) == nil)
}

@Test func noGravityGivesNoSample() {
    #expect(CompressionSignal.sample(people: [kneeling(x: 0.5)], gravity: nil, imageAspect: 1) == nil)
}

@Test func faintWristsGiveNoSample() {
    #expect(CompressionSignal.sample(people: [kneeling(x: 0.5, wristConfidence: 0.2)], gravity: down, imageAspect: 1) == nil)
}

@Test func theNearestOfTwoRescuersIsChosen() throws {
    let sample = try #require(CompressionSignal.sample(
        people: [kneeling(x: 0.3, armLength: 0.15), kneeling(x: 0.7, armLength: 0.3)],
        gravity: down,
        imageAspect: 1
    ))
    #expect(isClose(sample.scale, 0.3))
}

@Test func aPushMovesTheSampleAlongGravity() throws {
    let up = try #require(CompressionSignal.sample(people: [kneeling(x: 0.5, shoulderY: 0.3)], gravity: down, imageAspect: 1))
    let pushed = try #require(CompressionSignal.sample(people: [kneeling(x: 0.5, shoulderY: 0.32)], gravity: down, imageAspect: 1))
    #expect(isClose(pushed.position - up.position, 0.02))
}
