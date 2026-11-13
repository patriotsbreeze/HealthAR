import Foundation

/// What the sensors say about one proposed point.
public struct SceneVerdict: Sendable, Equatable {
    /// How far the point got through the checks. Later cases are closer to being accepted.
    public enum Finding: Int, Sendable, Comparable {
        /// The sensor could not measure the spot or the surface around it, or not cleanly enough.
        case unmeasured
        /// Too near or too far for the sensor to be trusted.
        case outOfRange
        /// Nothing stands out from the surface there.
        case flat
        /// Something stands out, but it is too small or too big.
        case wrongSize
        /// Something stands out, but it runs off the edge of the grid, so its size is not known.
        case cutOff
        /// Something of the right size stands out from the surface behind it.
        case plausible

        /// Orders findings by how close they came to being accepted.
        public static func < (lhs: Finding, rhs: Finding) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The last check the point reached.
    public var finding: Finding
    /// Distance to the object, or to the surface at the point when nothing stands out. Metres.
    public var distanceM: Double?
    /// How far the object stands out from the surface behind it, in metres.
    public var reliefM: Double?
    /// Real width of the object in metres.
    public var widthM: Double?
    /// Real height of the object in metres.
    public var heightM: Double?
    /// One plain sentence saying why.
    public var reason: String

    /// True only when every check passed.
    public var accepted: Bool { finding == .plausible }

    /// Creates a verdict. Measurements that were never taken stay nil.
    public init(finding: Finding, distanceM: Double? = nil, reliefM: Double? = nil, widthM: Double? = nil,
                heightM: Double? = nil, reason: String) {
        self.finding = finding
        self.distanceM = distanceM
        self.reliefM = reliefM
        self.widthM = widthM
        self.heightM = heightM
        self.reason = reason
    }
}
