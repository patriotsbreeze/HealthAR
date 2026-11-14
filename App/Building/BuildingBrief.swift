import Foundation

/// One building from `building_briefs.v1.json`, which the survey exporter writes after a person
/// approves the plan. The phone file carries only AEDs actually seen in a scan, never a spot someone
/// suggested for a new one, so nothing here can direct anyone to an AED that isn't there.
///
/// The model reports, the engine decides: this file is a report, and `usable` decides what of it the
/// app may show.
struct BuildingBriefFile: Decodable, Sendable {
    static let schema = "building_briefs.v1"

    var schema: String
    var generatedAt: String
    var buildings: [BuildingBrief]

    private enum CodingKeys: String, CodingKey { case schema, generatedAt, buildings }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        // One bad building costs that building, not the file.
        buildings = try container.decodeIfPresent([Lossy<BuildingBrief>].self, forKey: .buildings)?.compactMap(\.value) ?? []
    }
}

struct BuildingBrief: Decodable, Sendable, Equatable, Identifiable {
    struct Geofence: Decodable, Sendable, Equatable {
        var lat: Double
        var lon: Double
        var radiusM: Double
    }

    /// An AED seen in the scan, at the place the scan shows it.
    struct AED: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var place: String
        var floor: String
        var scanDate: String
        var confirmedAt: String
        /// The exporter's median one-way walk to it from the scanned area of its floor, in metres,
        /// rounded to 10. Nil when the file leaves it out, sends null, or sends something unusable.
        var typicalWalkM: Int?
        /// Read from older files and kept, but never shown: a demo AED looks like any other.
        var staged: Bool
        /// Pinned on this phone by someone standing at it, not read from any file.
        var markedByHand = false
        /// How to walk to it from the entrance doorway. Nil when the file has none, or one the guide can't use.
        var routeFromEntrance: Route?

        private enum CodingKeys: String, CodingKey {
            case id, place, floor, scanDate, confirmedAt, typicalWalkM, staged, routeFromEntrance
        }

        init(
            id: String,
            place: String,
            floor: String,
            scanDate: String,
            confirmedAt: String,
            typicalWalkM: Int? = nil,
            staged: Bool = false,
            routeFromEntrance: Route? = nil
        ) {
            self.id = id
            self.place = place
            self.floor = floor
            self.scanDate = scanDate
            self.confirmedAt = confirmedAt
            self.typicalWalkM = typicalWalkM
            self.staged = staged
            self.routeFromEntrance = routeFromEntrance
        }

