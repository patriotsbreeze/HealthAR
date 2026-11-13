import CoreGraphics
import Foundation
import ImageIO
import PlumbGeometry
import simd
import Testing
@testable import PlumbCapture

/// Scene snapshots built by hand from made-up frames.
struct SceneSnapshotTests {
    /// Bright in the top-left quarter of the picture and dark everywhere else.
    static let quartered = TestScene.image { u, v in u < 960 && v < 720 ? 240 : 20 }
    /// Each depth cell names itself: 1 + column + 1000 * row.
    static let numbered = TestScene.depthMap { column, row in Float(1 + column + 1000 * row) }

    func snapshot(depth: DepthMap = numbered, camera: FrameCamera = TestScene.level) throws -> SceneSnapshot {
        let copy = SnapshotCopy(image: Self.quartered, depth: depth, camera: camera, timestamp: 42)
        return try #require(SceneSnapshot(copy, minConfidence: CaptureConfig().probeMinConfidence))
    }

    /// The decoded JPEG and its mean brightness, 0...255.
    func decoded(_ data: Data?) throws -> (image: CGImage, brightness: Double) {
        let source = try #require(data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) })
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var total = 0
        for row in 0..<image.height {
            for column in 0..<image.width { total += Int(bytes[row * context.bytesPerRow + column]) }
        }
        return (image, Double(total) / Double(image.width * image.height))
    }

    // MARK: The picture

    @Test func keepsTheFramesPictureCameraAndTime() throws {
        let shot = try snapshot()
        #expect(shot.image.width == 1920 && shot.image.height == 1440)
        #expect(shot.imageSize == CGSize(width: 1920, height: 1440))
        #expect(shot.intrinsics == TestScene.intrinsics && shot.pose == TestScene.level.pose)
        #expect(shot.timestamp == 42)
    }

    @Test func theWholePictureIsShrunkToTheLongSide() throws {
        let whole = try decoded(snapshot().jpeg())
        #expect(whole.image.width == 1024 && whole.image.height == 768)
        // A quarter of the picture is bright (240) and the rest dark (20).
        #expect(abs(whole.brightness - (240 + 3 * 20) / 4) < 6)
    }

