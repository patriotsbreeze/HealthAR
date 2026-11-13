import SwiftUI

/// How a landscape screen is shared between a 4:3 picture on the left and a panel on the right.
public struct ScreenPlan: Equatable, Sendable {
    /// Scale of this screen against the phone's reference canvas. Type and spacing are multiplied by it.
    public let unit: CGFloat
    /// Size of the picture. Always 4:3, never cropped.
    public let pictureSize: CGSize
    /// Width left for the panel beside the picture.
    public let panelWidth: CGFloat

    /// Plans a screen of `size`, keeping at least `panelReferenceWidth` (in reference points) for the panel.
    public init(size: CGSize, panelReferenceWidth: CGFloat, metrics: Theme.Metrics = Theme.metrics) {
        let unit = Self.unit(for: size, metrics: metrics)
        let widest = max(0, size.width - panelReferenceWidth * unit)
        let width = min(widest, size.height * metrics.pictureAspect)
        self.unit = unit
        pictureSize = CGSize(width: width, height: width / metrics.pictureAspect)
        panelWidth = size.width - width
    }

    /// The scale of a screen of `size`: 1 on the phone, larger on a mirrored display.
    public static func unit(for size: CGSize, metrics: Theme.Metrics = Theme.metrics) -> CGFloat {
        let fit = min(size.width / metrics.referenceSize.width, size.height / metrics.referenceSize.height)
        return max(metrics.minimumUnit, fit)
    }
}

private struct UnitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// How much larger than the phone's reference canvas the views below are drawn. 1 on the phone.
    public var plumbUnit: CGFloat {
        get { self[UnitKey.self] }
        set { self[UnitKey.self] = newValue }
    }
}