        /// From the survey file, rather than marked by hand on this phone.
        var isFromScan: Bool { !markedByHand }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            place = try container.decodeIfPresent(String.self, forKey: .place) ?? ""
            floor = try container.decodeIfPresent(String.self, forKey: .floor) ?? ""
            scanDate = try container.decodeIfPresent(String.self, forKey: .scanDate) ?? ""
            confirmedAt = try container.decodeIfPresent(String.self, forKey: .confirmedAt) ?? ""
            // A bad walk costs only the near or far advice, never the AED.
            typicalWalkM = (try? container.decodeIfPresent(Int.self, forKey: .typicalWalkM)).flatMap { $0 >= 0 ? $0 : nil }
            staged = (try? container.decodeIfPresent(Bool.self, forKey: .staged)) ?? false
            // Likewise a route the guide can't follow costs only the guide.
            routeFromEntrance = (try? container.decodeIfPresent(Route.self, forKey: .routeFromEntrance))
                .flatMap { $0.isUsable && $0.anchor == "entrance" ? $0 : nil }
        }

        /// Nil when the walk isn't known, and then the line gives no near or far advice.
        var reach: BuildingWording.Reach? {
            typicalWalkM.map { $0 <= BuildingWording.nearWalkM ? .near($0) : .far($0) }
        }
    }

    /// A walk in a frame anchored at the entrance: the origin is where the person stands in the doorway,
    /// forward points into the building along the first leg, and right is their right. Metres.
    struct Route: Decodable, Sendable, Equatable {
        var anchor: String
        var anchorText: String
        var lengthM: Double
        var floorChange: Bool
        /// (right, forward) pairs, starting at the doorway.
        var waypoints: [SIMD2<Double>]
        /// What to do on each leg, keyed to the point where that leg ends.
        var steps: [Step]
        /// True-north compass bearing of the first leg, so the calibration can point the person along it.
        var startBearingDeg: Double?

        struct Step: Decodable, Sendable, Equatable {
            var at: SIMD2<Double>
            var text: String

            private enum CodingKeys: String, CodingKey { case at, text }

            init(at: SIMD2<Double>, text: String) {
                self.at = at
                self.text = text
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let pair = try container.decode([Double].self, forKey: .at)
                guard pair.count == 2, pair.allSatisfy(\.isFinite) else {
                    throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "not a pair")
                }
                at = SIMD2(pair[0], pair[1])
                text = BuildingWording.clean(try container.decode(String.self, forKey: .text)) + "."
            }
        }

        private enum CodingKeys: String, CodingKey { case anchor, anchorText, lengthM, floorChange, waypoints, steps, startBearingDeg }

        init(
            anchor: String = "entrance",
            anchorText: String,
            lengthM: Double? = nil,
            floorChange: Bool = false,
            waypoints: [SIMD2<Double>],
            steps: [Step] = [],
            startBearingDeg: Double? = nil
        ) {
            self.anchor = anchor
            self.anchorText = anchorText
            self.waypoints = waypoints
            self.lengthM = lengthM ?? AEDPath.length(waypoints)
            self.floorChange = floorChange
            self.steps = steps
            self.startBearingDeg = startBearingDeg
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            anchor = try container.decodeIfPresent(String.self, forKey: .anchor) ?? ""
            anchorText = try container.decodeIfPresent(String.self, forKey: .anchorText) ?? ""
            floorChange = (try? container.decodeIfPresent(Bool.self, forKey: .floorChange)) ?? false
            // A pair that isn't two finite numbers makes the whole route unusable, rather than a shortcut.
            let pairs = try container.decode([[Double]].self, forKey: .waypoints)
            waypoints = pairs.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } ? pairs.map { SIMD2($0[0], $0[1]) } : []
            lengthM = (try? container.decodeIfPresent(Double.self, forKey: .lengthM)) ?? AEDPath.length(waypoints)
            // A step that can't be read is left out; the arrows still show the way.
            steps = (try? container.decodeIfPresent([Lossy<Step>].self, forKey: .steps))?.compactMap(\.value).filter { $0.text.count > 1 } ?? []
            let bearing = (try? container.decodeIfPresent(Double.self, forKey: .startBearingDeg)) ?? nil
            startBearingDeg = bearing.flatMap { $0.isFinite ? Compass.normalized($0) : nil }
        }

        /// Somewhere to go. Where it starts from is the caller's to check.
        var isUsable: Bool {
            waypoints.count >= 2 && AEDPath.length(waypoints) >= 1
        }
    }

    struct EMSEntrance: Decodable, Sendable, Equatable {
        var text: String
        /// "scan", "aerial", or both.
        var checkedFrom: [String]
        var status: String

        private enum CodingKeys: String, CodingKey { case text, checkedFrom, status }

        init(text: String, checkedFrom: [String], status: String = "") {
            self.text = text
            self.checkedFrom = checkedFrom
            self.status = status
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            checkedFrom = try container.decodeIfPresent([String].self, forKey: .checkedFrom) ?? []
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        }
    }

    var id: String
    var name: String
    var address: String
    var geofence: Geofence
    var planStatus: String
    var layers: [String]
    var aeds: [AED]
    var emsEntrance: EMSEntrance?

    private enum CodingKeys: String, CodingKey { case id, name, address, geofence, planStatus, layers, aeds, emsEntrance }

    init(
        id: String,
        name: String,
        address: String,
        geofence: Geofence,
        planStatus: String,
        layers: [String] = [],
        aeds: [AED] = [],
        emsEntrance: EMSEntrance? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.geofence = geofence
        self.planStatus = planStatus
        self.layers = layers
        self.aeds = aeds
        self.emsEntrance = emsEntrance
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        geofence = try container.decode(Geofence.self, forKey: .geofence)
        planStatus = try container.decode(String.self, forKey: .planStatus)
        layers = try container.decodeIfPresent([String].self, forKey: .layers) ?? []
        aeds = try container.decodeIfPresent([Lossy<AED>].self, forKey: .aeds)?.compactMap(\.value) ?? []
        emsEntrance = try container.decodeIfPresent(EMSEntrance.self, forKey: .emsEntrance)
    }
}

extension BuildingBrief {
    static let verified = "verified"

    /// Snake case in the file, and unknown keys, a stray `proposals` among them, are never read.
    static func decode(_ data: Data) throws -> BuildingBriefFile {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BuildingBriefFile.self, from: data)
    }

    /// What the app may show: buildings a person approved, and in them only AEDs with a place, a scan
    /// date it can print, and a confirmation. Anything else in the file is left unread.
    static func usable(_ data: Data) -> [BuildingBrief] {
        guard let file = try? decode(data), file.schema == BuildingBriefFile.schema else { return [] }
        var seen = Set<String>()
        return file.buildings.compactMap { building in
            guard building.planStatus == verified,
                  !building.id.trimmed.isEmpty,
                  !building.name.trimmed.isEmpty,
                  building.geofence.radiusM > 0,
                  seen.insert(building.id).inserted
            else { return nil }
            var kept = building
            kept.aeds = building.aeds.filter(\.isUsable)
            if let entrance = building.emsEntrance, entrance.text.trimmed.isEmpty { kept.emsEntrance = nil }
            return kept
        }
    }
}

