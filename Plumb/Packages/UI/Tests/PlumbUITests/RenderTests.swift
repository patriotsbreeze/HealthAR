import Foundation
import ImageIO
import PlumbContracts
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PlumbUI

/// Draws every screen and state to a PNG in Packages/UI/.previews for a person to look at,
/// and checks the few things about each picture that a machine can be sure of.
@MainActor
@Suite struct RenderTests {
    nonisolated static let phone = CGSize(width: 874, height: 402)
    nonisolated static let mirrored = CGSize(width: 1280, height: 720)
    nonisolated static let scale: CGFloat = 2

    /// Packages/UI/.previews, found from this file so the tests can run from any directory.
    nonisolated static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".previews", isDirectory: true)

    typealias Palette = Theme.Palette

    private func image(of view: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = Self.scale
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(size.width * Self.scale))
        #expect(image.height == Int(size.height * Self.scale))
        return image
    }

    /// Draws a view without keeping the picture, for checks that need only its pixels.
    private func pixels(of view: some View, size: CGSize = phone) throws -> Pixels {
        try #require(Pixels(try image(of: view, size: size)))
    }

    /// Draws a view, saves the picture for review, and returns its pixels.
    @discardableResult
    private func render(_ view: some View, as name: String, size: CGSize = phone) throws -> Pixels {
        let image = try image(of: view, size: size)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let url = Self.folder.appendingPathComponent("\(name).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return try #require(Pixels(image))
    }

    /// The camera picture and the panel beside it, in pixels of a rescue render.
    private func regions(of size: CGSize = phone) -> (camera: CGRect, panel: CGRect) {
        let plan = ScreenPlan(size: size, panelReferenceWidth: Theme.metrics.panelWidth)
        let top = (size.height - plan.pictureSize.height) / 2
        let camera = CGRect(x: 0, y: top, width: plan.pictureSize.width, height: plan.pictureSize.height)
        let panel = CGRect(x: plan.pictureSize.width, y: 0, width: plan.panelWidth, height: size.height)
        let toPixels = CGAffineTransform(scaleX: Self.scale, y: Self.scale)
        return (camera.applying(toPixels), panel.applying(toPixels))
    }

    /// Nothing is ever drawn over the camera, and the panel is actually there.
    private func expectUntouchedCamera(_ pixels: Pixels, size: CGSize = phone) {
        let (camera, panel) = regions(of: size)
        #expect(pixels.isFlat(Fixture.pictureSwatch, in: camera.insetBy(dx: 2, dy: 2)))
        #expect(pixels.count(of: Palette.ground, in: panel) > 1_000)
        #expect(pixels.count(of: Palette.paper, in: panel) > 100)
    }

    // MARK: Rescue

    private func start(_ prompt: String = "Push hard and fast.") -> some View {
        Fixture.rescue(Fixture.panel(startPrompt: prompt, model: BarFieldModel(), rate: nil, elapsedSeconds: 0))
    }

    private var shallow: some View {
        let model = Fixture.model(Fixture.bars(Fixture.shallow), liveDepthMM: 27)
        return Fixture.rescue(Fixture.panel(command: "Push harder", model: model, rate: 104, elapsedSeconds: 10))
    }

    private var good: some View {
        // The newest push arrived a moment ago, so the picture catches the line answering it.
        let model = Fixture.model(Array(Fixture.bars(Fixture.corrected).dropLast()), liveDepthMM: 44)
        model.append(StrokeBar(depthMM: 54.5, reached: true, trust: .locked), at: Fixture.now.addingTimeInterval(-0.12))
        return Fixture.rescue(Fixture.panel(command: "Good", tone: .affirm, model: model, rate: 110, elapsedSeconds: 20))
    }

    private var estimating: some View {
        let model = Fixture.model(Fixture.bars(Fixture.corrected, trust: .estimating, scatterMM: 4),
                                  liveDepthMM: 33, trust: .estimating)
        return Fixture.rescue(Fixture.panel(model: model, rate: 109, elapsedSeconds: 20))
    }

    private var rateOnly: some View {
        let model = Fixture.model(Fixture.bars(Fixture.corrected, trust: .rateOnly), trust: .rateOnly)
        return Fixture.rescue(Fixture.panel(command: "Slower", model: model, rate: 128, rateInRange: false,
                                            elapsedSeconds: 20))
    }

    private var paused: some View {
        let model = Fixture.model(Fixture.bars(Fixture.corrected))
        model.setPause(seconds: 4, at: Fixture.now)
        return Fixture.rescue(Fixture.panel(command: "Push now", model: model, rate: nil, elapsedSeconds: 24))
    }

    @Test func rescueStart() throws {
        let pixels = try render(start(), as: "01-rescue-start")
        expectUntouchedCamera(pixels)
        // Before the first push there is nothing to fix, so nothing is in the accent.
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) == 0)
    }

    /// The command slot of a rescue render, in pixels.
    private func commandSlot(of size: CGSize = phone) -> CGRect {
        let plan = ScreenPlan(size: size, panelReferenceWidth: Theme.metrics.panelWidth)
        let metrics = Theme.metrics
        let slot = CGRect(x: plan.pictureSize.width + metrics.panelPadding * plan.unit, y: metrics.topPadding * plan.unit,
                          width: plan.panelWidth - 2 * metrics.panelPadding * plan.unit,
                          height: metrics.commandSlotHeight * plan.unit)
        return slot.applying(CGAffineTransform(scaleX: Self.scale, y: Self.scale))
    }

    /// The start state has one thing to say, so it is said at headline size, not in body text.
    @Test func theFirstInstructionIsSetLarge() throws {
        let ink = try #require(try pixels(of: start("Push hard.")).bounds(of: Palette.paper, in: commandSlot()))
        // No letter here hangs below the baseline, so the ink is as tall as the capitals:
        // about 22 points in the headline face, 12 in body text.
        #expect(ink.height / Self.scale >= 20, "the first instruction stands \(ink.height / Self.scale) pt tall")
    }

    /// A first instruction too long for one line wraps once and stays inside the slot.
    @Test func aLongFirstInstructionWrapsInsideTheSlot() throws {
        let pixels = try pixels(of: start("Kneel beside the chest. Push hard and fast."))
        let slot = commandSlot()
        let ink = try #require(pixels.bounds(of: Palette.paper, in: slot.insetBy(dx: 0, dy: -20)))
        #expect(ink.minY >= slot.minY && ink.maxY <= slot.maxY)
        #expect(ink.maxX <= slot.maxX)
        // Two lines: taller than one line of the headline face could be.
        #expect(ink.height / Self.scale > Theme.metrics.numeralFigure)
    }

    @Test func rescueShallow() throws {
        let pixels = try render(shallow, as: "02-rescue-push-harder")
        expectUntouchedCamera(pixels)
        #expect(pixels.count(of: Palette.accent, in: regions().panel) > 1_000)
    }

    @Test func rescueGood() throws {
        let pixels = try render(good, as: "03-rescue-good")
        expectUntouchedCamera(pixels)
        // Good is light bars reaching the line. It has no colour of its own.
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) == 0)
    }

    @Test func rescueEstimating() throws {
        let pixels = try render(estimating, as: "04-rescue-estimating")
        expectUntouchedCamera(pixels)
        // An estimate is never judged, so it is never in the accent.
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) == 0)
        #expect(pixels.count(of: Palette.quietOnGround, in: regions().panel) > 100)
    }

    @Test func rescueRateOnly() throws {
        let pixels = try render(rateOnly, as: "05-rescue-rate-only")
        expectUntouchedCamera(pixels)
        #expect(pixels.count(of: Palette.accent, in: regions().panel) > 100)
    }

    @Test func rescuePaused() throws {
        let pixels = try render(paused, as: "06-rescue-paused-4s")
        expectUntouchedCamera(pixels)
        #expect(pixels.count(of: Palette.accent, in: regions().panel) > 5_000)
    }

    /// The AED green appears on the rescue screen's one AED control and nowhere else in the app.
    @Test func greenIsOnlyForTheAED() throws {
        let rescue = try pixels(of: shallow)
        #expect(rescue.count(of: Palette.aed, in: regions().panel) > 20)
        #expect(rescue.count(of: Palette.aed, in: regions().camera) == 0)
        let handoff = try pixels(of: handoffFull)
        #expect(handoff.count(of: Palette.aed, in: handoff.bounds) == 0)
        let shown = try pixels(of: working)
        #expect(shown.count(of: Palette.aed, in: shown.bounds) == 0)
    }

    // MARK: Handoff

    private var handoffFull: some View {
        HandoffScreen(headline: HandoffFixture.headline, stats: HandoffFixture.full,
                      depthRange: HandoffFixture.depthRange, sentences: HandoffFixture.sentences,
                      onReadAloud: {}, onNewRescue: {})
    }

    private var handoffWithoutDepth: some View {
        HandoffScreen(headline: HandoffFixture.headline, stats: HandoffFixture.withoutDepth,
                      depthRange: nil, onReadAloud: {}, onNewRescue: {})
    }

    @Test func handoff() throws {
        let pixels = try render(handoffFull, as: "07-handoff")
        // The only light screen: paper to every corner, with dark ink and accent fills on it.
        for (x, y) in [(0, 0), (pixels.width - 1, 0), (0, pixels.height - 1), (pixels.width - 1, pixels.height - 1)] {
            #expect(pixels.matches(Palette.paper, x: x, y: y))
        }
        #expect(pixels.count(of: Palette.ground, in: pixels.bounds) > 5_000)
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) > 1_000)
    }

    /// The fullest page there can be: every caption and sentence on two lines, inside the phone's own margins.
    private var crowdedHandoff: some View {
        var stats = HandoffFixture.full
        stats.notRecorded += ["time of collapse", "changes of rescuer"]
        return HandoffScreen(headline: "CPR started 14:02. Ran 16 min 40 s. 13 pauses, longest 19 s.", stats: stats,
                             depthRange: HandoffFixture.depthRange,
                             sentences: ["Depth fell short for the first minute and reached the line after the first correction, then held.",
                                         "The longest pause, 9 s, came 2 min 16 s in, when the rescuer stopped to ask a question."],
                             onReadAloud: {}, onNewRescue: {})
            .safeAreaPadding(Self.phoneSafeArea)
    }

    @Test func handoffCrowded() throws {
        try render(crowdedHandoff, as: "17-handoff-crowded-phone-safe-area")
    }

    @Test func handoffDepthNotRecorded() throws {
        let pixels = try render(handoffWithoutDepth, as: "08-handoff-depth-not-recorded")
        #expect(pixels.matches(Palette.paper, x: 0, y: 0))
        // Pauses are still measured when depth is not, so their blocks are still there.
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) > 200)
    }

    // MARK: Show working

    private var working: some View {
        WorkingScreen(timeline: WorkingFixture.timeline, scores: WorkingFixture.scores,
                      failsWhen: WorkingFixture.failsWhen, selected: .decision(WorkingFixture.firstCueID),
                      onBack: {}) { Fixture.picture }
    }

    @Test func showWorking() throws {
        let pixels = try render(working, as: "09-show-working")
        let plan = ScreenPlan(size: Self.phone, panelReferenceWidth: Theme.metrics.workingPanelWidth)
        let picture = CGRect(x: 0, y: 0, width: plan.pictureSize.width * Self.scale,
                             height: plan.pictureSize.height * Self.scale)
        #expect(pixels.isFlat(Fixture.pictureSwatch, in: picture.insetBy(dx: 2, dy: 2)))
        #expect(pixels.count(of: Palette.accent, in: pixels.bounds) > 1_000)
    }

    // MARK: The phone's own margins

    /// The margins an iPhone Pro keeps clear in landscape: the sensor housing at each end, the home bar below.
    nonisolated static let phoneSafeArea = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)

    @Test func insideThePhonesSafeArea() throws {
        let rescue = try render(shallow.safeAreaPadding(Self.phoneSafeArea), as: "14-rescue-phone-safe-area")
        // The rescue screen runs edge to edge: the picture and the panel are exactly where they are without margins.
        expectUntouchedCamera(rescue)
        let handoff = try render(handoffFull.safeAreaPadding(Self.phoneSafeArea), as: "15-handoff-phone-safe-area")
        #expect(handoff.matches(Palette.paper, x: 0, y: 0))
        // The page stays inside the margins: nothing but paper in the strips beside it.
        let strip = CGRect(x: 0, y: 0, width: Self.phoneSafeArea.leading * Self.scale, height: CGFloat(handoff.height))
        #expect(handoff.isFlat(Palette.paper, in: strip))
        try render(working.safeAreaPadding(Self.phoneSafeArea), as: "16-show-working-phone-safe-area")
    }

    // MARK: The mirrored display

    @Test func mirroredDisplay() throws {
        expectUntouchedCamera(try render(good, as: "10-rescue-good-1280x720", size: Self.mirrored), size: Self.mirrored)
        expectUntouchedCamera(try render(paused, as: "11-rescue-paused-1280x720", size: Self.mirrored),
                              size: Self.mirrored)
        try render(handoffFull, as: "12-handoff-1280x720", size: Self.mirrored)
        try render(working, as: "13-show-working-1280x720", size: Self.mirrored)
    }
}
