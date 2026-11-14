import Foundation
import Observation

/// AEDs someone pinned on this phone by walking to them from the entrance with the guide up. The scan
/// can't know about an AED it never saw, so a person standing at one is the source. Each keeps the walk
/// that got there, simplified, so the guide can lead the next person the same way.
struct MarkedAED: Codable, Sendable, Equatable {
    var id: String
    /// (right, forward) from the entrance doorway, the same frame as the venue file's routes.
    var waypoints: [[Double]]
    var anchorText: String
    var markedAt: Date

    var route: BuildingBrief.Route {
        BuildingBrief.Route(anchorText: anchorText, waypoints: waypoints.map { SIMD2($0[0], $0[1]) })
    }

    /// As an AED of the building: usable, labelled as marked by hand, with its walk rounded to 10 m.
    var aed: BuildingBrief.AED {
        let route = route
        var aed = BuildingBrief.AED(
            id: id,
            place: BuildingWording.markedPlace,
            floor: "",
            scanDate: "",
            confirmedAt: ISO8601DateFormatter().string(from: markedAt),
            typicalWalkM: Int((route.lengthM / 10).rounded()) * 10,
            routeFromEntrance: route
        )
        aed.markedByHand = true
        return aed
    }
}

@MainActor
@Observable
final class MarkedAEDStore {
    static let shared = MarkedAEDStore()
    static let defaultsKey = "building.markedAEDs.v1"

    /// By building id.
    private(set) var marks: [String: [MarkedAED]]
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        marks = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: [MarkedAED]].self, from: $0) } ?? [:]
    }

    /// The building with its marked AEDs added after the file's own.
    func withMarks(_ building: BuildingBrief) -> BuildingBrief {
        guard let mine = marks[building.id], !mine.isEmpty else { return building }
        var building = building
        building.aeds += mine.map(\.aed)
        return building
    }

    /// Nil when the walk is too short to be a route.
    @discardableResult
    func mark(building: String, walk: [SIMD2<Double>], anchorText: String, at date: Date = Date()) -> MarkedAED? {
        let points = AEDPath.simplify(walk, tolerance: AEDPath.markTolerance)
        guard points.count >= 2, AEDPath.length(points) >= 1 else { return nil }
        let number = (marks[building]?.count ?? 0) + 1
        let mark = MarkedAED(
            id: "marked_\(number)_\(Int(date.timeIntervalSince1970))",
            waypoints: points.map { [($0.x * 100).rounded() / 100, ($0.y * 100).rounded() / 100] },
            anchorText: anchorText,
            markedAt: date
        )
        marks[building, default: []].append(mark)
        save()
        return mark
    }

    func clear(building: String) {
        marks[building] = nil
        save()
    }

    func count(for building: String) -> Int { marks[building]?.count ?? 0 }

    private func save() {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        defaults?.set(data, forKey: Self.defaultsKey)
    }
}
