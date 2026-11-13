import Testing
@testable import RescueAudio

private func consume(_ ring: SPSCRingBuffer, _ count: Int) -> [Float] {
    var output = [Float](repeating: 0, count: count)
    let popped = output.withUnsafeMutableBufferPointer { ring.pop(into: $0.baseAddress!, count: count) }
    return Array(output.prefix(popped))
}

@Suite struct VoiceLaneTests {
    @Test func aPhraseFinishesOnlyWhenItsLastSampleIsConsumed() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "a", samples: [1, 2, 3])
        #expect(lane.pump().finished == [])
        #expect(lane.isBusy)
        _ = consume(ring, 2)
        #expect(lane.pump().finished == [])
        _ = consume(ring, 1)
        #expect(lane.pump().finished == ["a"])
        #expect(!lane.isBusy)
    }

    @Test func phrasesPlayAndFinishInOrder() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "a", samples: [1, 1])
        lane.enqueueClip(id: "b", samples: [2])
        lane.enqueueClip(id: "c", samples: [3, 3])
        _ = lane.pump()
        #expect(consume(ring, 16) == [1, 1], "only one phrase in the ring at a time")
        #expect(lane.pump().finished == ["a"])
        #expect(consume(ring, 16) == [2])
        #expect(lane.pump().finished == ["b"])
        #expect(consume(ring, 16) == [3, 3])
        #expect(lane.pump().finished == ["c"])
        #expect(!lane.isBusy)
    }

    @Test func droppingLeavesThePhrasePlayingAndForgetsWhatIsBehindIt() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "playing", samples: [1, 1])
        lane.enqueueClip(id: "stale", samples: [2, 2])
        lane.enqueueClip(id: "also_stale", samples: [3, 3])
        _ = lane.pump()

        lane.dropQueued(keeping: [])
        lane.enqueueClip(id: "new", samples: [4])

        var heard: [Float] = []
        var finished: [String] = []
        for _ in 0..<6 {
            finished += lane.pump().finished
            heard += consume(ring, 1)
        }
        finished += lane.pump().finished
        #expect(heard == [1, 1, 4])
        #expect(finished == ["playing", "new"], "a dropped phrase is never reported as played")
        #expect(!lane.isBusy)
    }

    @Test func droppingKeepsAPhraseThatMustBeHeardInItsPlace() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "playing", samples: [1])
        lane.enqueueClip(id: "stale", samples: [2])
        lane.enqueueClip(id: "call", samples: [3])
        lane.enqueueClip(id: "stale_too", samples: [4])
        _ = lane.pump()

        lane.dropQueued(keeping: ["call"])
        lane.enqueueClip(id: "new", samples: [5])

        var heard: [Float] = []
        for _ in 0..<6 {
            _ = lane.pump()
            heard += consume(ring, 16)
        }
        #expect(heard == [1, 3, 5])
    }

    @Test func droppingKeepsAClipPartlyInTheRing() {
        let ring = SPSCRingBuffer(capacity: 4)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        let clip = (0..<10).map(Float.init)
        lane.enqueueClip(id: "long", samples: clip)
        lane.enqueueClip(id: "stale", samples: [99])
        _ = lane.pump()

        lane.dropQueued(keeping: [])
        var heard: [Float] = []
        for _ in 0..<8 {
            _ = lane.pump()
            heard += consume(ring, 4)
        }
        #expect(heard == clip, "half a phrase would be worse than a stale one")
    }

    @Test func droppingKeepsASynthesisInProgress() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueText(id: "speaking", text: "say this")
        lane.enqueueClip(id: "stale", samples: [9])
        #expect(lane.pump().startSynthesis == "say this")

        lane.dropQueued(keeping: [])
        lane.appendToHead([1])
        lane.completeHead()
        _ = lane.pump()
        #expect(consume(ring, 16) == [1])
        #expect(lane.pump().finished == ["speaking"])
        #expect(!lane.isBusy)
    }

    @Test func droppingAnUnstartedTextNeverAsksForItsSynthesis() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "playing", samples: [1])
        lane.enqueueText(id: "stale", text: "never say this")
        _ = lane.pump()
        lane.dropQueued(keeping: [])
        _ = consume(ring, 1)
        let result = lane.pump()
        #expect(result.finished == ["playing"])
        #expect(result.startSynthesis == nil)
    }

    @Test func cuttingSilencesTheLaneAtOnceAndReportsNothing() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "keep_pushing", samples: [1, 1, 1, 1])
        lane.enqueueClip(id: "also_stale", samples: [2])
        _ = lane.pump()
        _ = consume(ring, 1)

        #expect(lane.cut() == false)
        #expect(!lane.isBusy)
        lane.enqueueClip(id: "stand_clear", samples: [7])
        let result = lane.pump()
        #expect(result.finished.isEmpty)
        #expect(consume(ring, 16) == [7], "the rest of the old phrase is gone, and the new one survives")
        #expect(lane.pump().finished == ["stand_clear"])
    }

    @Test func cuttingSaysWhenASynthesisWasAbandoned() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueText(id: "speaking", text: "say this")
        _ = lane.pump()
        #expect(lane.cut() == true)
        lane.appendToHead([9])
        lane.completeHead()
        #expect(lane.failHead() == nil, "a late report from the old synthesis finds nothing")
        #expect(ring.totalWritten == 0)
    }

    @Test func aClipBiggerThanTheRingFeedsThroughOverSeveralPumps() {
        let ring = SPSCRingBuffer(capacity: 8)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        let clip = (0..<50).map(Float.init)
        lane.enqueueClip(id: "long", samples: clip)
        lane.enqueueClip(id: "next", samples: [99])

        var heard: [Float] = []
        var finished: [String] = []
        for _ in 0..<40 {
            finished += lane.pump().finished
            heard += consume(ring, 5)
        }
        finished += lane.pump().finished
        #expect(heard == clip + [99])
        #expect(finished == ["long", "next"])
    }

    @Test func textWaitsForEverythingBeforeItThenAsksForSynthesis() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "a", samples: [1])
        lane.enqueueText(id: "b", text: "say b")
        lane.enqueueClip(id: "c", samples: [3])

        #expect(lane.pump().startSynthesis == nil)
        _ = consume(ring, 1)
        let result = lane.pump()
        #expect(result.finished == ["a"])
        #expect(result.startSynthesis == "say b")
        // Asked only once, and the clip behind it holds its place.
        #expect(lane.pump().startSynthesis == nil)
        #expect(ring.totalWritten == 1)

        lane.appendToHead([2, 2])
        _ = lane.pump()
        #expect(consume(ring, 16) == [2, 2])
        #expect(lane.pump().finished == [])
        lane.completeHead()
        #expect(lane.pump().finished == ["b"])
        #expect(consume(ring, 16) == [3])
        #expect(lane.pump().finished == ["c"])
    }

    @Test func textSpokenOutsideTheRingFinishesWithNoSamples() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueText(id: "a", text: "say a")
        #expect(lane.pump().startSynthesis == "say a")
        lane.completeHead()
        #expect(lane.pump().finished == ["a"])
        #expect(!lane.isBusy)
    }

    @Test func failedSynthesisIsReportedAndDoesNotBlockTheQueue() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueText(id: "a", text: "say a")
        lane.enqueueClip(id: "b", samples: [2])
        _ = lane.pump()
        #expect(lane.failHead() == "a")
        #expect(lane.pump().finished == [])
        #expect(consume(ring, 16) == [2])
        #expect(lane.pump().finished == ["b"])
    }

    @Test func synthesisCallsAreIgnoredWhenNothingIsSynthesizing() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        var lane = VoiceLane(ring: ring)
        lane.enqueueClip(id: "a", samples: [1])
        lane.appendToHead([9])
        lane.completeHead()
        #expect(lane.failHead() == nil)
        _ = lane.pump()
        #expect(consume(ring, 16) == [1])
    }
}