extension BuildingBrief.AED {
    var isUsable: Bool {
        !place.trimmed.isEmpty
            && !confirmedAt.trimmed.isEmpty
            // One marked on this phone has no scan date. Everything from the file needs one.
            && (!isFromScan || BuildingWording.monthYear(scanDate) != nil)
            // A spot someone suggested is not an AED. The file shouldn't carry one, and if it does it stays unread.
            && !place.lowercased().contains("propos")
            && !id.lowercased().contains("propos")
    }
}

/// Every sentence the building section and rows say, so each one can be checked. None says "nearest":
/// the scan shows where an AED was, not which is closest. None says "proposed": a suggested spot is
/// not an AED, and the phone never points anyone at one.
enum BuildingWording {
    static let sectionTitle = "This building (simulation)"
    static let confirmTitle = "Yes, I'm in this building"
    static let confirmedLabel = "Building confirmed for this rescue"
    static let chooseTitle = "Choose a building plan (simulation)"
    static let matchByLocation = "Match by approximate location instead"
    static let chosenByHand = "Simulation: chosen by hand"
    static let noMatch = "No building plan matches your approximate location. Choose one to try it."
    static let readAloudTitle = "Read building aloud"
    static let readAloudHint = "Enabled once you confirm the building. An on-device voice reads it."
    static let handoffTitle = "Building (from a survey, not this rescue's log)"

    static let guideTitle = "Guide me to the AED (AR)"
    static let guideHint = "Enabled once you confirm the building. Opens the camera and draws the way from the entrance."
    /// An AED someone stood at and marked on this phone.
    static let marked = "AED marked by hand (simulation)"
    static let markedOrigin = "Marked on this phone by someone standing at it, not seen in a building scan."
    static let markedPlace = "Where it was marked"
    static let clearMarks = "Clear AEDs marked on this phone"

    static var fixedStrings: [String] {
        [sectionTitle, confirmTitle, confirmedLabel, chooseTitle, matchByLocation, chosenByHand, noMatch,
         readAloudTitle, readAloudHint, handoffTitle, none, guideTitle, guideHint,
         nearAdvice, farAdvice, marked, markedOrigin, markedPlace, clearMarks]
    }

    static let none = "No AED was seen in this building's scan. Ask people nearby."

    /// "Looks like Tower One, 1 Main St. From a building survey, …"
    static func match(_ building: BuildingBrief) -> String {
        "Looks like \(nameAndAddress(building)). From a building survey, matched by approximate location. Check it's where you are."
    }

    static func nameAndAddress(_ building: BuildingBrief) -> String {
        let address = clean(building.address)
        return address.isEmpty ? clean(building.name) : "\(clean(building.name)), \(address)"
    }

    /// Within this walk an AED is worth fetching, past it the person keeps pushing. 100 m one way, the
    /// coverage convention in Hansen et al., Circulation 2013.
    static let nearWalkM = 100

    enum Reach: Equatable, Sendable {
        case near(Int)
        case far(Int)
    }

    static let nearAdvice = "Send someone to get it. If you're alone, get it and come straight back."
    static let farAdvice = "Don't leave the person to get it. Keep pushing. If someone is with you, send them."

    static func advice(_ reach: Reach) -> String {
        switch reach {
        case .near: nearAdvice
        case .far: farAdvice
        }
    }

    /// "AED", or for one marked by hand, that.
    static func label(_ aed: BuildingBrief.AED) -> String {
        aed.markedByHand ? marked : "AED"
    }

    /// Near or far by the exporter's typical walk, and with no walk, where the scan saw it and nothing more.
    static func aed(_ aed: BuildingBrief.AED) -> String? {
        let date = monthYear(aed.scanDate)
        guard !aed.isFromScan || date != nil else { return nil }
        let origin = aed.markedByHand ? markedOrigin : "Seen in a building scan dated \(date ?? ""). It may have moved."
        switch aed.reach {
        case let .near(metres):
            return "\(label(aed)) about \(metres) m away: \(aedPlace(aed)). \(nearAdvice) \(origin)"
        case let .far(metres):
            let subject = aed.isFromScan ? "The AED seen in this building" : "The \(label(aed))"
            return "\(subject) is a long walk away (about \(metres) m): \(aedPlace(aed)). \(farAdvice) \(origin)"
        case nil:
            if !aed.isFromScan { return "\(label(aed)): \(aedPlace(aed)). \(origin)" }
            return "AED seen in a building scan dated \(date ?? ""): \(aedPlace(aed)). It may have moved. Check it's there."
        }
    }

