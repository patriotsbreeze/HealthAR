#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PlumbUI

@Suite struct ChestTraceGeometryTests {
    private let geometry = ChestTraceGeometry(size: CGSize(width: 298, height: 140), fullScaleMM: 20)

    @Test func zeroRunsAcrossTheMiddleAndUpIsUpAtAFixedScale() {
        #expect(geometry.y(0) == 70)
        #expect(geometry.y(10) == 0)
        #expect(geometry.y(-10) == 140)
        #expect(geometry.y(2) < geometry.y(1))
        // Beyond full scale the line leaves the plot, to be cut off there, rather than being squashed onto it.
        #expect(geometry.y(15) < geometry.plot.minY)
    }

    @Test func theOldestValueIsAtTheLeftEdgeAndTheNewestAtTheRight() {
        #expect(geometry.x(index: 0, count: 300) == 0)
        #expect(geometry.x(index: 299, count: 300) == 298)
        #expect(abs(geometry.x(index: 150, count: 301) - 149) < 1e-9)
        #expect(geometry.x(index: 0, count: 1) == 298)
    }

    @Test func theLineBreaksWhereNothingWasMeasuredAndALonePointIsNoLine() {
        let runs = geometry.runs([nil, 1, 2, 3, nil, 4, nil, nil, 5, 6])
        #expect(runs.count == 2)
        #expect(runs[0].count == 3)
        #expect(runs[1].count == 2)
        #expect(runs[0][0] == CGPoint(x: geometry.x(index: 1, count: 10), y: geometry.y(1)))
        #expect(runs[1].last == CGPoint(x: 298, y: geometry.y(6)))
        #expect(geometry.runs(Array(repeating: nil, count: 300)).isEmpty)
    }

    @Test func theBandCoversTheRightHandShareAndIsAsTallAsTheThreshold() {
        let band = geometry.bandRect(-1.2...1.2, share: 8.0 / 30)
        #expect(abs(band.maxX - 298) < 1e-9)
        #expect(abs(band.width - 298 * 8 / 30) < 1e-9)
        #expect(abs(band.height - 2.4 / 20 * 140) < 1e-9)
        #expect(abs(band.midY - 70) < 1e-9)
        #expect(geometry.bandRect(0...1, share: 3).width == 298)
        #expect(geometry.bandRect(0...1, share: -1).width == 0)
    }

    @Test func aStillChestInsideItsBandIsDrawnInsideTheBand() {
        let values: [Double?] = (0..<80).map { Double($0 % 5) * 0.2 - 0.4 }
        let band = geometry.bandRect(-1.2...1.2, share: 1)
        for point in geometry.runs(values).joined() {
            #expect(point.y >= band.minY && point.y <= band.maxY)
        }
    }
}

@MainActor
@Suite struct ChestScreenTests {
    nonisolated static let phone = CGSize(width: 874, height: 402)
    nonisolated static let mirrored = CGSize(width: 1280, height: 720)
    nonisolated static let scale: CGFloat = 2

    typealias Palette = Theme.Palette

    private func image(of view: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = Self.scale
        return try #require(renderer.cgImage)
    }

