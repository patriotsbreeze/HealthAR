import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PlumbUI

/// "Check chest" on the rescue screen: offered in the rate's place before there is a rate, and never beside one.
@MainActor
@Suite struct CheckChestTests {
    typealias Palette = Theme.Palette
    let size = RenderTests.phone
    let scale = RenderTests.scale

    private func pixels(rate: Double?, offersCheck: Bool, savedAs name: String? = nil) throws -> Pixels {
        let model = rate == nil ? BarFieldModel() : Fixture.model(Fixture.bars(Fixture.corrected))
        let panel = Fixture.panel(startPrompt: rate == nil ? "Push hard and fast." : nil, model: model, rate: rate,
                                  elapsedSeconds: rate == nil ? 0 : 20, onCheckChest: offersCheck ? {} : nil)
        let renderer = ImageRenderer(content: Fixture.rescue(panel).frame(width: size.width, height: size.height))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        if let name {
            let url = RenderTests.folder.appendingPathComponent("\(name).png")
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return try #require(Pixels(image))
    }

    /// The left half of the rate row, where the rate stands once there is one, in pixels.
    private var rateSide: CGRect {
        let plan = ScreenPlan(size: size, panelReferenceWidth: Theme.metrics.panelWidth)
        let metrics = Theme.metrics
        let unit = plan.unit
        let rowBottom = size.height - (metrics.controlHeight + metrics.ruleWidth) * unit
        let inner = plan.panelWidth - 2 * metrics.panelPadding * unit
        let side = CGRect(x: plan.pictureSize.width + metrics.panelPadding * unit,
                          y: rowBottom - metrics.rateRowHeight * unit, width: inner / 2,
                          height: metrics.rateRowHeight * unit)
        return side.applying(CGAffineTransform(scaleX: scale, y: scale))
    }

    @Test func theCheckStandsWhereTheRateWillBe() throws {
        let offered = try pixels(rate: nil, offersCheck: true, savedAs: "20-rescue-start-check-chest")
        let plain = try pixels(rate: nil, offersCheck: false)
        #expect(plain.count(of: Palette.paper, in: rateSide) == 0)
        #expect(offered.count(of: Palette.paper, in: rateSide) > 100)
        // An ordinary control: no accent, and no green, which belongs to the AED alone.
        #expect(offered.count(of: Palette.accent, in: offered.bounds) == 0)
        #expect(offered.count(of: Palette.aed, in: rateSide) == 0)
    }

    /// The elapsed time and the caption beside it stay exactly where they were.
    @Test func nothingElseInTheRowMoves() throws {
        let offered = try pixels(rate: nil, offersCheck: true)
        let plain = try pixels(rate: nil, offersCheck: false)
        let farSide = rateSide.offsetBy(dx: rateSide.width, dy: 0)
        let quiet = Palette.quietOnGround
        #expect(offered.bounds(of: quiet, in: farSide) == plain.bounds(of: quiet, in: farSide))
        #expect(plain.bounds(of: quiet, in: farSide) != nil)
    }

    @Test func aRateAlwaysTakesThePlace() throws {
        let offered = try pixels(rate: 108, offersCheck: true)
        let plain = try pixels(rate: 108, offersCheck: false)
        #expect(offered.count(of: Palette.paper, in: rateSide, step: 1)
            == plain.count(of: Palette.paper, in: rateSide, step: 1))
        #expect(plain.count(of: Palette.paper, in: rateSide) > 100)
    }
}
