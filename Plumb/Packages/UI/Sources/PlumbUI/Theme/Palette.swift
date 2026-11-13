import SwiftUI

extension Theme {
    /// The five colours. Each has one meaning and is never borrowed for another.
    public enum Palette {
        /// The ground of the rescue screen: a near-black with a slight cool cast. Also the ink on paper.
        public static let ground = Swatch(hex: 0x0B0D11)
        /// A neutral off-white: text, bars and marks on the ground, and the ground of the handoff.
        public static let paper = Swatch(hex: 0xF0EFEA)
        /// The quiet grey for units and context, in the tone that reads on the dark ground.
        public static let quietOnGround = Swatch(hex: 0x8B9097)
        /// The quiet grey for units and context, in the tone that reads on paper.
        public static let quietOnPaper = Swatch(hex: 0x5C6067)
        /// The one accent, a hot orange-red. It only ever means "fix this now". On paper it is a fill, never text.
        public static let accent = Swatch(hex: 0xF8431A)
        /// The green of the AED sign. Used for the AED and nothing else.
        public static let aed = Swatch(hex: 0x2FC47A)
    }

    /// One of the two grounds a screen is drawn on, with the tones that sit on it.
    public enum Surface: Sendable, Equatable {
        /// The dark ground of the rescue and show-working screens.
        case ground
        /// The light ground of the handoff.
        case paper

        /// The colour of the ground itself.
        public var fill: Swatch {
            self == .ground ? Palette.ground : Palette.paper
        }

        /// The colour of text, bars and marks on this ground.
        public var mark: Swatch {
            self == .ground ? Palette.paper : Palette.ground
        }

        /// The quiet grey in the tone that passes contrast on this ground.
        public var quiet: Swatch {
            self == .ground ? Palette.quietOnGround : Palette.quietOnPaper
        }
    }
}

private struct SurfaceKey: EnvironmentKey {
    static let defaultValue = Theme.Surface.ground
}

extension EnvironmentValues {
    /// Which ground the views below are drawn on. Controls and bars pick their tones from it.
    public var plumbSurface: Theme.Surface {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}
