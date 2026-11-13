import Foundation

/// Vision work allowed at a thermal state. It has no audio field by design: the metronome and
/// phrases live in another package this one can't reach, and load is never shed from them.
struct VisionLoad: Sendable, Equatable {
    var uplinkIntervalScale: Double
    var poseFramesPerSecond: Double
    var arEnabled: Bool
}

/// Sheds in order: fewer frames, slower inference, AR off.
enum ThermalGovernor {
    static func load(for state: ProcessInfo.ThermalState) -> VisionLoad {
        switch state {
        case .nominal:
            VisionLoad(uplinkIntervalScale: 1, poseFramesPerSecond: 30, arEnabled: true)
        case .fair:
            VisionLoad(uplinkIntervalScale: 2, poseFramesPerSecond: 30, arEnabled: true)
        case .serious:
            VisionLoad(uplinkIntervalScale: 2, poseFramesPerSecond: 15, arEnabled: true)
        case .critical:
            VisionLoad(uplinkIntervalScale: 2, poseFramesPerSecond: 15, arEnabled: false)
        @unknown default:
            VisionLoad(uplinkIntervalScale: 2, poseFramesPerSecond: 15, arEnabled: false)
        }
    }
}
