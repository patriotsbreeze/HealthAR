import CoreGraphics
import Foundation
import ImageIO
import PlumbContracts
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PlumbUI

/// The record control on the show-working screen: there only when the app can record, saying what a
/// press will do, and leaving everything above the footer where it was.
@MainActor
@Suite struct RecordControlTests {
    /// The scoreboard the app shows with the live camera, the only feed that can record. The control
    /// leaves each score about 75 points on the phone: enough for these, not for long captions.
    private let liveScores = [WorkingScore(value: "37", caption: "pushes counted"),
                              WorkingScore(value: "92%", caption: "depth trusted"),
                              WorkingScore(value: "Live", caption: "source")]

    private func screen(isRecording: Bool = false,
                        onRecordChanged: ((Bool) -> Void)? = nil) -> WorkingScreen<Color> {
        WorkingScreen(timeline: WorkingFixture.timeline, scores: liveScores,
                      failsWhen: WorkingFixture.failsWhen, selected: .decision(WorkingFixture.firstCueID),
                      onBack: {}, isRecording: isRecording, onRecordChanged: onRecordChanged) { Fixture.picture }
    }

    @Test func withoutACallbackThereIsNoRecordControl() {
        #expect(screen().recordControl == nil)
        #expect(screen(isRecording: true).recordControl == nil)
    }

    @Test func theControlSaysWhatAPressWillDo() throws {
        let idle = try #require(screen(onRecordChanged: { _ in }).recordControl)
        let recording = try #require(screen(isRecording: true, onRecordChanged: { _ in }).recordControl)
        #expect(RecordControl.title(isRecording: idle.isRecording) == "Record measurements")
        #expect(RecordControl.title(isRecording: recording.isRecording) == "Stop recording")
    }

    @Test func aPressAsksForTheOtherState() throws {
        var asked: [Bool] = []
        try #require(screen(onRecordChanged: { asked.append($0) }).recordControl).press()
        try #require(screen(isRecording: true, onRecordChanged: { asked.append($0) }).recordControl).press()
        #expect(asked == [true, false])
    }

    // MARK: Pictures

    private func image(of view: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = RenderTests.scale
        return try #require(renderer.cgImage)
    }

    /// Saves a picture next to the other screens' for a person to look at.
    private func save(_ image: CGImage, as name: String) throws {
        try FileManager.default.createDirectory(at: RenderTests.folder, withIntermediateDirectories: true)
        let url = RenderTests.folder.appendingPathComponent("\(name).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The sRGB bytes of every row, cut off `width` points from the left, to compare two pictures by.
    private func columns(of image: CGImage, leftOf width: CGFloat) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &buffer, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rowBytes = image.width * 4
        let kept = min(rowBytes, Int(width * RenderTests.scale) * 4)
        return (0..<image.height).flatMap { row in buffer[(row * rowBytes)..<(row * rowBytes + kept)] }
    }

    /// The control sits in the footer beside "Back", on the phone inside its own margins and on the
    /// mirrored display. It never touches the depth picture or the list under it, and the way back
    /// stays on screen. The rows above may give a caption's line to the footer, as they always do.
    @Test func theControlSitsInTheFooterBesideTheWayBack() throws {
        let cases: [(size: CGSize, insets: EdgeInsets, name: String)] = [
            (RenderTests.phone, RenderTests.phoneSafeArea, "18-show-working-recording-phone-safe-area"),
            (RenderTests.mirrored, EdgeInsets(), "19-show-working-record-1280x720"),
        ]
        for (index, item) in cases.enumerated() {
            let plain = try image(of: screen().safeAreaPadding(item.insets), size: item.size)
            let withControl = try image(of: screen(isRecording: index == 0, onRecordChanged: { _ in })
                .safeAreaPadding(item.insets), size: item.size)
            try save(withControl, as: item.name)
            let picture = ScreenPlan(size: item.size, panelReferenceWidth: Theme.metrics.workingPanelWidth).pictureSize
            #expect(try columns(of: plain, leftOf: picture.width) == columns(of: withControl, leftOf: picture.width))
            #expect(try columns(of: plain, leftOf: item.size.width) != columns(of: withControl, leftOf: item.size.width))
            // "Back" still ends at the right margin, in the bottom quarter.
            let scale = RenderTests.scale
            let corner = CGRect(x: (item.size.width - item.insets.trailing - 80) * scale,
                                y: item.size.height * 0.75 * scale, width: 80 * scale,
                                height: item.size.height * 0.25 * scale)
            #expect(try #require(Pixels(withControl)).count(of: Theme.Palette.paper, in: corner) > 20)
        }
    }

    /// Recording, the words are set in the mark colour so they are not forgotten; idle, in the quiet one.
    @Test func recordingIsMarkedAndIdleIsQuiet() throws {
        let size = RenderTests.phone
        let band = CGRect(x: 0, y: size.height * 0.75 * RenderTests.scale,
                          width: size.width * RenderTests.scale, height: size.height * 0.25 * RenderTests.scale)
        let idle = try #require(Pixels(try image(of: screen(onRecordChanged: { _ in }), size: size)))
        let recording = try #require(Pixels(try image(of: screen(isRecording: true, onRecordChanged: { _ in }),
                                                      size: size)))
        #expect(recording.count(of: Theme.Palette.paper, in: band) > idle.count(of: Theme.Palette.paper, in: band))
        #expect(recording.count(of: Theme.Palette.accent, in: band) == 0)
        #expect(idle.count(of: Theme.Palette.accent, in: band) == 0)
    }
}
