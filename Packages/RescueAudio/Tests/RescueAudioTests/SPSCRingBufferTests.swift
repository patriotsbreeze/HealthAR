import Foundation
import Testing
@testable import RescueAudio

private func pop(_ ring: SPSCRingBuffer, count: Int) -> [Float] {
    var output = [Float](repeating: 0, count: count)
    let popped = output.withUnsafeMutableBufferPointer { ring.pop(into: $0.baseAddress!, count: count) }
    return Array(output.prefix(popped))
}

@Suite struct SPSCRingBufferTests {
    @Test func capacityRoundsUpToAPowerOfTwo() {
        for (requested, expected) in [(1, 1), (2, 2), (3, 4), (8, 8), (1000, 1024)] {
            let ring = SPSCRingBuffer(capacity: requested)
            defer { ring.deallocate() }
            #expect(ring.capacity == expected)
        }
    }

    @Test func keepsOrderAcrossWraparound() {
        let ring = SPSCRingBuffer(capacity: 8)
        defer { ring.deallocate() }
        var next: Float = 0
        var expected: Float = 0
        // 5 and 3 share no factor with 8, so writes start at every offset and split at the edge.
        for _ in 0..<100 {
            let batch = (0..<5).map { Float($0) + next }
            #expect(ring.push(batch) == 5)
            next += 5
            for value in pop(ring, count: 3) + pop(ring, count: 2) {
                #expect(value == expected)
                expected += 1
            }
        }
        #expect(ring.totalWritten == 500)
        #expect(ring.totalRead == 500)
    }

    @Test func overflowAcceptsOnlyWhatFits() {
        let ring = SPSCRingBuffer(capacity: 4)
        defer { ring.deallocate() }
        #expect(ring.push([1, 2, 3, 4, 5, 6]) == 4)
        #expect(ring.push([7]) == 0)
        #expect(pop(ring, count: 10) == [1, 2, 3, 4])
        #expect(pop(ring, count: 10) == [])
    }

    @Test func flushDiscardsOnTheNextPopAndKeepsLaterSamples() {
        let ring = SPSCRingBuffer(capacity: 16)
        defer { ring.deallocate() }
        ring.push([1, 2, 3])
        ring.flush()
        ring.push([4, 5])
        #expect(pop(ring, count: 10) == [4, 5])
        #expect(ring.totalRead == ring.totalWritten)
    }

    @Test func flushAfterPartialReadAndAcrossWraparound() {
        let ring = SPSCRingBuffer(capacity: 4)
        defer { ring.deallocate() }
        ring.push([1, 2, 3])
        #expect(pop(ring, count: 2) == [1, 2])
        ring.push([4, 5, 6])
        ring.flush()
        #expect(pop(ring, count: 4) == [])
        ring.push([7, 8, 9, 10])
        #expect(pop(ring, count: 4) == [7, 8, 9, 10])
    }

    @Test func flushWhenEmptyIsHarmless() {
        let ring = SPSCRingBuffer(capacity: 4)
        defer { ring.deallocate() }
        ring.flush()
        #expect(pop(ring, count: 1) == [])
        ring.push([1])
        ring.flush()
        ring.flush()
        ring.push([2])
        #expect(pop(ring, count: 4) == [2])
    }

    @Test func flushFreesSpaceOnceTheConsumerHasSeenIt() {
        let ring = SPSCRingBuffer(capacity: 4)
        defer { ring.deallocate() }
        ring.push([1, 2, 3, 4])
        ring.flush()
        #expect(ring.push([5]) == 0)
        _ = pop(ring, count: 1)
        #expect(ring.push([5, 6, 7, 8]) == 4)
        #expect(pop(ring, count: 4) == [5, 6, 7, 8])
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentProducerAndConsumerStayInOrder() async {
        let ring = SPSCRingBuffer(capacity: 256)
        defer { ring.deallocate() }
        let total = 2_000_000

        let producer = Task.detached {
            var next = 0
            var batch = [Float](repeating: 0, count: 37)
            while next < total {
                let count = min(batch.count, total - next)
                // Stays within Float's exact integer range by wrapping.
                for index in 0..<count { batch[index] = Float((next + index) % 1_000_000) }
                let pushed = batch.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: count) }
                next += pushed
                if pushed == 0 { await Task.yield() }
            }
        }
        let consumer = Task.detached { () -> Int in
            var next = 0
            var errors = 0
            var batch = [Float](repeating: 0, count: 53)
            while next < total {
                let popped = batch.withUnsafeMutableBufferPointer { ring.pop(into: $0.baseAddress!, count: 53) }
                for index in 0..<popped where batch[index] != Float((next + index) % 1_000_000) { errors += 1 }
                next += popped
                if popped == 0 { await Task.yield() }
            }
            return errors
        }
        await producer.value
        #expect(await consumer.value == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func flushFromAThirdThreadNeverBreaksOrder() async {
        let ring = SPSCRingBuffer(capacity: 64)
        defer { ring.deallocate() }
        let total = 500_000

        let producer = Task.detached {
            var next = 0
            while next < total {
                var value = Float(next % 1_000_000)
                let pushed = ring.push(&value, count: 1)
                next += pushed
                if pushed == 0 { await Task.yield() }
            }
        }
        let flusher = Task.detached {
            for _ in 0..<20_000 {
                ring.flush()
                await Task.yield()
            }
        }
        let consumer = Task.detached { () -> Bool in
            var last: Float = -1
            var increasing = true
            var buffer = [Float](repeating: 0, count: 16)
            while ring.totalRead < total {
                let popped = buffer.withUnsafeMutableBufferPointer { ring.pop(into: $0.baseAddress!, count: 16) }
                // A flush may skip samples, but what does arrive must never go backwards.
                for index in 0..<popped {
                    if buffer[index] <= last { increasing = false }
                    last = buffer[index]
                }
                if popped == 0 { await Task.yield() }
            }
            return increasing
        }
        await producer.value
        await flusher.value
        #expect(await consumer.value)
    }
}
