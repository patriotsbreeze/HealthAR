import Foundation
import PlumbContracts
import Testing
@testable import PlumbSignal

func probeSamples(rate: Double, depth: Double, seconds: Double = 20, hz: Double = 60, noise: Double = 2,
                  seed: UInt64 = 1, startT: Double = 0, shape: (Double) -> Double) -> [HeightSample] {
    var rng = SplitMix64(seed: seed)
    return (0..<Int(seconds * hz)).map { i in
        let local = Double(i) / hz
        let phase = local * rate / 60
        let p = phase - phase.rounded(.down)
        return HeightSample(t: startT + local, heightMM: -depth * shape(p) + noise * rng.nextGaussian())
    }
}

let triangle: (Double) -> Double = { p in p < 0.5 ? p / 0.5 : (1 - p) / 0.5 }
let triangleRest: (Double) -> Double = { p in p < 0.35 ? p / 0.35 : (p < 0.7 ? (0.7 - p) / 0.35 : 0) }
let sine: (Double) -> Double = { p in (1 - cos(2 * .pi * p)) / 2 }
let hold: (Double) -> Double = { p in
    if p < 0.25 { return (1 - cos(.pi * p / 0.25)) / 2 }
    if p < 0.5 { return 1 }
    if p < 0.75 { return (1 + cos(.pi * (p - 0.5) / 0.25)) / 2 }
    return 0
}

struct ProbeResult {
    var count: Int
    var truthCount: Int
    var medianDepth: Double
    var worstDepthErr: Double
    var within5: Double
    var rate: Double?
    var slowest: Double
}

func probe(_ samples: [HeightSample], rate: Double, depth: Double, bottomPhase: Double, startT: Double = 0,
           seconds: Double = 20) -> ProbeResult {
    let period = 60 / rate
    var truthBottoms: [Double] = []
    var k = 0
    while (Double(k) + bottomPhase) * period < seconds {
        truthBottoms.append(startT + (Double(k) + bottomPhase) * period)
        k += 1
    }
    let run = play(samples)
    var slowest = 0.0
    for r in run.reported {
        guard case .compression(let s) = r.event else { continue }
        let nearestT = truthBottoms.min { abs($0 - s.tBottom) < abs($1 - s.tBottom) } ?? 0
        slowest = max(slowest, r.at - nearestT)
    }
    let depths = run.compressions.map(\.depthMM)
    let errs = depths.map { abs($0 - depth) }
    return ProbeResult(count: run.compressions.count, truthCount: truthBottoms.count, medianDepth: median(depths),
                       worstDepthErr: errs.max() ?? .nan,
                       within5: Double(errs.filter { $0 < 5 }.count) / Double(max(1, errs.count)),
                       rate: run.analyzer.metrics.ratePerMin, slowest: slowest)
}

func show(_ name: String, _ r: ProbeResult, depth: Double) {
    let f = { (x: Double) in String(format: "%.2f", x) }
    print("PROBE \(name): count \(r.count)/\(r.truthCount) median \(f(r.medianDepth)) (true \(depth)) worst \(f(r.worstDepthErr)) within5 \(f(r.within5)) rate \(r.rate.map(f) ?? "nil") slowest \(f(r.slowest))")
}

@Suite struct Probe {
    @Test func shapes() {
        for hz in [60.0, 30.0, 15.0] {
            for (rate, depth) in [(100.0, 50.0), (120.0, 55.0), (140.0, 20.0), (80.0, 35.0), (110.0, 35.0), (140.0, 60.0)] {
                for seed in [UInt64(1), 2] {
                    let tag = "hz \(Int(hz)) \(Int(rate))/min \(Int(depth))mm seed \(seed)"
                    show("synthetic \(tag)", probe(probeSamples(rate: rate, depth: depth, hz: hz, seed: seed, shape: SyntheticSession.strokeShape), rate: rate, depth: depth, bottomPhase: 0.35), depth: depth)
                    show("triangle \(tag)", probe(probeSamples(rate: rate, depth: depth, hz: hz, seed: seed, shape: triangle), rate: rate, depth: depth, bottomPhase: 0.5), depth: depth)
                    show("triRest \(tag)", probe(probeSamples(rate: rate, depth: depth, hz: hz, seed: seed, shape: triangleRest), rate: rate, depth: depth, bottomPhase: 0.35), depth: depth)
                    show("sine \(tag)", probe(probeSamples(rate: rate, depth: depth, hz: hz, seed: seed, shape: sine), rate: rate, depth: depth, bottomPhase: 0.5), depth: depth)
                    show("hold \(tag)", probe(probeSamples(rate: rate, depth: depth, hz: hz, seed: seed, shape: hold), rate: rate, depth: depth, bottomPhase: 0.375), depth: depth)
                }
            }
        }
    }
}

