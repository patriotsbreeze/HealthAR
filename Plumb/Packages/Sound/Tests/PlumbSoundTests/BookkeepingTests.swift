import PlumbContracts
import Testing
@testable import PlumbSound

@Suite("Who is speaking, and until when")
struct SpeechTimelineTests {
    @Test("Nothing is playing at first, so any cue may start and the beat is not ducked")
    func startsEmpty() {
        let timeline = SpeechTimeline(tailFrames: 100)
        #expect(!timeline.cuePlaying(at: 0))
        #expect(timeline.duckEnd == 0)
        #expect(Cue.allCases.allSatisfy { timeline.admits($0, at: 0) })
    }

    @Test("While a cue plays only \"push now\" is let in, and never on top of itself")
    func admission() {
        var timeline = SpeechTimeline(tailFrames: 100)
        timeline.cueStarted(.faster, at: 1_000, frames: 5_000)
        #expect(timeline.cuePlaying(at: 6_099))
        #expect(!timeline.cuePlaying(at: 6_100))
        #expect(timeline.duckEnd == 6_100)
        for cue in Cue.allCases {
            #expect(timeline.admits(cue, at: 3_000) == (cue == .pushNow))
            #expect(timeline.admits(cue, at: 6_100))
        }

        timeline.cueStarted(.pushNow, at: 3_000, frames: 5_000)
        #expect(Cue.allCases.allSatisfy { !timeline.admits($0, at: 4_000) })
        #expect(timeline.duckEnd == 8_100)
    }

    @Test("Model speech queues end to end and keeps the beat ducked until it is done")
    func modelSpeech() {
        var timeline = SpeechTimeline(tailFrames: 100)
        timeline.modelQueued(at: 0, frames: 1_000)
        timeline.modelQueued(at: 200, frames: 1_000)
        #expect(timeline.duckEnd == 2_100)
        // After a gap the next chunk starts now, not where the last one ended.
        timeline.modelQueued(at: 5_000, frames: 1_000)
        #expect(timeline.duckEnd == 6_100)

        timeline.modelStopped(at: 5_500)
        #expect(timeline.duckEnd == 5_500)
        // Stopping when nothing is queued changes nothing.
        timeline.modelStopped(at: 9_000)
        #expect(timeline.duckEnd == 5_500)
    }

    @Test("A cue cuts model speech off, and the beat is ducked for the cue alone")
    func cueOverModel() {
        var timeline = SpeechTimeline(tailFrames: 100)
        timeline.modelQueued(at: 0, frames: 50_000)
        timeline.cueStarted(.good, at: 1_000, frames: 2_000)
        #expect(timeline.duckEnd == 3_100)
        // Stopping the model during the cue must not release the duck early.
        timeline.modelStopped(at: 1_500)
        #expect(timeline.duckEnd == 3_100)
    }
}

@Suite("Which sample is being heard")
struct PlayheadTests {
    let playhead = Playhead(config: BeatEngine.Config())

    @Test("With no anchor the generated sample is the answer")
    func noAnchor() {
        #expect(playhead.heardFrame(generated: 12_345, anchorSeconds: .nan, nowSeconds: 9, latencySeconds: 0.01) == 12_345)
    }

    @Test("With an anchor the heard sample follows the clock, less the output latency")
    func followsClock() {
        // Sample 0 left at t = 100 s. Half a second later, with 1/64 s of latency, 0.484375 s
        // has been heard. (The numbers are binary fractions so the arithmetic is exact.)
        let heard = playhead.heardFrame(generated: 24_512, anchorSeconds: 100, nowSeconds: 100.5,
                                        latencySeconds: 0.015_625)
        #expect(heard == 23_250)
        // It moves between blocks: 1/1024 s later it is 46 samples on, though nothing new was generated.
        let later = playhead.heardFrame(generated: 24_512, anchorSeconds: 100, nowSeconds: 100.500_976_562_5,
                                        latencySeconds: 0.015_625)
        #expect(later == 23_296)
    }

    @Test("The answer never runs ahead of what was generated, nor far behind it, nor below zero")
    func bounded() {
        #expect(playhead.heardFrame(generated: 1_000, anchorSeconds: 100, nowSeconds: 200, latencySeconds: 0) == 1_000)
        // A quarter of a second (12 000 samples) is the furthest it may trail.
        #expect(playhead.heardFrame(generated: 100_000, anchorSeconds: 100, nowSeconds: 100, latencySeconds: 0) == 88_000)
        #expect(playhead.heardFrame(generated: 512, anchorSeconds: 100, nowSeconds: 100.001, latencySeconds: 0.02) == 0)
    }

    @Test("The host clock counts seconds")
    func hostClock() {
        let clock = HostClock()
        let before = clock.now
        let after = clock.now
        #expect(after >= before)
        #expect(after - before < 1)
        #expect(clock.seconds(ticks: 0) == 0)
    }
}
