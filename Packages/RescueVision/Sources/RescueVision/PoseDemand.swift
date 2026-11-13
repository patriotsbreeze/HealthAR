import Foundation
import RescueCore

/// What pose work the current step wants, from the overlay the engine already sends. Pure, so
/// when pose runs, and so when the camera's pixels are taken at all, is pinned by tests.
enum PoseDemand: Sendable, Equatable {
    case none
    /// The one person lying down: the chest zone, the pads, and the hands guide in compressions.
    case lying(since: TimeInterval)
    /// The person nearest the tapped injury, seated or lying.
    case nearPin

    /// Full rate for this long, to lock on fast, then a cap to save heat.
    static let fastLockSeconds: TimeInterval = 3
    static let lyingCap = 15.0
    static let nearPinCap = 10.0

    /// - Parameters:
    ///   - handsGuide: The window the coordinator opened as compressions began, if any.
    ///   - pinLive: A tapped pin under its 20 s.
    ///   - holdsLimb: A limb segment locked near the pin and pose still tracks it.
    static func demand(
        target: OverlayTarget?,
        enteredAt: TimeInterval,
        handsGuide: Range<TimeInterval>?,
        pinLive: Bool,
        holdsLimb: Bool,
        now: TimeInterval
    ) -> PoseDemand {
        switch target {
        case .chestCenter, .padZones:
            return .lying(since: enteredAt)
        case .injurySite:
            // No pin, no pose: a limb step costs the camera nothing until someone taps.
            return pinLive || holdsLimb ? .nearPin : .none
        case .aedDevice:
            return .none
        case nil:
            // Compressions takes no pixels, except for the hands guide the coordinator asked for.
            guard let handsGuide, handsGuide.contains(now) else { return .none }
            return .lying(since: handsGuide.lowerBound)
        }
    }

    /// Zero when nothing is wanted.
    func framesPerSecond(load: VisionLoad, now: TimeInterval) -> Double {
        switch self {
        case .none:
            0
        case let .lying(since):
            now - since < Self.fastLockSeconds ? load.poseFramesPerSecond : min(load.poseFramesPerSecond, Self.lyingCap)
        case .nearPin:
            min(load.poseFramesPerSecond, Self.nearPinCap)
        }
    }
}
