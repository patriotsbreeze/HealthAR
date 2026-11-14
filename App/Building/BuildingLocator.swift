import CoreLocation
import Foundation
import Observation

/// Approximate location for the building section, kept apart from `LocationService` so the caller
/// script's address is never touched by it. It never asks for permission: without it, there is no fix
/// and no building matches, and a building can still be chosen by hand.
@MainActor
@Observable
final class BuildingLocator: NSObject, CLLocationManagerDelegate {
    static let shared = BuildingLocator()

    /// Where the phone thinks it is, and how sure it is, in metres.
    struct Fix: Sendable, Equatable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
    }

    /// A fix less sure than this matches nothing.
    static let worstAccuracy: Double = 100
    /// However unsure a fix is, the geofence grows by no more than this.
    static let accuracyAllowanceCap: Double = 50
    /// A cached fix older than this may be from somewhere else.
    static let maxFixAge: TimeInterval = 300

    private(set) var fix: Fix?

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Does nothing without permission, and so can never raise a prompt.
    func refresh() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let location = manager.location { received(location) }
            manager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.received(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    func received(_ location: CLLocation, now: Date = Date()) {
        guard location.horizontalAccuracy >= 0, now.timeIntervalSince(location.timestamp) <= Self.maxFixAge else { return }
        fix = Fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy)
    }

    func match(in buildings: [BuildingBrief]) -> BuildingBrief? {
        Self.match(fix, in: buildings)
    }

    /// Exactly one building, or none. Two that both fit is a guess, and this doesn't guess.
    static func match(_ fix: Fix?, in buildings: [BuildingBrief]) -> BuildingBrief? {
        guard let fix, fix.accuracy >= 0, fix.accuracy <= worstAccuracy else { return nil }
        let allowance = min(fix.accuracy, accuracyAllowanceCap)
        let inside = buildings.filter { building in
            let fence = building.geofence
            return distance(fix.latitude, fix.longitude, fence.lat, fence.lon) <= fence.radiusM + allowance
        }
        return inside.count == 1 ? inside[0] : nil
    }

    /// Haversine, in metres.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadius = 6_371_008.8
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
