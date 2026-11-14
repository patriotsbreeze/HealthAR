import SwiftUI
import UIKit

/// Clinical night. The camera first, a near-black deck, white type, and one meaning per color. Every
/// color, size and timing a view uses comes from here, so a view that needs something missing here is
/// asking for a new meaning. That's a design decision before it's a code one.
enum DS {}

extension UIColor {
    /// 0xRRGGBB, sRGB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// 0xRRGGBB, sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Follows Increase Contrast by itself, in views and in a Canvas alike.
    static func adaptive(_ normal: UIColor, increased: UIColor) -> Color {
        Color(uiColor: UIColor { $0.accessibilityContrast == .high ? increased : normal })
    }
}

extension DS {
    /// The hex values, so the contrast test reads the same numbers the views draw with.
    enum Hex {
        static let canvas: UInt32 = 0x000000
        static let surface: UInt32 = 0x151517
        static let surfaceRaised: UInt32 = 0x232326
        static let holdSweep: UInt32 = 0x48484A
        static let textPrimary: UInt32 = 0xF5F5F7
        static let textSecondary: UInt32 = 0xA1A1A6
        static let textSecondaryIncreased: UInt32 = 0xC7C7CC
        static let textTertiary: UInt32 = 0x6E6E73
        static let ink: UInt32 = 0x000000
        static let primaryFill: UInt32 = 0xF5F5F7
        static let target: UInt32 = 0x3CD3FE
        static let item: UInt32 = 0xFFFFFF
        static let critical: UInt32 = 0xFF453A
        static let criticalFill: UInt32 = 0xC4141C
        static let caution: UInt32 = 0xFFB340
        static let ok: UInt32 = 0x30D158
    }

    /// Dark only, since the app forces dark. Ratios in the comments are against `surface`.
    enum Colors {
        static let canvas = Color(hex: Hex.canvas)
        /// The deck, sheets, AR billboards and pills.
        static let surface = Color(hex: Hex.surface)
        /// Secondary and answer buttons, rows.
        static let surfaceRaised = Color(hex: Hex.surfaceRaised)
        /// A neutral hold filling up. White on it is 8.4:1.
        static let holdSweep = Color(hex: Hex.holdSweep)
        static let textPrimary = Color(hex: Hex.textPrimary)
        static let textSecondary = Color.adaptive(UIColor(hex: Hex.textSecondary), increased: UIColor(hex: Hex.textSecondaryIncreased))
        /// 3.6:1. Only for text nobody needs, like a source citation.
        static let textTertiary = Color(hex: Hex.textTertiary)
        static let hairline = Color.adaptive(UIColor(white: 1, alpha: 0.10), increased: UIColor(white: 1, alpha: 0.24))
        /// Labels on primaryFill, caution and target.
        static let ink = Color(hex: Hex.ink)
        static let primaryFill = Color(hex: Hex.primaryFill)

        // Meanings. One each, and the comment is all of it.
        /// Act here: a body zone, the body-part noun, the beat.
        static let target = Color(hex: Hex.target)
        /// Grab this: an item in the room. Brackets, leaders, the item's pointer.
        static let item = Color(hex: Hex.item)
        /// Life threat, Start CPR, leaving CPR. Text and strokes.
        static let critical = Color(hex: Hex.critical)
        /// The same meaning as a fill under white text.
        static let criticalFill = Color(hex: Hex.criticalFill)
        /// A degraded system, and the simulation strip.
        static let caution = Color(hex: Hex.caution)
        /// Live or confirmed. Never decoration.
        static let ok = Color(hex: Hex.ok)

        // AR. Cyan on light skin is about 1:1 alone, so every mark sits on a black keyline.
        static let keyline = Color.adaptive(UIColor(white: 0, alpha: 0.60), increased: UIColor(white: 0, alpha: 0.85))
        /// The wide under-stroke. A flat stroke, not a blur, so it costs nothing and reads as no glow.
        static let underStroke = Color(hex: 0x000000, opacity: 0.40)
    }
}

/// SF Pro in Regular, Semibold or Bold only, scaled from a text style so Dynamic Type moves it.
struct DSFont: Equatable, Sendable {
    var size: CGFloat
    var weight: Font.Weight
    var relativeTo: Font.TextStyle
    var monospacedDigits = false

    func points(for typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFontMetrics(forTextStyle: relativeTo.uiKit).scaledValue(for: size, compatibleWith: traits)
    }

