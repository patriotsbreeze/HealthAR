import Foundation
import os

/// `drone_video.json`, schema `drone_video.v1`: for each AED, one short clip per scan spot flying to
/// the next spot, and a final push-in on the AED. Each clip ends on the pose the next one starts from,
/// so a chain played back to back is one continuous flight. Git-ignored with its clips, which are
/// copied in renamed `dronevid-<aed>-<file>.mp4` so the bundle root holds them all.
struct DroneVideo: Sendable, Equatable {
    static let schema = "drone_video.v1"
    static let resource = "drone_video"
    /// The walk on the arrival card, in metres a second.
    static let walkingPace = 1.4

    struct Clip: Sendable, Equatable {
        var pano: String
        var next: String?
        var room: String
        var floor: String
        var lengthM: Double
        var clip: String?
        var finalClip: String?
        var durationS: Double
        /// A takeoff dive from above the building into this spot, played first when the flight starts here.
        var introClip: String? = nil
        var introDurationS: Double = 0
    }

    struct Target: Sendable, Equatable {
        var text: String
        var clips: [String: Clip]
    }

    /// One piece of the flight, in play order.
    struct Segment: Sendable, Equatable {
        var pano: String
        var file: String
        var durationS: Double
        var lengthM: Double
        var room: String
        var floor: String
        var isFinal: Bool
        var isIntro = false
    }

    var building: String
    var targets: [String: Target]

