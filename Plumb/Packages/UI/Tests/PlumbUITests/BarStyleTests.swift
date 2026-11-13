import PlumbContracts
import Testing
@testable import PlumbUI

@Suite struct BarStyleTests {
    private func style(reached: Bool, trust: LockState) -> BarStyle {
        BarStyle(StrokeBar(depthMM: 50, reached: reached, trust: trust))
    }

    @Test func trustedPushesAreJudged() {
        #expect(style(reached: true, trust: .locked) == .reached)
        #expect(style(reached: false, trust: .locked) == .short)
    }

    @Test(arguments: [true, false])
    func estimatesAreOutlinedWithoutJudgement(reached: Bool) {
        #expect(style(reached: reached, trust: .estimating) == .outline)
    }

    @Test(arguments: [LockState.rateOnly, .lost], [true, false])
    func rhythmOnlyIsATick(trust: LockState, reached: Bool) {
        #expect(style(reached: reached, trust: trust) == .tick)
    }

    @Test func colourOnTheGround() {
        #expect(BarStyle.reached.swatch(on: .ground) == Theme.Palette.paper)
        #expect(BarStyle.short.swatch(on: .ground) == Theme.Palette.accent)
        #expect(BarStyle.outline.swatch(on: .ground) == Theme.Palette.quietOnGround)
        #expect(BarStyle.tick.swatch(on: .ground) == Theme.Palette.paper)
    }

    @Test func colourOnPaper() {
        #expect(BarStyle.reached.swatch(on: .paper) == Theme.Palette.ground)
        #expect(BarStyle.short.swatch(on: .paper) == Theme.Palette.accent)
        #expect(BarStyle.outline.swatch(on: .paper) == Theme.Palette.quietOnPaper)
        #expect(BarStyle.tick.swatch(on: .paper) == Theme.Palette.ground)
    }

    /// Good has no colour of its own, and the accent is never used for anything but a shortfall.
    @Test func onlyAShortfallTakesTheAccent() {
        for surface in [Theme.Surface.ground, .paper] {
            for style in [BarStyle.reached, .outline, .tick] {
                #expect(style.swatch(on: surface) != Theme.Palette.accent)
                #expect(style.swatch(on: surface) != Theme.Palette.aed)
            }
        }
    }

    @Test func aCompressionIsJudgedAgainstTheMinimumTarget() {
        func compression(_ depthMM: Double) -> Compression {
            Compression(index: 1, tTop: 0, tBottom: 0.2, depthMM: depthMM, intervalS: nil, lock: .locked)
        }
        #expect(StrokeBar(compression(50)).reached)
        #expect(!StrokeBar(compression(49.9)).reached)
        #expect(StrokeBar(compression(45), targets: Targets(depthMinMM: 40)).reached)
        #expect(StrokeBar(compression(52)).trust == .locked)
        #expect(StrokeBar(compression(52)).depthMM == 52)
    }
}
