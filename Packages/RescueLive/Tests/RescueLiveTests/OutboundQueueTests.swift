import Foundation
import RescueCore
import Testing
@testable import RescueLive

@Suite struct OutboundQueueTests {
    private func drain(_ queue: inout OutboundQueue) -> [RealtimeOutbound] {
        var out: [RealtimeOutbound] = []
        while let next = queue.next() { out.append(next) }
        return out
    }

    @Test func framesAreLatestWins() {
        var queue = OutboundQueue(maxAudioBytes: 100)
        queue.enqueueFrame(Data([1]))
        queue.enqueueFrame(Data([2]))
        queue.enqueueFrame(Data([3]))
        #expect(drain(&queue) == [.frame(jpeg: Data([3]))])
    }

    @Test func audioDropsOldestPastItsLimit() {
        var queue = OutboundQueue(maxAudioBytes: 4)
        for byte in UInt8(1)...5 { queue.enqueueAudio(Data([byte, byte])) }
        #expect(drain(&queue) == [.audio(Data([4, 4])), .audio(Data([5, 5]))])
    }

    @Test func oneLargeChunkStillSends() {
        var queue = OutboundQueue(maxAudioBytes: 4)
        queue.enqueueAudio(Data(repeating: 1, count: 100))
        #expect(drain(&queue).count == 1)
    }

    @Test func audioEntriesAreCappedEvenWhenTiny() {
        var queue = OutboundQueue(maxAudioBytes: 1_000_000)
        for _ in 0..<10_000 {
            queue.enqueueAudio(Data([1]))
            queue.enqueueAudioStreamEnd()
        }
        #expect(drain(&queue).count <= 64)
    }

    @Test func controlIsBounded() {
        var queue = OutboundQueue(maxAudioBytes: 100)
        for index in 0..<1000 {
            queue.enqueueToolResponses([ToolResponse(id: "\(index)", name: "say", status: .received, reason: nil)])
        }
        let out = drain(&queue)
        #expect(out.count == 16)
        #expect(out.last == .toolResponses([ToolResponse(id: "999", name: "say", status: .received, reason: nil)]))
    }

    @Test func controlGoesFirstThenAudioInOrderThenFrame() {
        var queue = OutboundQueue(maxAudioBytes: 100)
        let response = ToolResponse(id: "a", name: "say", status: .received, reason: nil)
        queue.enqueueFrame(Data([9]))
        queue.enqueueAudio(Data([1]))
        queue.enqueueAudioStreamEnd()
        queue.enqueueAudio(Data([2]))
        queue.enqueueToolResponses([response])
        #expect(drain(&queue) == [
            .toolResponses([response]),
            .audio(Data([1])),
            .audioStreamEnd,
            .audio(Data([2])),
            .frame(jpeg: Data([9])),
        ])
    }

    @Test func aNewerBriefReplacesAQueuedOneButNotASeed() {
        var queue = OutboundQueue(maxAudioBytes: 100)
        queue.enqueueBrief(brief(version: 1), seed: true)
        queue.enqueueBrief(brief(version: 2), seed: false)
        queue.enqueueBrief(brief(version: 3), seed: false)
        #expect(drain(&queue) == [
            .stateBrief(brief(version: 1), seed: true),
            .stateBrief(brief(version: 3), seed: false),
        ])
    }

    @Test func removeAllEmptiesEveryLane() {
        var queue = OutboundQueue(maxAudioBytes: 100)
        queue.enqueueFrame(Data([1]))
        queue.enqueueAudio(Data([1]))
        queue.enqueueBrief(brief(), seed: false)
        queue.removeAll()
        #expect(queue.isEmpty)
        #expect(queue.next() == nil)
    }
}
