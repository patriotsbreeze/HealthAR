import SwiftUI

extension Theme {
    /// One palette colour kept as plain sRGB numbers, so its contrast can be computed as well as drawn.
    public struct Swatch: Equatable, Sendable {
        /// Red in sRGB, 0...1.
        public let red: Double
        /// Green in sRGB, 0...1.
        public let green: Double
        /// Blue in sRGB, 0...1.
        public let blue: Double

        /// A colour from sRGB parts, each 0...1.
        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// A colour from a six-digit hex value such as 0x0B0D11.
        public init(hex: UInt32) {
            self.init(red: Double((hex >> 16) & 0xFF) / 255,
                      green: Double((hex >> 8) & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255)
        }

        /// The same colour for SwiftUI drawing.
        public var color: Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }

        /// WCAG relative luminance: 0 for black, 1 for white.
        public var luminance: Double {
            func linear(_ part: Double) -> Double {
                part <= 0.04045 ? part / 12.92 : pow((part + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG contrast ratio against another colour, from 1 (the same) to 21 (black on white).
        public func contrast(against other: Swatch) -> Double {
            let lighter = max(luminance, other.luminance)
            let darker = min(luminance, other.luminance)
            return (lighter + 0.05) / (darker + 0.05)
        }
    }
}