extension Probe {
    /// Strokes of `depth` whose recoil stops `lean` short of the top on the strokes listed.
    static func leaning(rate: Double, depth: Double, lean: Double, leanStrokes: Set<Int>, strokes: Int,
                        hz: Double = 60, noise: Double = 2, seed: UInt64 = 1) -> [HeightSample] {
        var rng = SplitMix64(seed: seed)
        let period = 60 / rate
        return (0..<Int(Double(strokes) * period * hz)).map { i in
            let t = Double(i) / hz
            let k = Int(t / period)
            let p = t / period - Double(k)
            // top before stroke k is lowered when k is a leaning stroke (hands did not come back up after k-1)
            let topBefore = leanStrokes.contains(k) ? -lean : 0
            let topAfter = leanStrokes.contains(k + 1) ? -lean : 0
            var h: Double
            if p < 0.35 {
                h = topBefore + (-depth - topBefore) * (1 - cos(.pi * p / 0.35)) / 2
            } else if p < 0.7 {
                h = -depth + (topAfter + depth) * (1 - cos(.pi * (p - 0.35) / 0.35)) / 2
            } else {
                h = topAfter
            }
            h += noise * rng.nextGaussian()
            return HeightSample(t: t, heightMM: h)
        }
    }

    @Test func incompleteRecoil() {
        for (name, set) in [("one", Set([10])), ("three", Set([10, 11, 12])), ("every other", Set(stride(from: 5, to: 30, by: 2)))] {
            for lean in [10.0, 20.0, 30.0] {
                let run = play(Self.leaning(rate: 110, depth: 50, lean: lean, leanStrokes: set, strokes: 30))
                let d = run.compressions.map { String(format: "%.0f", $0.depthMM) }.joined(separator: " ")
                print("PROBE lean \(name) \(lean): count \(run.compressions.count)/30 depths \(d)")
            }
        }
    }

    @Test func hugeTimes() {
        for startT in [0.0, 1e5, 1e7, 3e8] {
            let segs = SyntheticSession.demo
            let s = SyntheticSession.samples(segs, noiseMM: 2, seed: 5, startT: startT)
            let run = play(s)
            let m = run.analyzer.metrics
            print("PROBE startT \(startT): count \(run.compressions.count) depth \(m.depthMM ?? -1) rate \(m.ratePerMin ?? -1) handsOn \(m.handsOnFraction ?? -1) pauses \(run.pauseStarts.map { $0 - startT }) ends \(run.pauseEnds.map { $0.duration }) locks \(run.locks)")
        }
    }

    @Test func subGateSpikes() {
        for hz in [60.0, 30.0] {
            for spike in [15.0, 20.0, 25.0, 29.0] {
                var worst = 0.0, countDiff = 0, bad = 0, total = 0
                for seed in UInt64(1)...6 {
                    let clean = SyntheticSession.samples(steady(rate: 110, depth: 50), sampleHz: hz, noiseMM: 2, seed: seed)
                    var spiked = clean
                    var up = false
                    for i in stride(from: 7, to: clean.count, by: 11) { spiked[i].heightMM += up ? spike : -spike; up.toggle() }
                    let a = play(clean), b = play(spiked)
                    countDiff += abs(a.compressions.count - b.compressions.count)
                    for c in b.compressions { let e = abs(c.depthMM - 50); worst = max(worst, e); total += 1; if e >= 5 { bad += 1 } }
                }
                print("PROBE spikes \(spike)mm hz \(hz): countDiff \(countDiff) worst \(worst) bad \(bad)/\(total)")
            }
        }
    }

