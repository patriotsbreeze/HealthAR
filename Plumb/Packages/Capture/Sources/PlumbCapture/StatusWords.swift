import ARKit
import Foundation

/// The plain words the status uses for states that come from the system.
enum StatusWords {
    /// World tracking in one word a person can read.
    static func tracking(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "unavailable"
        case .limited(.initializing): return "starting"
        case .limited(.excessiveMotion): return "moving"
        case .limited(.insufficientFeatures): return "featureless"
        case .limited(.relocalizing): return "relocalizing"
        case .limited: return "limited"
        }
    }

    /// The phone's thermal state in one word.
    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
