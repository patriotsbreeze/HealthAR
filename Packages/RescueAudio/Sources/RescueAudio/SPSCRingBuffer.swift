import Synchronization

/// A lock-free single producer, single consumer float ring.
///
/// A plain struct of pointers, so a render callback can capture it by value and never touch a
/// reference count. The owner calls `deallocate()` once no thread can reach it.
public struct SPSCRingBuffer: @unchecked Sendable {
    public let capacity: Int

    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    // Positions only ever grow. At 48 kHz an Int lasts millions of years.
    private let writePosition: UnsafeMutablePointer<Atomic<Int>>
    private let readPosition: UnsafeMutablePointer<Atomic<Int>>
    private let flushPosition: UnsafeMutablePointer<Atomic<Int>>

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int) {
        precondition(capacity > 0)
        let rounded = capacity == 1 ? 1 : 1 << (Int.bitWidth - (capacity - 1).leadingZeroBitCount)
        self.capacity = rounded
        mask = rounded - 1
        storage = .allocate(capacity: rounded)
        storage.initialize(repeating: 0, count: rounded)
        writePosition = Self.makeCounter()
        readPosition = Self.makeCounter()
        flushPosition = Self.makeCounter()
    }

    private static func makeCounter() -> UnsafeMutablePointer<Atomic<Int>> {
        let pointer = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        pointer.initialize(to: Atomic(0))
        return pointer
    }

    public func deallocate() {
        storage.deallocate()
        for pointer in [writePosition, readPosition, flushPosition] {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
    }

    /// Total samples ever accepted by `push`.
    public var totalWritten: Int { writePosition.pointee.load(ordering: .acquiring) }
    /// Total samples the consumer has moved past, played or flushed.
    public var totalRead: Int { readPosition.pointee.load(ordering: .acquiring) }

    /// Producer only. Returns how many samples fit. The rest are dropped by the caller.
    @discardableResult
    public func push(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let write = writePosition.pointee.load(ordering: .relaxed)
        let read = readPosition.pointee.load(ordering: .acquiring)
        let accepted = min(count, capacity - (write - read))
        guard accepted > 0 else { return 0 }
        let start = write & mask
        let firstPart = min(accepted, capacity - start)
        (storage + start).update(from: source, count: firstPart)
        storage.update(from: source + firstPart, count: accepted - firstPart)
        writePosition.pointee.store(write + accepted, ordering: .releasing)
        return accepted
    }

    /// Consumer only. Returns how many samples were copied, and applies any pending flush first.
    @discardableResult
    public func pop(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        var read = readPosition.pointee.load(ordering: .relaxed)
        // Load the flush position first. It was copied from the write position, so write >= flush.
        let flush = flushPosition.pointee.load(ordering: .acquiring)
        if flush > read { read = flush }
        let write = writePosition.pointee.load(ordering: .acquiring)
        let copied = min(count, write - read)
        if copied > 0 {
            let start = read & mask
            let firstPart = min(copied, capacity - start)
            destination.update(from: storage + start, count: firstPart)
            (destination + firstPart).update(from: storage, count: copied - firstPart)
        }
        readPosition.pointee.store(read + copied, ordering: .releasing)
        return copied
    }

    /// Any thread. Discards everything pushed so far, one atomic store. The consumer applies it on
    /// its next `pop`, so in a render callback it takes effect within one IO buffer. Samples pushed
    /// after this call survive.
    public func flush() {
        let write = writePosition.pointee.load(ordering: .acquiring)
        flushPosition.pointee.store(write, ordering: .releasing)
    }
}

extension SPSCRingBuffer {
    /// Producer only. Returns how many samples fit, starting from `offset`.
    @discardableResult
    public func push(_ samples: [Float], from offset: Int = 0) -> Int {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, offset < buffer.count else { return 0 }
            return push(base + offset, count: buffer.count - offset)
        }
    }
}