    @Test func aRegionIsCutOutThenShrunkKeepingItsShape() throws {
        // The middle half across, full height: 960 x 1440 pixels, 2:3.
        let middle = try decoded(snapshot().jpeg(region: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)))
        #expect(middle.image.height == 1024 && middle.image.width == 683)
        let small = try decoded(snapshot().jpeg(region: CGRect(x: 0.25, y: 0, width: 0.5, height: 1),
                                                maxLongSide: 300, quality: 0.3))
        #expect(small.image.height == 300 && small.image.width == 200)
    }

    @Test func regionsAreMeasuredFromTheTopLeft() throws {
        let shot = try snapshot()
        // Small enough to keep every pixel: never scaled up.
        let topLeft = try decoded(shot.jpeg(region: CGRect(x: 0, y: 0, width: 0.25, height: 0.25)))
        #expect(topLeft.image.width == 480 && topLeft.image.height == 360)
        #expect(topLeft.brightness > 225)
        let topRight = try decoded(shot.jpeg(region: CGRect(x: 0.75, y: 0, width: 0.25, height: 0.25)))
        #expect(topRight.brightness < 35)
        let bottomLeft = try decoded(shot.jpeg(region: CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25)))
        #expect(bottomLeft.brightness < 35)
    }

    @Test func aRegionIsTrimmedToThePicture() throws {
        let shot = try snapshot()
        let corner = try decoded(shot.jpeg(region: CGRect(x: 0.75, y: 0.75, width: 0.5, height: 0.5)))
        #expect(corner.image.width == 480 && corner.image.height == 360)
        #expect(shot.jpeg(region: CGRect(x: 1.2, y: 0, width: 0.5, height: 0.5)) == nil)
        #expect(shot.jpeg(region: CGRect(x: 0.5, y: 0.5, width: 0, height: 0.5)) == nil)
        #expect(shot.jpeg(maxLongSide: 0) == nil)
    }

    // MARK: Depth grids

    @Test func aGridReadsTheDepthCellUnderEachCellCentre() throws {
        // 75 pixels in 5 cells of 15 around (960, 720): centres 30 pixels either side, which at
        // 7.5 pixels a depth cell are every other cell from column 124 and row 92.
        let grid = try #require(snapshot().depthGrid(around: CGPoint(x: 0.5, y: 0.5), sidePx: 75, cells: 5))
        #expect(grid.width == 5 && grid.height == 5)
        #expect(grid.widthPx == 75 && grid.heightPx == 75 && grid.focalLengthPx == 1450)
        let columns = [124, 126, 128, 130, 132], rows = [92, 94, 96, 98, 100]
        #expect(grid.depthsM == rows.flatMap { row in columns.map { Double(1 + $0 + 1000 * row) } })
    }

    @Test func cellsOffThePictureHaveNoReading() throws {
        // At u = 19.2 the first cell's centre lies 10.8 pixels left of the picture.
        let shot = try snapshot()
        let grid = try #require(shot.depthGrid(around: CGPoint(x: 0.01, y: 0.5), sidePx: 75, cells: 5))
        for row in 0..<5 {
            let cells = grid.depthsM[(row * 5)..<(row * 5 + 5)]
            #expect(cells.first!.isNaN && cells.dropFirst().allSatisfy(\.isFinite))
        }
        // A grid with gaps still equals itself.
        #expect(shot.depthGrid(around: CGPoint(x: 0.01, y: 0.5), sidePx: 75, cells: 5) == grid)
        let corner = try #require(shot.depthGrid(around: CGPoint(x: 1, y: 1), sidePx: 40, cells: 2))
        #expect(corner.depthsM[0].isFinite && corner.depthsM[1...].allSatisfy(\.isNaN))
    }

    @Test func lowConfidenceCellsHaveNoReading() throws {
        // Low confidence left of column 128, medium from there: the default floor is medium.
        var levels: [UInt8] = []
        for _ in 0..<192 { for column in 0..<256 { levels.append(column < 128 ? 0 : 1) } }
        let depth = DepthMap(width: 256, height: 192, depthsM: Self.numbered.depthsM, confidence: levels)
        let grid = try #require(snapshot(depth: depth).depthGrid(around: CGPoint(x: 0.5, y: 0.5), sidePx: 75, cells: 5))
        for row in 0..<5 {
            let cells = Array(grid.depthsM[(row * 5)..<(row * 5 + 5)])
            #expect(cells[0].isNaN && cells[1].isNaN && cells[2...].allSatisfy(\.isFinite))
        }
    }

    @Test func aPointOffThePictureGivesNoGrid() throws {
        let shot = try snapshot()
        for point in [CGPoint(x: 1.01, y: 0.5), CGPoint(x: 0.5, y: -0.1), CGPoint(x: CGFloat.nan, y: 0.5)] {
            #expect(shot.depthGrid(around: point, sidePx: 75, cells: 5) == nil)
        }
        #expect(shot.depthGrid(around: CGPoint(x: 0.5, y: 0.5), sidePx: 0, cells: 5) == nil)
        #expect(shot.depthGrid(around: CGPoint(x: 0.5, y: 0.5), sidePx: 75, cells: 0) == nil)
    }

    // MARK: The world

    @Test func worldPointsProjectBackToTheirPixel() throws {
        let camera = FrameCamera(intrinsics: TestScene.intrinsics,
                                 pose: .aimed(from: SIMD3(0.4, 1.3, -0.2), tiltDownRadians: 0.5,
                                              rollRadians: 0.2, headingRadians: -0.7))
        let shot = try snapshot(camera: camera)
        #expect(shot.cameraPosition == SIMD3<Float>(0.4, 1.3, -0.2))
        for (point, depthM) in [(CGPoint(x: 0.3, y: 0.7), 0.6), (CGPoint(x: 0.9, y: 0.1), 1.8),
                                (CGPoint(x: 0.5, y: 0.5), 3.0)] {
            let world = shot.worldPoint(at: point, depthM: depthM)
            let seen = try #require(Projection.project(SIMD3<Double>(world), intrinsics: camera.intrinsics,
                                                       pose: camera.pose))
            // The world point is a Float: about a hundredth of a pixel is as close as it gets.
            #expect(abs(seen.u - Double(point.x) * 1920) < 0.01 && abs(seen.v - Double(point.y) * 1440) < 0.01)
            #expect(abs(seen.depthM - depthM) < 1e-5)
        }
    }
}
