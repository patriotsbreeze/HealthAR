#if canImport(AppKit)
import AppKit
#endif
import CoreText
import PlumbContracts
import SwiftUI
import Testing
@testable import PlumbUI

@MainActor
@Suite struct CommandTests {
    /// Every command the coach can ever show, in the words it is expected to use.
    nonisolated static let commands = ["PUSH NOW", "PUSH HARDER", "FASTER", "SLOWER", "GOOD"]

    /// The width SwiftUI itself gives a command set in the command face, in points.
    private func renderedWidth(_ command: String, unit: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: Text(command).font(Theme.Face.command(unit: unit)).fixedSize())
        renderer.scale = 1
        return CGFloat(try #require(renderer.cgImage).width)
    }

    private func room(in size: CGSize) -> (width: CGFloat, unit: CGFloat) {
        let plan = ScreenPlan(size: size, panelReferenceWidth: Theme.metrics.panelWidth)
        return (plan.panelWidth - 2 * Theme.metrics.panelPadding * plan.unit, plan.unit)
    }

    @Test func pushHarderFitsThePhonesPanelOnOneLine() throws {
        let (width, unit) = room(in: CGSize(width: 874, height: 402))
        #expect(width == 298)
        let needed = try renderedWidth("PUSH HARDER", unit: unit)
        #expect(needed <= width, "PUSH HARDER needs \(needed) pt and has \(width)")
        // It should also be close to the limit: the command is meant to be as large as the panel allows.
        #expect(needed > width * 0.9)
    }

    @Test(arguments: commands)
    func everyCommandFitsAtBothSizes(command: String) throws {
        for size in [CGSize(width: 874, height: 402), CGSize(width: 1280, height: 720)] {
            let (width, unit) = room(in: size)
            #expect(try renderedWidth(command, unit: unit) <= width)
        }
    }

    #if canImport(AppKit)
    /// The same measurement taken straight from the font, so the result does not rest on the renderer alone.
    @Test func theFontItselfAgrees() {
        let font = NSFont.systemFont(ofSize: Theme.metrics.commandSize, weight: .black, width: .compressed)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PUSH HARDER", attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        #expect(width <= 298)
        #expect(font.capHeight <= Theme.metrics.commandSlotHeight)
    }
    #endif

    #if canImport(AppKit)
    /// The first instruction may wrap once, and both of its lines must stand inside the command's slot.
    @Test func twoLinesOfTheFirstInstructionFitTheCommandSlot() {
        let font = NSFont.systemFont(ofSize: Theme.metrics.numeralFigure, weight: .semibold, width: .compressed)
        let lineHeight = font.ascender - font.descender + font.leading
        #expect(CGFloat(Theme.metrics.wrapLines) * lineHeight <= Theme.metrics.commandSlotHeight)
        // The command itself must still fit the slot it is named for.
        let command = NSFont.systemFont(ofSize: Theme.metrics.commandSize, weight: .black, width: .compressed)
        #expect(command.ascender - command.descender + command.leading <= Theme.metrics.commandSlotHeight)
    }
    #endif

    @Test func theCommandIsMuchLargerThanAnythingElseOnTheRescueScreen() {
        let metrics = Theme.metrics
        #expect(metrics.commandSize > metrics.numeralLarge)
        #expect(metrics.commandSize >= metrics.textBody * 3)
        #expect(metrics.numeralLarge >= metrics.numeralSmall * 2)
    }

    // MARK: How long a command stays

    @Test func aCorrectionStaysForAsLongAsItIsPassed() {
        #expect(CommandSlot.visible(command: "Push harder", tone: .fix, spent: nil) == "Push harder")
        #expect(CommandSlot.visible(command: "Push harder", tone: .fix, spent: "Push harder") == "Push harder")
    }

    @Test func anAffirmationGoesOnceItHasHadItsTime() {
        #expect(CommandSlot.visible(command: "Good", tone: .affirm, spent: nil) == "Good")
        #expect(CommandSlot.visible(command: "Good", tone: .affirm, spent: "Good") == nil)
        #expect(CommandSlot.visible(command: "Good", tone: .affirm, spent: "Nice") == "Good")
    }

    @Test func nothingShowsWhenThereIsNoCommand() {
        #expect(CommandSlot.visible(command: nil, tone: .fix, spent: nil) == nil)
        #expect(CommandSlot.visible(command: nil, tone: .affirm, spent: "Good") == nil)
    }

    @Test func goodStaysForACoupleOfSeconds() {
        #expect((1.5...3).contains(Theme.metrics.affirmSeconds))
    }

    @Test func everythingButTheBarsMovesInAboutATenthOfASecond() {
        #expect((0.1...0.15).contains(Theme.metrics.fadeSeconds))
        #expect((0.1...0.15).contains(Theme.metrics.stepSeconds))
    }
}