    /// The AED the guide walks to: the shortest route among those that have one.
    static func guideTarget(_ building: BuildingBrief) -> BuildingBrief.AED? {
        building.aeds
            .filter { $0.routeFromEntrance != nil && aed($0) != nil }
            .min { ($0.routeFromEntrance?.lengthM ?? 0) < ($1.routeFromEntrance?.lengthM ?? 0) }
    }

    static func aeds(_ building: BuildingBrief) -> [String] {
        let lines = building.aeds.compactMap(aed)
        return lines.isEmpty ? [none] : lines
    }

    /// Nil when the file doesn't say what checked it, since "AI-assisted from" something is the point.
    static func entrance(_ building: BuildingBrief) -> String? {
        guard let entrance = building.emsEntrance, let source = source(entrance) else { return nil }
        let text = clean(entrance.text)
        guard !text.isEmpty else { return nil }
        return "Suggested EMS entrance: \(text). AI-assisted from \(source), approved by a person, not checked on site."
    }

    static func source(_ entrance: BuildingBrief.EMSEntrance) -> String? {
        let from = Set(entrance.checkedFrom.map { $0.lowercased() })
        switch (from.contains("scan"), from.contains("aerial")) {
        case (true, true): return "the scan and aerial photos"
        case (true, false): return "the scan only"
        case (false, true): return "the aerial photos only"
        case (false, false): return nil
        }
    }

    /// For the mock dispatcher, and only once the person has said they're in this building, this rescue.
    static func spoken(_ building: BuildingBrief, confirmed: Bool) -> String? {
        guard confirmed else { return nil }
        var parts = ["This is a simulation.", "The caller confirms they are in \(clean(building.name))."]
        if entrance(building) != nil, let text = building.emsEntrance.map({ clean($0.text) }) {
            parts.append("A building survey suggests EMS use \(text).")
            parts.append("It was not checked on site.")
        }
        let shown = building.aeds.filter { aed($0) != nil }
        // The shortest known walk decides near or far. With none known, it's where the scan saw them.
        if let closest = shown.filter({ $0.typicalWalkM != nil }).min(by: { ($0.typicalWalkM ?? 0) < ($1.typicalWalkM ?? 0) }),
           let reach = closest.reach {
            let place = clean(closest.place)
            switch (reach, !closest.isFromScan) {
            case let (.near(metres), false):
                parts.append("An AED was seen in a scan of this building, about \(metres) m away: \(place).")
            case let (.near(metres), true):
                parts.append("A \(label(closest)) is in this building, about \(metres) m away: \(place).")
            case let (.far(metres), false):
                parts.append("The AED seen in a scan of this building is a long walk away, about \(metres) m: \(place).")
            case let (.far(metres), true):
                parts.append("The \(label(closest)) in this building is a long walk away, about \(metres) m: \(place).")
            }
            parts.append(advice(reach))
            return parts.joined(separator: " ")
        }
        let places = shown.filter(\.isFromScan).map { clean($0.place) }
        switch places.count {
        case 0: parts.append("No AED was seen in this building's scan.")
        case 1: parts.append("An AED was seen in a scan of this building: \(places[0]).")
        default: parts.append("AEDs were seen in a scan of this building: \(places.joined(separator: "; ")).")
        }
        for other in shown where !other.isFromScan {
            parts.append("\(label(other)): \(clean(other.place)).")
        }
        return parts.joined(separator: " ")
    }

    /// "2024-05" or "2024-05-17" to "May 2024". English, whatever the phone's language, like every
    /// other line here. Nil for anything else, which leaves that AED unshown.
    static func monthYear(_ date: String) -> String? {
        let parts = date.trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].count == 4, let year = Int(parts[0]), year > 1900,
              parts[1].count == 2, let month = Int(parts[1]), (1...12).contains(month)
        else { return nil }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[month - 1]) \(year)"
    }

    static func aedPlace(_ aed: BuildingBrief.AED) -> String {
        let floor = clean(aed.floor)
        return floor.isEmpty ? clean(aed.place) : "\(clean(aed.place)), \(floor)"
    }

    /// Trims the edges, and a trailing full stop, since every line adds its own.
    static func clean(_ text: String) -> String {
        var text = text.trimmed
        while text.hasSuffix(".") { text.removeLast() }
        return text.trimmed
    }
}

/// Decodes what it can and leaves the rest as nil.
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