    func font(for typeSize: DynamicTypeSize) -> Font {
        let font = Font.system(size: points(for: typeSize), weight: weight)
        return monospacedDigits ? font.monospacedDigit() : font
    }
}

extension DS {
    enum Fonts {
        /// The step. Never shrinks past 0.85, so it stays readable at a glance.
        static let command = DSFont(size: 34, weight: .bold, relativeTo: .largeTitle)
        /// A camera step's step. SAFETY.md holds it at 24 pt, so the band keeps its room.
        static let commandCompact = DSFont(size: 24, weight: .bold, relativeTo: .title)
        static let confirm = DSFont(size: 34, weight: .bold, relativeTo: .largeTitle)
        static let title = DSFont(size: 22, weight: .bold, relativeTo: .title2)
        static let detail = DSFont(size: 20, weight: .semibold, relativeTo: .title3)
        static let detailCompact = DSFont(size: 15, weight: .semibold, relativeTo: .subheadline)
        static let prompt = DSFont(size: 17, weight: .semibold, relativeTo: .headline)
        static let body = DSFont(size: 17, weight: .regular, relativeTo: .body)
        static let button = DSFont(size: 19, weight: .semibold, relativeTo: .title3)
        /// The way-out row a size down, so Not responding now stays on one line on a small phone.
        static let buttonTight = DSFont(size: 16, weight: .semibold, relativeTo: .title3)
        static let buttonCompact = DSFont(size: 15, weight: .semibold, relativeTo: .subheadline)
        /// Three to a row, or a long hold label on a camera step, where 15 pt would wrap to three lines.
        static let buttonSmall = DSFont(size: 13, weight: .semibold, relativeTo: .footnote)
        /// AR billboards, pills, alert rows, the why headline.
        static let label = DSFont(size: 15, weight: .semibold, relativeTo: .subheadline)
        static let meta = DSFont(size: 13, weight: .semibold, relativeTo: .footnote, monospacedDigits: true)
        static let caption = DSFont(size: 13, weight: .regular, relativeTo: .footnote)
        static let strip = DSFont(size: 13, weight: .semibold, relativeTo: .footnote)
        static let badge = DSFont(size: 12, weight: .semibold, relativeTo: .caption)
        static let value = DSFont(size: 17, weight: .semibold, relativeTo: .body, monospacedDigits: true)
    }
}

private struct DSFontModifier: ViewModifier {
    let token: DSFont
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.font(token.font(for: typeSize))
    }
}

extension View {
    func dsFont(_ token: DSFont) -> some View { modifier(DSFontModifier(token: token)) }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}

