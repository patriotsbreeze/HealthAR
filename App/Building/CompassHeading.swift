import CoreLocation
import Foundation
import Observation

/// The phone's compass heading for the calibrate arrow. Its own manager, the same nonisolated
/// delegate pattern as `LocationService`, and it never asks for permission: without location access
/// there's no true heading, and the magnetic one stands in.
@MainActor
@Observable
final class CompassHeading: NSObject, CLLocationManagerDelegate {
    /// Degrees clockwise from north. Nil until the first reading, and on a phone with no compass.
    private(set) var degrees: Double?
    /// False where there's no magnetometer, the Simulator among them.
    let available: Bool

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        available = CLLocationManager.headingAvailable()
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
    }

    func start() {
        guard available else { return }
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let reading = Compass.heading(true: newHeading.trueHeading, magnetic: newHeading.magneticHeading)
        Task { @MainActor in self.degrees = reading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}

    /// The system's figure-eight prompt would cover the arrow mid-demo.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { false }
}
