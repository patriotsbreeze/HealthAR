import Foundation

enum TrackingQuality: Sendable, Equatable {
    case notAvailable, limited, normal
}

struct FrameRecord: Sendable, Equatable {
    var id: UInt64
    var timestamp: TimeInterval
    var pose: CameraPose
    var tracking: TrackingQuality
}

/// Frame id to camera pose, as a fixed ring buffer. Recording never allocates, because it runs
/// inside the AR delegate call.
struct FrameLedger: Sendable {
    /// About 20 s at ARKit's 60 FPS, which outlasts a slow locate answer.
    static let defaultCapacity = 1200

    private var slots: [FrameRecord?]
    private var nextID: UInt64 = 1

    init(capacity: Int = FrameLedger.defaultCapacity) {
        slots = Array(repeating: nil, count: max(1, capacity))
    }

    @discardableResult
    mutating func record(timestamp: TimeInterval, pose: CameraPose, tracking: TrackingQuality) -> FrameRecord {
        let record = FrameRecord(id: nextID, timestamp: timestamp, pose: pose, tracking: tracking)
        slots[slot(for: nextID)] = record
        nextID += 1
        return record
    }

    func entry(for id: UInt64) -> FrameRecord? {
        guard let record = slots[slot(for: id)], record.id == id else { return nil }
        return record
    }

    var latest: FrameRecord? { nextID > 1 ? entry(for: nextID - 1) : nil }

    /// Ids keep counting, so an id from before this can never resolve to a later frame.
    mutating func removeAll() {
        for index in slots.indices { slots[index] = nil }
    }

    private func slot(for id: UInt64) -> Int { Int(id % UInt64(slots.count)) }
}
