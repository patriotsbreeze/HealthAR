import Foundation

/// `drone.json`, schema `drone.v1`: for each AED, one recorded frame per scan spot, looking toward the
/// next spot on the walk there. Following `next` from any spot flies the route; the last frame faces
/// the AED. Git-ignored with its JPEGs, which are copied in renamed `drone-<aed>-<pano>.jpg` so they
/// can sit in the bundle root beside the locator tiles of the same pano.
struct DroneData: Sendable, Equatable {
    static let schema = "drone.v1"
    static let resource = "drone"

    struct Frame: Sendable, Equatable {
        var pano: String
        var next: String?
        var img: String
        var room: String
        var floor: String
    }

    struct Target: Sendable, Equatable {
        var text: String
        var staged: Bool
        var frames: [String: Frame]
    }

    var building: String
    var entrancePano: String?
    var targets: [String: Target]

    /// Read raw: the keys are ids, which a snake-case decoder would rewrite.
    static func decode(_ data: Data) -> DroneData? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? String == schema,
              let building = root["building"] as? String,
              let targetsJSON = root["targets"] as? [String: Any]
        else { return nil }
        var targets: [String: Target] = [:]
        for (aed, value) in targetsJSON {
            guard let target = value as? [String: Any], let framesJSON = target["frames"] as? [String: Any] else { continue }
            var frames: [String: Frame] = [:]
            for (pano, body) in framesJSON {
                guard let frame = body as? [String: Any], let img = frame["img"] as? String, !img.isEmpty else { continue }
                frames[pano] = Frame(
                    pano: pano,
                    next: (frame["next"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    img: img,
                    room: frame["room"] as? String ?? "",
                    floor: frame["floor"] as? String ?? ""
                )
            }
            guard !frames.isEmpty else { continue }
            targets[aed] = Target(text: target["text"] as? String ?? "", staged: target["staged"] as? Bool ?? false, frames: frames)
        }
        return targets.isEmpty ? nil : DroneData(building: building, entrancePano: root["entrance_pano"] as? String, targets: targets)
    }

    static func load(bundle: Bundle = .main) -> DroneData? {
        bundle.url(forResource: resource, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(decode)
    }

    nonisolated static let bundled = DroneData.load()

    /// The flight from `start` to the AED: each frame in turn until `next` runs out. A loop, a `next`
    /// with no frame, or a frame whose picture is missing ends it at the last good frame. Nil when the
    /// start has no frame at all.
    func flight(to aed: String, from start: String, hasImage: (Frame) -> Bool = { DroneData.imageURL($0.img) != nil }) -> [Frame]? {
        guard let frames = targets[aed]?.frames, let first = frames[start], hasImage(first) else { return nil }
        var flight = [first]
        var seen: Set<String> = [start]
        var next = first.next
        while let id = next, !seen.contains(id), let frame = frames[id], hasImage(frame) {
            flight.append(frame)
            seen.insert(id)
            next = frame.next
        }
        return flight
    }

    /// "drone/staged_1/abc.jpg" is "drone-staged_1-abc.jpg" in the bundle.
    static func resourceName(_ img: String) -> String {
        let path = img.hasSuffix(".jpg") ? String(img.dropLast(4)) : img
        return path.split(separator: "/").joined(separator: "-")
    }

    static func imageURL(_ img: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName(img), withExtension: "jpg")
    }

    /// "Through the Hallway · Floor 1", or the floor alone when the room has no name.
    static func caption(_ frame: Frame) -> String {
        let room = BuildingWording.clean(frame.room)
        let floor = BuildingWording.clean(frame.floor)
        switch (room.isEmpty, floor.isEmpty) {
        case (false, false): return "Through the \(room) · \(floor)"
        case (false, true): return "Through the \(room)"
        case (true, false): return floor
        case (true, true): return "On the way"
        }
    }

    /// The end card: "AED here: AED by the water fountains". The file's `staged` flag is never shown.
    static func arrival(_ target: Target, aed: BuildingBrief.AED?, lengthM: Double?) -> (title: String, detail: String?) {
        let name = BuildingWording.clean(target.text.isEmpty ? (aed?.place ?? "") : target.text)
        let title = name.isEmpty ? "AED here" : "AED here: \(name)"
        let detail = lengthM.map { "About \(Int($0.rounded())) m walk" }
        return (title, detail)
    }
}
