import CoreLocation
import MapKit
import Observation
import RescueCore

/// Approximate location for the caller script. Only onboarding may ask for permission. Without it
/// `current` stays nil, which the script shows as "Location unknown".
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var current: CallerLocation?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var geocoding: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Onboarding only.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Does nothing without permission, and so can never raise a prompt.
    func refresh() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func confirmAddress() {
        guard current?.address != nil else { return }
        current?.confirmed = true
    }

    /// Exposed so the caller script can be exercised without a location fix.
    func set(_ location: CallerLocation?) {
        current = location
    }

    /// A new rescue may be somewhere else, and an address is only ever confirmed for its own run.
    func reset() {
        geocoding?.cancel()
        current = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.received(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    func received(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, current?.confirmed != true else { return }
        // Coordinates first. They need no network, and a street address may never come.
        let coordinate = location.coordinate
        let fallback = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        let accuracy = location.horizontalAccuracy
        if current?.address == nil || current?.accuracyMeters != accuracy {
            current = CallerLocation(address: current?.address ?? fallback, accuracyMeters: accuracy, confirmed: false)
        }

        geocoding?.cancel()
        geocoding = Task {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let items = try? await request.mapItems,
                  let address = items.first?.address?.fullAddress,
                  !Task.isCancelled,
                  self.current?.confirmed != true
            else { return }
            self.current = CallerLocation(address: address, accuracyMeters: accuracy, confirmed: false)
        }
    }
}