    /// Draws a view, saves the picture to Packages/UI/.previews for review, and returns its pixels.
    @discardableResult
    private func render(_ view: some View, as name: String, size: CGSize = phone) throws -> Pixels {
        let image = try image(of: view, size: size)
        try FileManager.default.createDirectory(at: RenderTests.folder, withIntermediateDirectories: true)
        let url = RenderTests.folder.appendingPathComponent("\(name).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return try #require(Pixels(image))
    }

    /// The camera, the whole panel, the headline slot and the trace, in pixels of a render.
    private func regions(of size: CGSize = phone) -> (camera: CGRect, panel: CGRect, headline: CGRect, trace: CGRect) {
        let plan = ScreenPlan(size: size, panelReferenceWidth: Theme.metrics.panelWidth)
        let metrics = Theme.metrics
        let unit = plan.unit
        let top = (size.height - plan.pictureSize.height) / 2
        let camera = CGRect(x: 0, y: top, width: plan.pictureSize.width, height: plan.pictureSize.height)
        let panel = CGRect(x: plan.pictureSize.width, y: 0, width: plan.panelWidth, height: size.height)
        let content = panel.insetBy(dx: metrics.panelPadding * unit, dy: 0)
        let headline = CGRect(x: content.minX, y: metrics.topPadding * unit, width: content.width,
                              height: Theme.chest.headlineHeight * unit)
        let below = metrics.rowGap * unit + Theme.chest.contextHeight * unit + metrics.ruleWidth * unit
            + metrics.controlHeight * unit
        let trace = CGRect(x: content.minX, y: headline.maxY + metrics.rowGap * unit, width: content.width,
                           height: size.height - headline.maxY - metrics.rowGap * unit - below)
        let toPixels = CGAffineTransform(scaleX: Self.scale, y: Self.scale)
        return (camera.applying(toPixels), panel.applying(toPixels), headline.applying(toPixels),
                trace.applying(toPixels))
    }

    /// Nothing is drawn over the camera, the panel is there, and the AED green is nowhere on this screen.
    private func expectPlainScreen(_ pixels: Pixels, size: CGSize = phone) {
        let parts = regions(of: size)
        #expect(pixels.isFlat(Fixture.pictureSwatch, in: parts.camera.insetBy(dx: 2, dy: 2)))
        #expect(pixels.count(of: Palette.ground, in: parts.panel) > 1_000)
        #expect(pixels.count(of: Palette.paper, in: parts.panel) > 100)
        #expect(pixels.count(of: Palette.aed, in: pixels.bounds) == 0)
    }

    /// The accent appears in the headline slot and nowhere else: not on the picture, the trace or the controls.
    private func expectAccentOnlyInTheHeadline(_ pixels: Pixels, size: CGSize = phone) {
        let parts = regions(of: size)
        let belowHeadline = CGRect(x: parts.panel.minX, y: parts.headline.maxY, width: parts.panel.width,
                                   height: parts.panel.maxY - parts.headline.maxY)
        #expect(pixels.count(of: Palette.accent, in: parts.headline) > 1_000)
        #expect(pixels.count(of: Palette.accent, in: belowHeadline) == 0)
        #expect(pixels.count(of: Palette.accent, in: parts.camera) == 0)
    }

    // MARK: States

    @Test func tapTheChest() throws {
        let pixels = try render(ChestFixture.tapTheChest, as: "chest-01-tap-the-chest")
        expectPlainScreen(pixels)
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) == 0)
        // Nothing measured, so no line: the trace is bare ground.
        #expect(pixels.isFlat(Palette.ground, in: regions().trace))
    }

    @Test func movementSeen() throws {
        let pixels = try render(ChestFixture.movementSeen, as: "chest-02-movement-seen")
        expectPlainScreen(pixels)
        // Movement seen is a reading, not something to fix, so nothing is in the accent.
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) == 0)
        // The line is drawn in the quiet colour.
        #expect(pixels.count(of: Palette.quietOnGround, in: regions().trace) > 300)
        #expect(pixels.count(of: Palette.paper, in: regions().trace) == 0)
    }

    @Test func startPushing() throws {
        let pixels = try render(ChestFixture.startPushing, as: "chest-03-start-pushing")
        expectPlainScreen(pixels)
        expectAccentOnlyInTheHeadline(pixels)
        #expect(pixels.count(of: Palette.quietOnGround, in: regions().trace) > 300)
    }

    /// The command stays when the chest moves again. The screen draws what it is given, so this is the picture
    /// of that moment: the line moving under a command that has not gone.
    @Test func movementAfterThePrompt() throws {
        let pixels = try render(ChestFixture.movementAfterThePrompt, as: "chest-04-movement-after-the-prompt")
        expectPlainScreen(pixels)
        expectAccentOnlyInTheHeadline(pixels)
    }

    @Test func mirroredDisplayAndThePhonesSafeArea() throws {
        let mirrored = try render(ChestFixture.startPushing, as: "chest-05-start-pushing-1280x720", size: Self.mirrored)
        expectPlainScreen(mirrored, size: Self.mirrored)
        expectAccentOnlyInTheHeadline(mirrored, size: Self.mirrored)
        // The screen runs edge to edge like the rescue screen: the margins move nothing.
        let safe = try render(ChestFixture.startPushing.safeAreaPadding(RenderTests.phoneSafeArea),
                              as: "chest-06-start-pushing-phone-safe-area")
        expectPlainScreen(safe)
        expectAccentOnlyInTheHeadline(safe)
    }

    /// The command and the longest status both stand inside the headline slot and the panel's margins.
    @Test(arguments: [true, false])
    func theHeadlineStaysInsideItsSlot(isCommand: Bool) throws {
        for size in [Self.phone, Self.mirrored] {
            let view = ChestFixture.screen(status: "No chest movement seen for 125\u{00A0}s",
                                           command: isCommand ? "Start pushing" : nil,
                                           trace: Array(repeating: nil, count: ChestFixture.slots), band: nil)
            let pixels = try #require(Pixels(try image(of: view, size: size)))
            let slot = regions(of: size).headline
            let ink = try #require(pixels.bounds(of: isCommand ? Palette.accent : Palette.paper,
                                                 in: slot.insetBy(dx: -40, dy: -40)))
            #expect(ink.minY >= slot.minY && ink.maxY <= slot.maxY, "\(ink) outside \(slot) at \(size)")
            #expect(ink.minX >= slot.minX && ink.maxX <= slot.maxX, "\(ink) outside \(slot) at \(size)")
            // Two lines, whichever it is: taller than one line of its face could be.
            let face = isCommand ? Theme.metrics.commandSize : Theme.metrics.numeralFigure
            #expect(ink.height / Self.scale > face * plan(size).unit)
        }
    }

    private func plan(_ size: CGSize) -> ScreenPlan {
        ScreenPlan(size: size, panelReferenceWidth: Theme.metrics.panelWidth)
    }

    // MARK: The command's two lines

    /// "START PUSHING" is wider than the panel, so each word takes a line. Each must fit the panel by itself.
    @Test func eachWordOfTheCommandFitsThePanel() throws {
        for size in [Self.phone, Self.mirrored] {
            let plan = plan(size)
            let room = plan.panelWidth - 2 * Theme.metrics.panelPadding * plan.unit
            for word in ["START", "PUSHING"] {
                let renderer = ImageRenderer(content: Text(word).font(Theme.Face.command(unit: plan.unit)).fixedSize())
                renderer.scale = 1
                let width = CGFloat(try #require(renderer.cgImage).width)
                #expect(width <= room, "\(word) needs \(width) pt and has \(room)")
            }
        }
    }

    #if canImport(AppKit)
    @Test func twoLinesOfTheCommandFitTheHeadlineSlot() {
        let command = NSFont.systemFont(ofSize: Theme.metrics.commandSize, weight: .black, width: .compressed)
        let lineHeight = command.ascender - command.descender + command.leading
        #expect(CGFloat(Theme.metrics.wrapLines) * lineHeight <= Theme.chest.headlineHeight)
        // And the slot is not much taller than it needs to be.
        #expect(CGFloat(Theme.metrics.wrapLines) * lineHeight > Theme.chest.headlineHeight * 0.85)
    }
    #endif

    /// The panel, laid out top to bottom on the phone, leaves the trace a useful height.
    @Test func theTraceKeepsAUsefulHeightOnThePhone() {
        let trace = regions().trace
        #expect(trace.height / Self.scale >= 120, "trace is \(trace.height / Self.scale) pt tall")
    }
}
