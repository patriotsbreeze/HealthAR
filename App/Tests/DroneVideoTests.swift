import Foundation
@testable import HealthAISim
import Testing

/// Made up for these tests: a → b → c then the AED, plus a loop, a gap and a hop with no file.
private let pack = """
{"schema": "drone_video.v1", "building": "mp:FIXTURE", "fps": 30, "targets": {"staged_1": {"text": "AED by the water fountains", "clips": {
  "a": {"next": "b", "room": "Hallway", "floor": "Floor 1", "length_m": 4, "clip": "dronevid/staged_1/a.mp4", "duration_s": 2},
  "b2": {"next": "c", "room": "", "floor": "Floor 1", "length_m": 6, "clip": "dronevid/staged_1/b2.mp4", "duration_s": 2, "intro_clip": "dronevid/staged_1/intro_b2.mp4", "intro_duration_s": 3},
  "b": {"next": "c", "room": "", "floor": "Floor 1", "length_m": 6, "clip": "dronevid/staged_1/b.mp4", "duration_s": 2},
  "c": {"next": null, "room": "Lobby", "floor": "", "length_m": 0, "final_clip": "dronevid/staged_1/final_c.mp4", "duration_s": 2.2},
  "x": {"next": "y", "length_m": 1, "clip": "dronevid/staged_1/x.mp4", "duration_s": 1},
  "y": {"next": "x", "length_m": 1, "clip": "dronevid/staged_1/y.mp4", "duration_s": 1},
  "g": {"next": "missing", "length_m": 1, "clip": "dronevid/staged_1/g.mp4", "duration_s": 1},
  "n": {"next": "c", "length_m": 1, "duration_s": 1}}}}}
"""

@MainActor
@Suite struct DroneVideoTests {
    let video = DroneVideo.decode(Data(pack.utf8))
    private let always: (String) -> Bool = { _ in true }

    @Test func aWholeChainEndsOnTheFinalClip() throws {
        let flight = try #require(video?.flight(to: "staged_1", from: "a", hasFile: always))
        #expect(flight.map(\.pano) == ["a", "b", "c"])
        #expect(flight.map(\.file) == ["dronevid/staged_1/a.mp4", "dronevid/staged_1/b.mp4", "dronevid/staged_1/final_c.mp4"])
        #expect(flight.last?.isFinal == true)
        #expect(flight.last?.lengthM == 0)
    }

    @Test func aTakeoffPlaysFirstWhenTheStartHasOne() throws {
        let flight = try #require(video?.flight(to: "staged_1", from: "b2", hasFile: always))
        #expect(flight.map(\.file) == ["dronevid/staged_1/intro_b2.mp4", "dronevid/staged_1/b2.mp4", "dronevid/staged_1/final_c.mp4"])
        #expect(flight.first?.isIntro == true)
        #expect(flight.first?.lengthM == 0)
        #expect(DroneVideo.caption(flight[0]) == "Takeoff")
        // A missing takeoff file is skipped, not fatal.
        let noIntro = try #require(video?.flight(to: "staged_1", from: "b2", hasFile: { !$0.contains("intro") }))
        #expect(noIntro.first?.isIntro == false)
    }

    @Test func fromHereUsesTheSpotOrTheClosestRecordedOne() throws {
        let video = try #require(video)
        // Its own spot has a flight.
        #expect(video.start(for: "a", aed: "staged_1", locator: nil, hasFile: always)! == ("a", false))
        // "x" loops, so the closest recorded spot stands in: here the only whole ones are a, b, b2 and c.
        let picked = try #require(video.start(for: "x", aed: "staged_1", locator: nil, hasFile: always))
        #expect(picked.nearest)
        #expect(["a", "b", "b2", "c"].contains(picked.pano))
        #expect(video.start(for: "x", aed: "aed_9", locator: nil, hasFile: always) == nil)
    }

    @Test func aLoopAGapOrAMissingClipIsNoFlight() {
        #expect(video?.flight(to: "staged_1", from: "x", hasFile: always) == nil)
        #expect(video?.flight(to: "staged_1", from: "g", hasFile: always) == nil)
        #expect(video?.flight(to: "staged_1", from: "n", hasFile: always) == nil)
        // A file missing from the bundle counts too.
        #expect(video?.flight(to: "staged_1", from: "a", hasFile: { !$0.hasSuffix("b.mp4") }) == nil)
    }

    @Test func anUnknownStartOrAEDIsNoFlight() {
        #expect(video?.flight(to: "staged_1", from: "nowhere", hasFile: always) == nil)
        #expect(video?.flight(to: "aed_9", from: "a", hasFile: always) == nil)
        #expect(DroneVideo.decode(Data(pack.replacingOccurrences(of: "drone_video.v1", with: "drone_video.v2").utf8)) == nil)
    }

    @Test func theCountdownDropsSmoothlyAcrossHops() throws {
        let flight = try #require(video?.flight(to: "staged_1", from: "a", hasFile: always))
        let durations = [2.0, 2.0, 2.2]
        let starts = DroneVideo.starts(durations)
        #expect(starts == [0, 2, 4])
        func left(_ t: Double) -> Double { DroneVideo.remaining(at: t, segments: flight, starts: starts, durations: durations) }
        #expect(left(0) == 10)
        #expect(left(1) == 8)      // halfway through the 4 m hop
        #expect(left(2) == 6)
        #expect(left(3) == 3)      // halfway through the 6 m hop
        #expect(left(4) == 0)      // the final push-in covers no ground
        #expect(left(9) == 0)
        #expect(DroneVideo.index(at: 0, starts: starts) == 0)
        #expect(DroneVideo.index(at: 2.5, starts: starts) == 1)
        #expect(DroneVideo.index(at: 5, starts: starts) == 2)
    }

    @Test func captionsAndTheArrivalCardReadRight() throws {
        let flight = try #require(video?.flight(to: "staged_1", from: "a", hasFile: always))
        #expect(flight.map(DroneVideo.caption) == ["Hallway · Floor 1", "Floor 1", "Lobby"])
        #expect(DroneVideo.arrival(text: "AED by the water fountains", lengthM: 51) == "AED · by the water fountains · 51 m · about 35\u{00A0}s walk")
        #expect(DroneVideo.arrival(text: "", lengthM: 0) == "AED")
        #expect(DroneVideo.resourceName("dronevid/staged_1/final_c.mp4") == ("dronevid-staged_1-final_c", "mp4"))
    }

    /// Where a build has the real pack: the entrance flight is whole, and every hop's file is there.
    @Test func theBundledEntranceFlightIsWhole() throws {
        guard let bundled = DroneVideo.bundled, let entrance = DroneData.bundled?.entrancePano else { return }
        let flight = try #require(bundled.flight(to: "staged_1", from: entrance))
        #expect(flight.last?.isFinal == true)
    }
}
