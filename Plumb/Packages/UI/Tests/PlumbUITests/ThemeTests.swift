import Testing
@testable import PlumbUI

@Suite struct ThemeTests {
    typealias Palette = Theme.Palette

    /// WCAG AA for body text.
    static let textContrast = 4.5
    /// WCAG AA for graphics that carry meaning, such as a filled bar.
    static let fillContrast = 3.0

    @Test func contrastFormulaMatchesWCAG() {
        let black = Theme.Swatch(red: 0, green: 0, blue: 0)
        let white = Theme.Swatch(red: 1, green: 1, blue: 1)
        #expect(abs(white.contrast(against: black) - 21) < 1e-9)
        #expect(abs(black.contrast(against: white) - 21) < 1e-9)
        #expect(white.contrast(against: white) == 1)
        // The published example: #777 on white is 4.48:1, just short of AA.
        let grey = Theme.Swatch(hex: 0x777777)
        #expect(abs(grey.contrast(against: white) - 4.48) < 0.01)
    }

    @Test func hexReadsEachChannel() {
        let swatch = Theme.Swatch(hex: 0xFF8000)
        #expect(swatch.red == 1)
        #expect(abs(swatch.green - 128.0 / 255) < 1e-12)
        #expect(swatch.blue == 0)
    }

    /// Every pairing the screens actually set text in.
    @Test(arguments: [
        ("text on the ground", Palette.paper, Palette.ground),
        ("quiet text on the ground", Palette.quietOnGround, Palette.ground),
        ("the command on the ground", Palette.accent, Palette.ground),
        ("Find AED on the ground", Palette.aed, Palette.ground),
        ("text on paper", Palette.ground, Palette.paper),
        ("quiet text on paper", Palette.quietOnPaper, Palette.paper),
        ("the pause count on its accent block", Palette.ground, Palette.accent),
    ])
    func textPairsPassAA(name: String, text: Theme.Swatch, ground: Theme.Swatch) {
        let ratio = text.contrast(against: ground)
        #expect(ratio >= Self.textContrast, "\(name) is \(ratio):1")
    }

    @Test func accentIsStrongEnoughAsAFillOnPaper() {
        #expect(Palette.accent.contrast(against: Palette.paper) >= Self.fillContrast)
    }

    @Test func groundIsAChosenBlackWithACoolCast() {
        let ground = Palette.ground
        #expect(ground != Theme.Swatch(hex: 0x000000))
        #expect(ground.blue > ground.green && ground.green > ground.red)
        #expect(ground.luminance < 0.01)
    }

    @Test func paperIsNeutral() {
        let paper = Palette.paper
        let spread = max(paper.red, paper.green, paper.blue) - min(paper.red, paper.green, paper.blue)
        #expect(spread < 0.03)
        #expect(paper != Theme.Swatch(hex: 0xFFFFFF))
    }

    @Test func eachSurfaceUsesTheOtherAsItsMark() {
        #expect(Theme.Surface.ground.fill == Palette.ground)
        #expect(Theme.Surface.ground.mark == Palette.paper)
        #expect(Theme.Surface.ground.quiet == Palette.quietOnGround)
        #expect(Theme.Surface.paper.fill == Palette.paper)
        #expect(Theme.Surface.paper.mark == Palette.ground)
        #expect(Theme.Surface.paper.quiet == Palette.quietOnPaper)
    }
}
