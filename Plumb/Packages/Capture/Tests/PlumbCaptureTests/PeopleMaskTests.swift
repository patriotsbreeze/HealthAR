import CoreGraphics
import Foundation
import Testing
@testable import PlumbCapture

/// The people mask's arithmetic on small made-up pictures.
struct PeopleMaskTests {
    /// A mask read one coverage value a pixel from rows of `#` (a person) and `.` (no one).
    func mask(_ rows: [String]) throws -> PeopleMask {
        let width = rows[0].count
        let coverage = rows.flatMap { $0.map { $0 == "#" ? UInt8(255) : 0 } }
        return try #require(PeopleMask(coverage: coverage, coverageWidth: width, coverageHeight: rows.count,
                                       threshold: 128, width: width, height: rows.count))
    }

    /// The mask drawn back as rows of `#` (hidden) and `.` (shown).
    func drawn(_ mask: PeopleMask) -> [String] {
        (0..<mask.height).map { row in
            String((0..<mask.width).map { mask.hidden[row * mask.width + $0] ? "#" : "." })
        }
    }

    // MARK: Reading coverage

    @Test func coverageAtOrAboveTheThresholdIsHidden() throws {
        let mask = try #require(PeopleMask(coverage: [0, 63, 64, 255], coverageWidth: 4, coverageHeight: 1,
                                           threshold: 64, width: 4, height: 1))
        #expect(mask.hidden == [false, false, true, true])
    }

    @Test func aCoarseGridIsStretchedOverThePicture() throws {
        // Seven pixel centres over three cells: cells 0, 0, 1, 1, 1, 2, 2.
        let row = try #require(PeopleMask(coverage: [255, 0, 255], coverageWidth: 3, coverageHeight: 1,
                                          threshold: 128, width: 7, height: 1))
        #expect(drawn(row) == ["##...##"])
        let quarters = try #require(PeopleMask(coverage: [255, 0, 0, 255], coverageWidth: 2, coverageHeight: 2,
                                               threshold: 128, width: 6, height: 4))
        #expect(drawn(quarters) == ["###...", "###...", "...###", "...###"])
    }

    @Test func aGridThatDoesNotFitGivesNoMask() {
        // Too few values for the grid, an empty grid, an empty picture.
        #expect(PeopleMask(coverage: [0, 0, 0], coverageWidth: 2, coverageHeight: 2, threshold: 1,
                           width: 4, height: 4) == nil)
        #expect(PeopleMask(coverage: [], coverageWidth: 0, coverageHeight: 0, threshold: 1,
                           width: 4, height: 4) == nil)
        #expect(PeopleMask(coverage: [0], coverageWidth: 1, coverageHeight: 1, threshold: 1,
                           width: 0, height: 4) == nil)
    }

    @Test func theHiddenFractionCountsPixels() throws {
        #expect(try mask(["##..", "...."]).hiddenFraction == 0.25)
        #expect(try mask(["....", "...."]).hiddenFraction == 0)
    }

    // MARK: Growing

    @Test func growingHidesASquareAroundEachPixel() throws {
        var grown = try mask([".......", ".......", ".......", "...#...", ".......", ".......", "......."])
        let before = grown
        grown.grow(by: 0)
        #expect(grown == before)
        grown.grow(by: 2)
        #expect(drawn(grown) == [".......", ".#####.", ".#####.", ".#####.", ".#####.", ".#####.", "......."])
    }

    @Test func growingStopsAtTheEdges() throws {
        var grown = try mask(["#.......", "........", "........", ".......#"])
        grown.grow(by: 1)
        #expect(drawn(grown) == ["##......", "##......", "......##", "......##"])
        grown.grow(by: Int.max)
        #expect(grown.hiddenFraction == 1)
    }

    @Test func growingNeverUncoversAPixel() throws {
        var grown = try mask(["#.#.#", ".#.#.", "#.#.#"])
        let before = grown.hidden
        grown.grow(by: 1)
        #expect(zip(before, grown.hidden).allSatisfy { !$0 || $1 })
        #expect(grown.hiddenFraction == 1)
    }

    // MARK: Boxes

    @Test func aBoxHidesItsWholePixelsOnThePicture() throws {
        var boxed = try mask(["......", "......", "......", "......"])
        // Rounded out to columns 1...3 and rows -1...1, of which rows 0 and 1 are on the picture.
        boxed.hide(CGRect(x: 1.5, y: -1, width: 2, height: 3))
        #expect(drawn(boxed) == [".###..", ".###..", "......", "......"])
        let before = boxed
        boxed.hide(CGRect(x: 10, y: 0, width: 3, height: 3))
        boxed.hide(CGRect(x: CGFloat.nan, y: 0, width: 3, height: 3))
        boxed.hide(.null)
        #expect(boxed == before)
    }

    @Test func faceBoxesGrowByTheirMargin() {
        let picture = CGSize(width: 1920, height: 1440)
        // 30% of 100 across and of 50 down on every side.
        #expect(PeopleMask.faceBox(CGRect(x: 200, y: 100, width: 100, height: 50), margin: 0.3, within: picture)
                == CGRect(x: 170, y: 85, width: 160, height: 80))
        // Rounded out to whole pixels, never in.
        #expect(PeopleMask.faceBox(CGRect(x: 10.2, y: 20.7, width: 30.1, height: 40.4), margin: 0, within: picture)
                == CGRect(x: 10, y: 20, width: 31, height: 42))
    }

    @Test func faceBoxesAreCutToThePicture() {
        let picture = CGSize(width: 1920, height: 1440)
        #expect(PeopleMask.faceBox(CGRect(x: -20, y: -10, width: 100, height: 100), margin: 0.3, within: picture)
                == CGRect(x: 0, y: 0, width: 110, height: 120))
        #expect(PeopleMask.faceBox(CGRect(x: 1850, y: 1400, width: 100, height: 100), margin: 0.3, within: picture)
                == CGRect(x: 1820, y: 1370, width: 100, height: 70))
        #expect(PeopleMask.faceBox(CGRect(x: 3000, y: 0, width: 50, height: 50), margin: 0.3, within: picture) == nil)
        #expect(PeopleMask.faceBox(CGRect(x: CGFloat.nan, y: 0, width: 50, height: 50), margin: 0.3,
                                   within: picture) == nil)
    }
}
