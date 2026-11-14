import Foundation
@testable import HealthAISim
import Testing

/// Made up for these tests: a spot chain a → b → c → AED, plus a loop and a gap.
private let drone = """
{"schema": "drone.v1", "building": "mp:FIXTURE", "entrance_pano": "a",
 "targets": {"staged_1": {"text": "AED by the stairs", "staged": true, "frames": {
   "a": {"next": "b", "img": "drone/staged_1/a.jpg", "room": "Hallway", "floor": "Floor 1"},
   "b": {"next": "c", "img": "drone/staged_1/b.jpg", "room": "", "floor": "Floor 1"},
   "c": {"next": null, "img": "drone/staged_1/c.jpg", "room": "Lobby", "floor": ""},
   "x": {"next": "y", "img": "drone/staged_1/x.jpg", "room": "", "floor": ""},
   "y": {"next": "x", "img": "drone/staged_1/y.jpg", "room": "", "floor": ""},
   "g": {"next": "missing", "img": "drone/staged_1/g.jpg", "room": "", "floor": ""},
   "h": {"next": "a", "img": "", "room": "", "floor": ""}}}}}
"""

@MainActor
@Suite struct DroneFlightTests {
    let data = DroneData.decode(Data(drone.utf8))
    private let always: (DroneData.Frame) -> Bool = { _ in true }

    @Test func itDecodesAndKeepsItsIDs() throws {
        let data = try #require(data)
        #expect(data.building == "mp:FIXTURE")
        #expect(data.entrancePano == "a")
        let target = try #require(data.targets["staged_1"])
        #expect(target.staged)
        // A frame with no picture is left out.
        #expect(target.frames["h"] == nil)
        #expect(target.frames.count == 6)
    }

    @Test func aChainFliesToTheEnd() throws {
        let flight = try #require(data?.flight(to: "staged_1", from: "a", hasImage: always))
        #expect(flight.map(\.pano) == ["a", "b", "c"])
        #expect(try #require(data?.flight(to: "staged_1", from: "b", hasImage: always)).map(\.pano) == ["b", "c"])
    }

    @Test func aLoopStopsAtTheLastNewFrame() throws {
        let flight = try #require(data?.flight(to: "staged_1", from: "x", hasImage: always))
        #expect(flight.map(\.pano) == ["x", "y"])
    }

    @Test func aMissingFrameStopsAtTheLastGoodOne() throws {
        #expect(try #require(data?.flight(to: "staged_1", from: "g", hasImage: always)).map(\.pano) == ["g"])
        // A picture missing from the bundle counts as a missing frame.
        let noC = try #require(data?.flight(to: "staged_1", from: "a", hasImage: { $0.pano != "c" }))
        #expect(noC.map(\.pano) == ["a", "b"])
    }

    @Test func anUnknownStartOrAEDHasNoFlight() {
        #expect(data?.flight(to: "staged_1", from: "nowhere", hasImage: always) == nil)
        #expect(data?.flight(to: "aed_9", from: "a", hasImage: always) == nil)
        #expect(data?.flight(to: "staged_1", from: "a", hasImage: { _ in false }) == nil)
    }

    @Test func otherSchemasAreIgnored() {
        #expect(DroneData.decode(Data(drone.replacingOccurrences(of: "drone.v1", with: "drone.v2").utf8)) == nil)
    }

    @Test func picturesAreFoundByTheirRenamedFile() {
        #expect(DroneData.resourceName("drone/staged_1/abc.jpg") == "drone-staged_1-abc")
    }

    @Test func captionsAndTheEndCardReadRight() throws {
        let frames = try #require(data?.targets["staged_1"]?.frames)
        #expect(DroneData.caption(try #require(frames["a"])) == "Through the Hallway · Floor 1")
        #expect(DroneData.caption(try #require(frames["b"])) == "Floor 1")
        #expect(DroneData.caption(try #require(frames["c"])) == "Through the Lobby")
        let end = DroneData.arrival(try #require(data?.targets["staged_1"]), aed: nil, lengthM: 28.3)
        // The file's staged flag is never shown.
        #expect(end.title == "AED here: AED by the stairs")
        #expect(end.detail == "About 28 m walk")
        for line in [end.title, DronePreviewButton.title, DronePreviewButton.hint] {
            #expect(!line.lowercased().contains("nearest") && !line.lowercased().contains("proposed"))
        }
    }

    /// Where a build has the real pack: every frame's picture is there and every chain reaches its end.
    @Test func theBundledPackIsComplete() throws {
        guard let bundled = DroneData.bundled else { return }
        for (aed, target) in bundled.targets {
            for (pano, frame) in target.frames {
                #expect(DroneData.imageURL(frame.img) != nil, "\(frame.img)")
                let flight = try #require(bundled.flight(to: aed, from: pano))
                #expect(flight.last?.next == nil, "\(pano) stops early")
            }
        }
        if let entrance = bundled.entrancePano { #expect(bundled.flight(to: "staged_1", from: entrance) != nil) }
    }
}
