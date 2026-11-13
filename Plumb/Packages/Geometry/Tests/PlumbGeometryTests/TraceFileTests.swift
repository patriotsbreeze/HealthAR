import Foundation
import Testing
import PlumbContracts
@testable import PlumbGeometry

@Suite struct TraceFileTests {
    let header = TraceHeader(createdAt: Date(timeIntervalSince1970: 1_794_365_340), device: "iPhone16,1",
                             note: "cushion torso, phone propped on a book / 1 m")

    /// Frames with the patch sizes a real recording uses: 24x24 depth, 16x16 reference, 32x96 luma.
    private func recording(seconds: Double) -> [TraceFrame] {
        let heights = SyntheticSession.samples(
            [SyntheticSegment(duration: seconds, ratePerMin: 110, depthMM: 50)], sampleHz: 30, noiseMM: 0)
        return SyntheticScene(tiltDownDegrees: 20, rollDegrees: 5).frames(following: heights)
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("plumb-\(UUID().uuidString).trace")
    }

    @Test func encodeThenDecodeReturnsIdenticalFrames() throws {
        let frames = recording(seconds: 2)
        let data = try TraceFile.encode(header: header, frames: frames)
        let (readHeader, readFrames) = try TraceFile.decode(data)
        #expect(readHeader == header)
        #expect(readFrames == frames)
        #expect(readFrames.count == 60)
    }

    @Test func framesWithoutPatchesRoundTripToo() throws {
        var bare = recording(seconds: 0.1)
        for index in bare.indices {
            bare[index].hands = nil
            bare[index].handsLuma = nil
            bare[index].reference = nil
            bare[index].referenceU = nil
            bare[index].referenceV = nil
            bare[index].trackingNormal = false
        }
        let data = try TraceFile.encode(header: header, frames: bare)
        #expect(try TraceFile.decode(data).1 == bare)
        #expect(!String(decoding: data, as: UTF8.self).contains("reference"))
    }

    @Test func theFileIsOneJSONObjectPerLineWithTheHeaderFirst() throws {
        let data = try TraceFile.encode(header: header, frames: recording(seconds: 0.2))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 7)
        #expect(lines[0] == #"{"createdAt":"2026-11-11T02:49:00Z","device":"iPhone16,1","note":"cushion torso, phone propped on a book / 1 m","version":1}"#)
        for line in lines {
            #expect(line.hasPrefix("{"))
            #expect(line.hasSuffix("}"))
        }
        // The big arrays are packed, not written out as lists of numbers.
        #expect(lines[1].contains(#""depthsM":""#))
        #expect(lines[1].contains(#""pixels":""#))
        #expect(!lines[1].contains(#"\/"#))
    }

    @Test func twentySecondsAtThirtyFramesASecondStaysUnderEightMegabytes() throws {
        let frames = recording(seconds: 20)
        #expect(frames.count == 600)
        #expect(frames[0].hands?.depthsM.count == 24 * 24)
        #expect(frames[0].handsLuma?.pixels.count == 32 * 96)
        let data = try TraceFile.encode(header: header, frames: frames)
        #expect(data.count < 8_000_000, "trace is \(data.count) bytes")
    }

    @Test func theStreamingWriterMakesAFileTheDecoderReads() throws {
        let frames = recording(seconds: 1)
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try TraceWriter(url: url, header: header)
        for frame in frames {
            try writer.append(frame)
        }
        #expect(writer.frameCount == frames.count)
        try writer.close()

        let written = try Data(contentsOf: url)
        let (readHeader, readFrames) = try TraceFile.decode(written)
        #expect(readHeader == header)
        #expect(readFrames == frames)
        // Streaming and one-shot encoding are the same bytes.
        #expect(written == (try TraceFile.encode(header: header, frames: frames)))
    }

    @Test func framesAreOnDiskBeforeTheWriterIsClosed() throws {
        let frames = recording(seconds: 0.2)
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TraceWriter(url: url, header: header)
        try writer.append(frames[0])
        try writer.append(frames[1])
        #expect(try TraceFile.decode(Data(contentsOf: url)).1 == Array(frames[0...1]))
        try writer.close()
    }

    @Test func appendingAfterCloseThrows() throws {
        let frames = recording(seconds: 0.1)
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TraceWriter(url: url, header: header)
        try writer.append(frames[0])
        try writer.close()
        #expect(throws: (any Error).self) { try writer.append(frames[1]) }
        #expect(writer.frameCount == 1)
        #expect(try TraceFile.decode(Data(contentsOf: url)).1 == [frames[0]])
    }

    @Test func aWriterReplacesAnOlderFileAndRefusesABadPath() throws {
        let url = scratchFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("stale contents\n".utf8).write(to: url)
        let writer = try TraceWriter(url: url, header: header)
        try writer.close()
        #expect(try TraceFile.decode(Data(contentsOf: url)).1.isEmpty)

        let nowhere = URL(fileURLWithPath: "/nonexistent-folder-\(UUID().uuidString)/x.trace")
        #expect(throws: TraceFile.Failure.cannotCreate(nowhere)) {
            _ = try TraceWriter(url: nowhere, header: header)
        }
    }

    @Test func aRecordingCutOffMidLineStillOpens() throws {
        let frames = recording(seconds: 0.2)
        let whole = try TraceFile.encode(header: header, frames: frames)
        let cut = whole.prefix(whole.count - 500)
        #expect(try TraceFile.decode(Data(cut)).1 == Array(frames.dropLast()))
    }

    @Test func damageIsReportedWithItsLineNumber() throws {
        let frames = recording(seconds: 0.2)
        var lines = String(decoding: try TraceFile.encode(header: header, frames: frames), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        lines[3] = "{\"t\":"
        let damaged = Data((lines.joined(separator: "\n") + "\n").utf8)
        #expect(throws: TraceFile.Failure.unreadableLine(4)) { try TraceFile.decode(damaged) }

        #expect(throws: TraceFile.Failure.empty) { try TraceFile.decode(Data()) }
        #expect(throws: TraceFile.Failure.unreadableLine(1)) { try TraceFile.decode(Data("not json\n".utf8)) }

        let future = TraceHeader(version: 2, createdAt: header.createdAt, device: "x", note: "")
        let newer = try TraceFile.encode(header: future, frames: [])
        #expect(throws: TraceFile.Failure.unsupportedVersion(2)) { try TraceFile.decode(newer) }
    }
}
