import Testing
import simd
@testable import RescueVision

@Test func theFirstSamplePassesThrough() {
    var filter = OneEuroFilter()
    #expect(filter.filter([0.3, 0.7], at: 5) == [0.3, 0.7])
}

/// So a still torso gives exactly the ring it always did.
@Test func aConstantInputStaysExactlyConstant() {
    var filter = OneEuroFilter()
    for tick in 0..<120 {
        #expect(filter.filter([0.123456789, 0.987654321], at: Double(tick) / 30) == [0.123456789, 0.987654321])
    }
}

@Test func jitterOnAStillPointIsReduced() {
    var filter = OneEuroFilter()
    var generator = SplitMix(seed: 7)
    var raw: [Double] = []
    var smoothed: [Double] = []
    for tick in 0..<300 {
        let noise = (Double(generator.next() % 1000) / 1000 - 0.5) * 0.01
        raw.append(noise)
        smoothed.append(filter.filter([0.5 + noise, 0.5], at: Double(tick) / 30).x - 0.5)
    }
    let variance: ([Double]) -> Double = { values in
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
    }
    let ratio = variance(Array(smoothed.dropFirst(30))) / variance(Array(raw.dropFirst(30)))
    #expect(ratio < 0.33, "kept \(ratio) of the variance")
}

@Test func fastMotionFollowsWithLittleLag() {
    var filter = OneEuroFilter()
    var still = OneEuroFilter(beta: 0)
    var last = SIMD2<Double>.zero
    var lagging = SIMD2<Double>.zero
    for tick in 0...60 {
        let time = Double(tick) / 60
        last = filter.filter([time, 0], at: time)
        lagging = still.filter([time, 0], at: time)
    }
    #expect(1 - last.x < 0.03, "lagged \(1 - last.x) image heights at 1 per second")
    #expect(1 - lagging.x > 0.1, "without beta it would trail")
}

@Test func aGapOrAnOutOfOrderSampleStartsOver() {
    var filter = OneEuroFilter()
    _ = filter.filter([0, 0], at: 0)
    _ = filter.filter([0.01, 0], at: 1.0 / 30)
    #expect(filter.filter([0.5, 0.5], at: 1.0 / 30 + OneEuroFilter.maxGap + 0.01) == [0.5, 0.5])
    #expect(filter.filter([0.2, 0.2], at: 0.1) == [0.2, 0.2])
}

@Test func resetForgets() {
    var filter = OneEuroFilter()
    _ = filter.filter([0, 0], at: 0)
    filter.reset()
    #expect(filter.filter([0.4, 0.4], at: 0.01) == [0.4, 0.4])
}

@Test func aDifferentPersonDoesNotGlideOverFromTheLast() {
    var smoother = JointSmoother()
    let first = person(center: [0.3, 0.5], axisDegrees: 0)
    let second = person(center: [0.7, 0.5], axisDegrees: 0)
    _ = smoother.smooth(first, at: 0, imageAspect: 1)
    _ = smoother.smooth(first, at: 1.0 / 30, imageAspect: 1)
    #expect(smoother.smooth(second, at: 2.0 / 30, imageAspect: 1) == second)
}

@Test func smoothingMovesEveryJointTogether() {
    var smoother = JointSmoother()
    let body = fullPerson(axisDegrees: 0)
    _ = smoother.smooth(body, at: 0, imageAspect: 1)
    let moved = body.mapPositions { _, position in position + [0.01, 0] }
    let smoothed = smoother.smooth(moved, at: 1.0 / 30, imageAspect: 1)
    for (name, position) in smoothed.allPositions {
        let before = body.allPositions[name]!.x
        #expect(position.x > before && position.x < before + 0.01, "\(name)")
    }
}

/// A fixed sequence, so the jitter test reads the same every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