    @Test func noisyHolds() {
        for hz in [60.0, 30.0] {
            for noise in [2.0, 3.0, 4.0] {
                for (rate, depth) in [(100.0, 50.0), (120.0, 40.0)] {
                    var counts: [Int] = []
                    var med: [Double] = []
                    for seed in UInt64(1)...5 {
                        let r = probe(probeSamples(rate: rate, depth: depth, hz: hz, noise: noise, seed: seed, shape: hold), rate: rate, depth: depth, bottomPhase: 0.375)
                        counts.append(r.count - r.truthCount); med.append(r.medianDepth - depth)
                    }
                    print("PROBE noisyHold hz \(hz) noise \(noise) \(rate)/\(depth): countErr \(counts) medErr \(med.map { String(format: "%.1f", $0) })")
                }
            }
        }
    }

    @Test func afterPauseAndLoss() {
        // strokes, pause, strokes: is the first stroke after the pause found with the right depth?
        for hz in [60.0, 30.0] {
            for seed in UInt64(1)...5 {
                let segs = [wholeStrokes(10, rate: 110, depth: 50), .pause(4), wholeStrokes(10, rate: 110, depth: 50)]
                let truth = SyntheticSession.truth(segs)
                let run = play(SyntheticSession.samples(segs, sampleHz: hz, noiseMM: 2, seed: seed))
                let after = run.compressions.filter { $0.tBottom > truth.bottoms[9].t + 1 }
                print("PROBE afterPause hz \(hz) seed \(seed): count \(run.compressions.count)/20 firstAfter t \(after.first?.tBottom ?? -1) (true \(truth.bottoms[10].t)) depth \(after.first?.depthMM ?? -1)")
            }
            // loss mid-run at arbitrary phases
            for cut in [6.0, 6.1, 6.2, 6.3, 6.4, 6.5] {
                let all = SyntheticSession.samples(steady(rate: 110, depth: 50, seconds: 14), sampleHz: hz, noiseMM: 2, seed: 3)
                let truth = SyntheticSession.truth(steady(rate: 110, depth: 50, seconds: 14))
                let back = cut + 1.37
                let run = play(all.filter { $0.t < cut || $0.t >= back })
                let expectedAfter = truth.bottoms.filter { $0.t > back + 0.05 }.count
                let gotAfter = run.compressions.filter { $0.tBottom > back }
                let expectedBefore = truth.bottoms.filter { $0.t < cut - 0.15 }.count
                let gotBefore = run.compressions.filter { $0.tBottom < cut }.count
                print("PROBE loss hz \(hz) cut \(cut): before \(gotBefore)/\(expectedBefore) after \(gotAfter.count)/\(expectedAfter) firstDepths \(gotAfter.prefix(3).map { String(format: "%.0f(%@)", $0.depthMM, $0.lock.rawValue) })")
            }
            // quality changes without loss
            let q = SyntheticSession.samples(steady(rate: 110, depth: 50, seconds: 14), sampleHz: hz, noiseMM: 2, seed: 3).map {
                HeightSample(t: $0.t, heightMM: $0.heightMM, quality: Int($0.t * 2) % 2 == 0 ? 0.9 : 0.1)
            }
            let run = play(q)
            print("PROBE flappingQuality hz \(hz): count \(run.compressions.count)/\(SyntheticSession.truth(steady(rate: 110, depth: 50, seconds: 14)).bottoms.count) locks \(run.locks.count)")
        }
    }

    @Test func shortGaps() {
        for gap in [0.1, 0.15, 0.2, 0.3, 0.45] {
            var worst = 0.0, bad = 0, total = 0, countErr = 0
            for seed in UInt64(1)...5 {
                let all = SyntheticSession.samples(steady(rate: 110, depth: 50, seconds: 20), noiseMM: 2, seed: seed)
                let truth = SyntheticSession.truth(steady(rate: 110, depth: 50, seconds: 20))
                // a gap every 1.7 s, so it lands at different phases
                let s = all.filter { ($0.t.truncatingRemainder(dividingBy: 1.7)) >= gap }
                let run = play(s)
                countErr += abs(run.compressions.count - truth.bottoms.count)
                for c in run.compressions where c.lock == .locked { let e = abs(c.depthMM - 50); worst = max(worst, e); total += 1; if e >= 5 { bad += 1 } }
            }
            print("PROBE gaps \(gap)s: countErr \(countErr) (5 runs x 36) lockedBad \(bad)/\(total) worst \(worst)")
        }
    }
}
