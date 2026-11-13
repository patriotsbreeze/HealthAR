import SwiftUI

extension Theme {
    /// The three type roles, all cut from the system font. Sizes are multiplied by the screen unit.
    public enum Face {
        /// The command: compressed and very heavy, at one fixed size that never shrinks to fit a string.
        public static func command(unit: CGFloat = 1) -> Font {
            Font.system(size: Theme.metrics.commandSize * unit, weight: .black).width(.compressed)
        }

        /// Numerals: compressed semibold with tabular digits, so a changing number holds still.
        public static func numeral(_ size: NumeralSize, unit: CGFloat = 1) -> Font {
            Font.system(size: size.points * unit, weight: .semibold).width(.compressed).monospacedDigit()
        }

        /// The standard text face, for the few sentences and the plain-word controls.
        public static func text(_ size: TextSize, unit: CGFloat = 1) -> Font {
            Font.system(size: size.points * unit, weight: .regular)
        }

        /// The sizes numerals are set at.
        public enum NumeralSize: Sendable {
            /// The one large number on a screen.
            case large
            /// The handoff headline and figures.
            case figure
            /// Quiet numbers such as the elapsed time.
            case small
            /// Labels on lines and axes.
            case label

            /// The size in reference points.
            public var points: CGFloat {
                switch self {
                case .large: Theme.metrics.numeralLarge
                case .figure: Theme.metrics.numeralFigure
                case .small: Theme.metrics.numeralSmall
                case .label: Theme.metrics.numeralLabel
                }
            }
        }

        /// The two sizes sentences are set at.
        public enum TextSize: Sendable {
            /// Sentences and controls.
            case body
            /// Captions and lists.
            case small

            /// The size in reference points.
            public var points: CGFloat {
                switch self {
                case .body: Theme.metrics.textBody
                case .small: Theme.metrics.textSmall
                }
            }
        }
    }
}