extension DS {
    /// A 4 pt grid. The deck padding and the gutter share 16, so text lines up down the screen.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let gutter: CGFloat = 16
        static let deckInset: CGFloat = 8
        static let deckPadding: CGFloat = 16
        static let betweenButtons: CGFloat = 8
    }

    /// Three families and nothing else: the deck, capsules for anything pressed, 14 for rows and cards.
    enum Radius {
        static let deck: CGFloat = 28
        static let row: CGFloat = 14
    }

    /// Minimum heights. These are the pinned gloved-hand sizes, and a label that needs more grows the button.
    enum Height {
        /// Start CPR and Resume CPR on the arrest path.
        static let arrestPrimary: CGFloat = 84
        static let arrest: CGFloat = 68
        /// No, keep pushing.
        static let stopCancel: CGFloat = 96
        /// Yes, stop CPR.
        static let stopConfirm: CGFloat = 84
        /// Answers, triage and steps when someone is awake.
        static let awake: CGFloat = 56
        static let awakeHold: CGFloat = 58
        /// Start CPR and Not responding now, outside the scroll.
        static let awakeWayOut: CGFloat = 60
        /// Holds on a camera step, and the standing row.
        static let camera: CGFloat = 48
        static let strip: CGFloat = 28
        static let rail: CGFloat = 44
        static let pill: CGFloat = 28
        /// The one glass button, and every other small control.
        static let control: CGFloat = 44
        static let alertRow: CGFloat = 32
    }

    /// The least band a step keeps. Only the camera step's is a promise to someone aiming.
    enum Band {
        static let arrest: CGFloat = 100
        /// A guide card's own height with its margin.
        static let guide: CGFloat = 92
        static let camera: CGFloat = 112
    }

    enum Pulse {
        /// Centered in compressions. The overlay's keep-off column is sized from this.
        static let standard: CGFloat = 170
        /// Top-trailing when the step also draws on the camera, so the body stays clear.
        static let docked: CGFloat = 96
        static let sheet: CGFloat = 44
        static let confirmation: CGFloat = 88
        static let dockedInset: CGFloat = 12
    }

    enum Listening {
        static let orb: CGFloat = 56
        /// The glow reaches out to this, and it's the bubble's whole height.
        static let frame: CGFloat = 88
    }

    /// No bounce anywhere. Motion explains a change, or it doesn't happen.
    enum Motion {
        static let stepIn = Animation.smooth(duration: 0.30, extraBounce: 0)
        static let stepOut = Animation.easeOut(duration: 0.12)
        static let stepRise: CGFloat = 6
        static let press = Animation.snappy(duration: 0.18, extraBounce: 0)
        static let deck = Animation.smooth(duration: 0.35, extraBounce: 0)
        static let alert = Animation.easeOut(duration: 0.15)
        // The overlay draws by the clock, so these are durations, not Animations.
        static let lockIn: TimeInterval = 0.28
        static let lockScale: CGFloat = 1.12
        static let lostGrace: TimeInterval = 0.5
    }

    enum Haptics {
        static let step: SensoryFeedback = .impact(weight: .medium)
        static let compressions: SensoryFeedback = .impact(weight: .heavy)
        static let holdBegan: SensoryFeedback = .impact(weight: .light)
        static let holdDone: SensoryFeedback = .impact(weight: .heavy)
        static let stopAsked: SensoryFeedback = .warning
        static let alert: SensoryFeedback = .warning
    }

    /// Every AR stroke is four layers: a wide under-stroke, the fill, a black keyline, the colored stroke.
    enum AR {
        /// The ghost's flat marks. Its bodies are 3D, with their opacity in `GhostPlacement`.
        enum Ghost {
            /// Metres, scaled by distance on screen, then held to `limbWidth`.
            static let limbMetres = 0.08
            static let headMetres = 0.1
            static let limbWidth: ClosedRange<CGFloat> = 5...24
            static let keyline: CGFloat = 3
            /// The hands' press ring, at full strength only on the click.
            static let pressRing: CGFloat = 18
            static let pressRingWidth: CGFloat = 2.5
        }

        static let underWidth: CGFloat = 13
        static let keylineWidth: CGFloat = 7
        static let strokeWidth: CGFloat = 3.5
        /// Dash and gap as they look, for the colored stroke alone: the under-stroke and keyline stay
        /// solid, so the dark rim holds its contrast and only the color breaks up. Round caps, so the
        /// pattern drawn is shortened by the stroke's width. A small shape gets the short one.
        static let dash: [CGFloat] = [10, 7]
        static let dashSmall: [CGFloat] = [6, 5]
        /// Shapes smaller than this on their longer side, like a pad, take `dashSmall`.
        static let dashSmallBelow: CGFloat = 90
        static let fill = 0.22
        static let underHandFill = 0.14
        /// Under the upper hand's fill, so where it lies over the lower hand it reads as on top of it.
        static let overHandBase = 0.85
        static let heelFill = 0.5
        static let itemStroke: CGFloat = 3
        static let itemKeyline: CGFloat = 6.5
        static let itemUnder: CGFloat = 11
        static let bracketArm: ClosedRange<CGFloat> = 14...28
        static let bracketArmFraction: CGFloat = 0.2
        static let leaderWidth: CGFloat = 1.5
        static let leaderKeyline: CGFloat = 4
        static let leaderDot: CGFloat = 5
        static let pressRingMinRadius: CGFloat = 22
        static let limbMinWidth: CGFloat = 28
        static let pointerDisc: CGFloat = 44
        /// The pointer keeps this far in from the band's sides and from its top and bottom.
        static let pointerInset = CGSize(width: 24, height: 8)
        static let itemNominal = CGSize(width: 64, height: 64)
        static let chipPadding = CGSize(width: 10, height: 6)
        static let chipGap: CGFloat = 12
        /// A band shorter than this has room for nothing but the buttons under it.
        static let leastBand: CGFloat = 36
        static let maxZones = 1
        static let maxItems = 2
        static let maxPointers = 1
        /// Labels drawn over the camera stop growing here, so they never hide what they label.
        static let typeCap: DynamicTypeSize = .xxxLarge
    }
}

extension AnyTransition {
    /// The new step rises 6 pt into place. The old one only fades, quickly, so nothing slides under a finger.
    static func step(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: DS.Motion.stepRise)),
                removal: .opacity.animation(DS.Motion.stepOut)
            )
    }
}