    /// Read raw: the keys are ids, which a snake-case decoder would rewrite.
    static func decode(_ data: Data) -> DroneVideo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? String == schema,
              let building = root["building"] as? String,
              let targetsJSON = root["targets"] as? [String: Any]
        else { return nil }
        var targets: [String: Target] = [:]
        for (aed, value) in targetsJSON {
            guard let target = value as? [String: Any], let clipsJSON = target["clips"] as? [String: Any] else { continue }
            var clips: [String: Clip] = [:]
            for (pano, body) in clipsJSON {
                guard let clip = body as? [String: Any] else { continue }
                func text(_ key: String) -> String? { (clip[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                func number(_ key: String) -> Double { (clip[key] as? NSNumber)?.doubleValue ?? 0 }
                clips[pano] = Clip(
                    pano: pano, next: text("next"), room: text("room") ?? "", floor: text("floor") ?? "",
                    lengthM: max(0, number("length_m")), clip: text("clip"), finalClip: text("final_clip"),
                    durationS: max(0, number("duration_s")),
                    introClip: text("intro_clip"), introDurationS: max(0, number("intro_duration_s"))
                )
            }
            guard !clips.isEmpty else { continue }
            targets[aed] = Target(text: target["text"] as? String ?? "", clips: clips)
        }
        return targets.isEmpty ? nil : DroneVideo(building: building, targets: targets)
    }

    static func load(bundle: Bundle = .main) -> DroneVideo? {
        bundle.url(forResource: resource, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(decode)
    }

    nonisolated static let bundled = DroneVideo.load()

    /// At most this many clipless hops in one flight. More and it's a slideshow of jumps, not a flight.
    static let maxCuts = 2

    /// Each hop's clip from `start`, then the AED's final clip. Only a whole flight counts: a loop, a
    /// missing entry or a missing file means no flight, so the button stays hidden rather than stopping
    /// short of the AED. A hop with no clip at all is skipped as a cut.
    func flight(to aed: String, from start: String, hasFile: (String) -> Bool = { DroneVideo.url($0) != nil }) -> [Segment]? {
        guard let clips = targets[aed]?.clips else { return nil }
        var segments: [Segment] = []
        var seen: Set<String> = []
        var here = start
        var cuts = 0
        // The takeoff covers no ground, so the countdown starts once the first hop does.
        if let intro = clips[start]?.introClip, hasFile(intro) {
            segments.append(Segment(pano: start, file: intro, durationS: clips[start]?.introDurationS ?? 0, lengthM: 0,
                                    room: "", floor: "", isFinal: false, isIntro: true))
        }
        while let entry = clips[here], seen.insert(here).inserted {
            if let next = entry.next {
                // A hop with no clip is a cut: its recording went somewhere else, so the flight jumps to
                // the next spot, a few metres on, rather than show the wrong hallway. A clip that's named
                // but missing from the bundle still sinks the whole flight.
                guard let file = entry.clip else {
                    cuts += 1
                    if cuts > Self.maxCuts { return nil }
                    here = next
                    continue
                }
                guard hasFile(file) else { return nil }
                segments.append(Segment(pano: here, file: file, durationS: entry.durationS, lengthM: entry.lengthM,
                                        room: entry.room, floor: entry.floor, isFinal: false))
                here = next
            } else {
                guard let file = entry.finalClip, hasFile(file) else { return nil }
                segments.append(Segment(pano: here, file: file, durationS: entry.durationS, lengthM: 0,
                                        room: entry.room, floor: entry.floor, isFinal: true))
                return segments
            }
        }
        return nil
    }

    /// Where to fly from for someone standing at `pano`: that spot when it has a whole flight, else the
    /// closest spot that does: same area of the survey first, then the most similar walk to the AED.
    /// `nearest` says it isn't their own spot, so the screen can say so.
    func start(for pano: String, aed: String, locator: LocatorData?, hasFile: (String) -> Bool = { DroneVideo.url($0) != nil }) -> (pano: String, nearest: Bool)? {
        if flight(to: aed, from: pano, hasFile: hasFile) != nil { return (pano, false) }
        guard let clips = targets[aed]?.clips else { return nil }
        let area = locator?.areas.first { $0.panos.contains { $0.id == pano } }?.id
        let areaOf: [String: String] = Dictionary(
            (locator?.areas ?? []).flatMap { area in area.panos.map { ($0.id, area.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let mine = locator?.routes[aed]?[pano]?.lengthM
        func walk(_ id: String) -> Double? { locator?.routes[aed]?[id]?.lengthM }
        let candidates = clips.keys.filter { flight(to: aed, from: $0, hasFile: hasFile) != nil }
        let best = candidates.min { a, b in
            let rank = { (id: String) -> (Int, Double, String) in
                let sameArea = area != nil && areaOf[id] == area ? 0 : 1
                let gap = mine.flatMap { m in walk(id).map { abs($0 - m) } } ?? .infinity
                return (sameArea, gap, id)
            }
            return rank(a) < rank(b)
        }
        return best.map { ($0, true) }
    }

    static let log = Logger(subsystem: "HealthAI", category: "drone")

    static let nearestNote = "Starting from the nearest recorded spot"

    /// "dronevid/staged_1/abc.mp4" is "dronevid-staged_1-abc.mp4" in the bundle.
    static func resourceName(_ path: String) -> (name: String, ext: String) {
        let ns = path as NSString
        let ext = ns.pathExtension.isEmpty ? "mp4" : ns.pathExtension
        return (ns.deletingPathExtension.split(separator: "/").joined(separator: "-"), ext)
    }

    static func url(_ path: String, bundle: Bundle = .main) -> URL? {
        let resource = resourceName(path)
        return bundle.url(forResource: resource.name, withExtension: resource.ext)
    }

    /// Metres left at `time` seconds into the flight: every hop not yet flown, and the unflown share of
    /// the current one. `starts` are each segment's start time, as the composition actually laid them out.
    static func remaining(at time: Double, segments: [Segment], starts: [Double], durations: [Double]) -> Double {
        guard !segments.isEmpty, starts.count == segments.count, durations.count == segments.count else { return 0 }
        var left = 0.0
        for (index, segment) in segments.enumerated() {
            let start = starts[index]
            let duration = durations[index]
            if time <= start {
                left += segment.lengthM
            } else if time < start + duration, duration > 0 {
                left += segment.lengthM * (1 - (time - start) / duration)
            }
        }
        return max(0, left)
    }

    /// The segment playing at `time`.
    static func index(at time: Double, starts: [Double]) -> Int {
        starts.lastIndex { $0 <= time } ?? 0
    }

    /// Back-to-back start times from durations.
    static func starts(_ durations: [Double]) -> [Double] {
        var cursor = 0.0
        return durations.map { duration in
            defer { cursor += duration }
            return cursor
        }
    }

    /// "Hallway · Floor 1", or the floor alone when the room has no name.
    static func caption(_ segment: Segment) -> String {
        if segment.isIntro { return "Takeoff" }
        let room = BuildingWording.clean(segment.room)
        let floor = BuildingWording.clean(segment.floor)
        switch (room.isEmpty, floor.isEmpty) {
        case (false, false): return "\(room) · \(floor)"
        case (false, true): return room
        case (true, false): return floor
        case (true, true): return "En route"
        }
    }

    /// "AED · by the water fountains · 51 m · about 40 s walk"
    static func arrival(text: String, lengthM: Double) -> String {
        var place = BuildingWording.clean(text)
        if place.lowercased().hasPrefix("aed ") { place = String(place.dropFirst(4)) }
        let metres = Int(lengthM.rounded())
        let seconds = Int((lengthM / walkingPace / 5).rounded()) * 5
        var parts = ["AED"]
        if !place.isEmpty { parts.append(place) }
        if metres > 0 {
            parts.append("\(metres) m")
            // A no-break space keeps "25 s" together on a narrow card.
            parts.append("about \(max(seconds, 5))\u{00A0}s walk")
        }
        return parts.joined(separator: " · ")
    }
}
