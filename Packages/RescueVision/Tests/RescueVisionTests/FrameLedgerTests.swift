import Testing
@testable import RescueVision

@Test func looksUpARecordedFrameByID() throws {
    var ledger = FrameLedger(capacity: 4)
    let pose = cameraPose(transform(position: [1, 2, 3]))
    let record = ledger.record(timestamp: 5, pose: pose, tracking: .normal)
    let found = try #require(ledger.entry(for: record.id))
    #expect(found.pose == pose)
    #expect(found.pose.intrinsics == testIntrinsics)
    #expect(found.pose.imageResolution == [1920, 1440])
    #expect(found.timestamp == 5)
    #expect(ledger.latest == record)
}

@Test func oldestFramesFallOffTheEnd() {
    var ledger = FrameLedger(capacity: 3)
    let ids = (0..<5).map { ledger.record(timestamp: Double($0), pose: cameraPose(), tracking: .normal).id }
    #expect(ledger.entry(for: ids[0]) == nil)
    #expect(ledger.entry(for: ids[1]) == nil)
    #expect(ledger.entry(for: ids[2]) != nil)
    #expect(ledger.entry(for: ids[4])?.timestamp == 4)
    #expect(ledger.latest?.id == ids[4])
}

@Test func unknownIDsResolveToNothing() {
    var ledger = FrameLedger(capacity: 3)
    #expect(ledger.latest == nil)
    #expect(ledger.entry(for: 1) == nil)
    let id = ledger.record(timestamp: 0, pose: cameraPose(), tracking: .normal).id
    #expect(ledger.entry(for: id + 3) == nil)
}

@Test func idsFromBeforeAClearNeverResolve() {
    var ledger = FrameLedger(capacity: 3)
    let old = ledger.record(timestamp: 0, pose: cameraPose(), tracking: .normal).id
    ledger.removeAll()
    #expect(ledger.entry(for: old) == nil)
    #expect(ledger.latest == nil)
    let new = ledger.record(timestamp: 1, pose: cameraPose(), tracking: .normal).id
    #expect(new > old)
    #expect(ledger.entry(for: old) == nil)
}
