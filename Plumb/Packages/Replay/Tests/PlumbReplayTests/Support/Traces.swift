import Foundation
import PlumbContracts
import PlumbGeometry
@testable import PlumbReplay

/// The recordings the tests share, each rendered once.
enum Traces {
    static let header = TraceHeader(createdAt: Date(timeIntervalSince1970: 1_794_000_000), device: "iPhone16,2",
                                    note: "Rig: flat plate, 50 mm travel")

    /// Pushes of 50 mm at 110 a minute, seen from 0.9 m.
    static let standard = trace(Rig())

    /// The same rig and travel on another day: a different pattern, noise and rate, still 0.9 m away.
    static let sameDistance = trace(Rig(seed: 21), pushes: Rig.pushes(ratePerMin: 104))

    /// The same travel seen from much nearer, 0.6 m.
    static let nearer = trace(Rig(rangeM: 0.6, seed: 33), pushes: Rig.pushes(ratePerMin: 116))

    static func trace(_ rig: Rig, pushes: [HeightSample] = Rig.pushes()) -> RecordedTrace {
        // A rig that renders is a test fixture that works; failing here would be a broken fixture.
        try! RecordedTrace(header: header, frames: rig.frames(following: pushes))
    }
}

/// A folder of its own for each test that touches the disk, removed when the test is done.
struct TemporaryFolder: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Writes `trace` the way the phone does, one frame at a time, and returns its path.
    func write(_ trace: RecordedTrace, as name: String) throws -> String {
        let writer = try TraceWriter(url: file(name), header: trace.header)
        for frame in trace.frames {
            try writer.append(frame)
        }
        try writer.close()
        return file(name).path
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
