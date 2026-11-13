/// An ordered queue of things to say, feeding one ring from a serial queue.
///
/// One phrase goes into the ring at a time, as space allows, so everything behind it can still be
/// dropped when a transition makes it stale. Text waits its turn, asks to be synthesized, and its
/// audio arrives through `appendToHead`. A phrase finishes when the render thread has consumed its
/// last sample, so a report of "played" means it reached the output and not merely the queue. A
/// dropped or cut phrase is never reported, because it wasn't heard.
struct VoiceLane {
    struct PumpResult: Equatable {
        /// In order.
        var finished: [String] = []
        var startSynthesis: String?
    }

    private struct Item {
        var id: String
        var samples: [Float]
        var nextSample = 0
        var text: String?
        var isSynthesizing = false
        var isComplete: Bool

        var hasStarted: Bool { isSynthesizing || nextSample > 0 }
    }

    private struct Playing {
        var id: String
        var endPosition: Int
    }

    private let ring: SPSCRingBuffer
    private var items: [Item] = []
    private var playing: [Playing] = []

    init(ring: SPSCRingBuffer) {
        self.ring = ring
    }

    var isBusy: Bool { !items.isEmpty || !playing.isEmpty }

    mutating func enqueueClip(id: String, samples: [Float]) {
        items.append(Item(id: id, samples: samples, isComplete: true))
    }

    mutating func enqueueText(id: String, text: String) {
        items.append(Item(id: id, samples: [], text: text, isComplete: false))
    }

    mutating func appendToHead(_ samples: [Float]) {
        guard items.first?.isSynthesizing == true else { return }
        items[0].samples.append(contentsOf: samples)
    }

    mutating func completeHead() {
        guard items.first?.isSynthesizing == true else { return }
        items[0].isComplete = true
    }

    /// Synthesis failed. Returns the phrase ID so the caller can report it, since it wasn't heard.
    mutating func failHead() -> String? {
        guard items.first?.isSynthesizing == true else { return nil }
        return items.removeFirst().id
    }

    /// Forgets everything that hasn't started, except `keeping`. The one playing finishes.
    mutating func dropQueued(keeping: Set<String>) {
        let started = items.first?.hasStarted == true ? 1 : 0
        items = Array(items.prefix(started)) + items.dropFirst(started).filter { keeping.contains($0.id) }
    }

    /// Silences this lane at once. Returns true if a synthesis was abandoned, for the caller to stop.
    mutating func cut() -> Bool {
        let wasSynthesizing = items.first?.isSynthesizing == true
        ring.flush()
        items.removeAll()
        playing.removeAll()
        return wasSynthesizing
    }

    mutating func pump() -> PumpResult {
        var result = PumpResult()
        while true {
            collectFinished(into: &result)
            guard playing.isEmpty, !items.isEmpty else { break }
            if items[0].text != nil, !items[0].isSynthesizing {
                items[0].isSynthesizing = true
                result.startSynthesis = items[0].text
                break
            }
            items[0].nextSample += ring.push(items[0].samples, from: items[0].nextSample)
            guard items[0].isComplete, items[0].nextSample == items[0].samples.count else { break }
            playing.append(Playing(id: items[0].id, endPosition: ring.totalWritten))
            items.removeFirst()
        }
        return result
    }

    private mutating func collectFinished(into result: inout PumpResult) {
        let consumed = ring.totalRead
        while let first = playing.first, consumed >= first.endPosition {
            result.finished.append(first.id)
            playing.removeFirst()
        }
    }
}
