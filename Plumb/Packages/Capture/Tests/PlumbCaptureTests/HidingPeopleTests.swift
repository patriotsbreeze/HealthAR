import CoreGraphics
import Foundation
import Testing
@testable import PlumbCapture

/// Hiding people in scene snapshots, with Vision's findings made up by hand.
struct HidingPeopleTests {
    static let width = 240, height = 180
    /// Textured, so a changed pixel shows.
    static let picture = TestScene.image(width: width, height: height, luma: TestScene.stripes)

    func snapshot() throws -> SceneSnapshot {
        let copy = SnapshotCopy(image: Self.picture, depth: SceneSnapshotTests.numbered, camera: TestScene.level,
                                timestamp: 42)
        return try #require(SceneSnapshot(copy, minConfidence: CaptureConfig().probeMinConfidence))
    }

    /// What Vision would say of a picture with no one in it, on a mask half the picture's size.
    static let noOne = PeopleSighting(coverage: [UInt8](repeating: 0, count: 120 * 90), coverageWidth: 120,
                                      coverageHeight: 90, faces: [])

    /// The picture's red, green and blue values, three a pixel, row by row from the top-left, read
    /// straight from its bytes so nothing is redrawn on the way.
    func colours(_ image: CGImage) throws -> [UInt8] {
        #expect(image.bitsPerComponent == 8 && image.bitsPerPixel == 32)
        #expect(image.alphaInfo == .noneSkipLast || image.alphaInfo == .premultipliedLast)
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        var values: [UInt8] = []
        for row in 0..<image.height {
            for column in 0..<image.width {
                let pixel = row * image.bytesPerRow + column * 4
                values += [bytes[pixel], bytes[pixel + 1], bytes[pixel + 2]]
            }
        }
        return values
    }

    /// Checks that every pixel inside `filled` is the flat ground colour and every other pixel is
    /// exactly as it was.
    func expectFilled(_ hidden: SceneSnapshot, from original: SceneSnapshot, exactly filled: [CGRect]) throws {
        #expect(hidden.image.width == original.image.width && hidden.image.height == original.image.height)
        let before = try colours(original.image), after = try colours(hidden.image)
        var wrong = 0
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let index = (row * Self.width + column) * 3
                let inside = filled.contains { $0.contains(CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5)) }
                let wanted = inside ? [0x0B, 0x0D, 0x11] : Array(before[index..<(index + 3)])
                if Array(after[index..<(index + 3)]) != wanted { wrong += 1 }
            }
        }
        #expect(wrong == 0)
    }

    // MARK: What is filled

    @Test func aPictureWithNoOneInItComesBackUnchanged() async throws {
        let shot = try snapshot()
        #expect(shot.peopleHidden == nil)
        let hidden = try #require(await shot.hidingPeople { _ in Self.noOne })
        #expect(hidden.peopleHidden == PeopleHidden(filledFraction: 0, faceCount: 0))
        try expectFilled(hidden, from: shot, exactly: [])
        // Everything but the picture is kept.
        #expect(hidden.intrinsics == shot.intrinsics && hidden.pose == shot.pose && hidden.timestamp == 42)
        #expect(hidden.depthGrid(around: CGPoint(x: 0.5, y: 0.5), sidePx: 75, cells: 5)
                == shot.depthGrid(around: CGPoint(x: 0.5, y: 0.5), sidePx: 75, cells: 5))
        #expect(hidden.jpeg() != nil)
    }

    @Test func aPersonIsFilledFlatAndGrownBeyondTheMask() async throws {
        let shot = try snapshot()
        // Mask cells 30..<50 across and 20..<40 down, two pixels each: pixels 60..<100 and 40..<80.
        var coverage = [UInt8](repeating: 0, count: 120 * 90)
        for row in 20..<40 { for column in 30..<50 { coverage[row * 120 + column] = 200 } }
        let sighting = PeopleSighting(coverage: coverage, coverageWidth: 120, coverageHeight: 90, faces: [])
        let hidden = try #require(await shot.hidingPeople { _ in sighting })
        // Grown by four pixels and one two-pixel mask cell on every side.
        let filled = CGRect(x: 54, y: 34, width: 52, height: 52)
        try expectFilled(hidden, from: shot, exactly: [filled])
        #expect(hidden.peopleHidden == PeopleHidden(filledFraction: 52.0 * 52 / (240 * 180), faceCount: 0))
    }

    @Test func aFaceIsFilledEvenWhereTheMaskMissedIt() async throws {
        let shot = try snapshot()
        // The second face runs off the picture's bottom-right corner.
        let faces = [CGRect(x: 100, y: 50, width: 20, height: 30), CGRect(x: 230, y: 170, width: 20, height: 20)]
        let sighting = PeopleSighting(coverage: Self.noOne.coverage, coverageWidth: 120, coverageHeight: 90,
                                      faces: faces)
        let hidden = try #require(await shot.hidingPeople { _ in sighting })
        // Each grown by 30% of its size on every side, then cut to the picture.
        let filled = [CGRect(x: 94, y: 41, width: 32, height: 48), CGRect(x: 224, y: 164, width: 16, height: 16)]
        try expectFilled(hidden, from: shot, exactly: filled)
        #expect(hidden.peopleHidden == PeopleHidden(filledFraction: (32.0 * 48 + 16 * 16) / (240 * 180), faceCount: 2))
    }

    @Test func cutsOfTheHiddenPictureShowTheFillAndNothingElseChanges() async throws {
        let shot = try snapshot()
        // A mask as fine as the picture with everyone left of column 100: hidden up to column 105.
        var coverage = [UInt8](repeating: 0, count: 240 * 180)
        for row in 0..<180 { for column in 0..<100 { coverage[row * 240 + column] = 255 } }
        let sighting = PeopleSighting(coverage: coverage, coverageWidth: 240, coverageHeight: 180, faces: [])
        let hidden = try #require(await shot.hidingPeople { _ in sighting })
        let left = CGRect(x: 0, y: 0, width: 0.4, height: 1), right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let shown = try SceneSnapshotTests().decoded(hidden.jpeg(region: left))
        #expect(shown.image.width == 96 && shown.image.height == 180)
        // #0B0D11 is about 13 in grey; the stripes average far brighter.
        #expect(shown.brightness < 20)
        #expect(hidden.jpeg(region: right) == shot.jpeg(region: right))
    }

    // MARK: Failing closed

    @Test func whenVisionFindsNothingUsableNothingComesBack() async throws {
        let shot = try snapshot()
        #expect(await shot.hidingPeople { _ in nil } == nil)
        let short = PeopleSighting(coverage: [0, 0, 0], coverageWidth: 2, coverageHeight: 2, faces: [])
        #expect(await shot.hidingPeople { _ in short } == nil)
        let empty = PeopleSighting(coverage: [], coverageWidth: 0, coverageHeight: 0, faces: [])
        #expect(await shot.hidingPeople { _ in empty } == nil)
        let lostFace = PeopleSighting(coverage: Self.noOne.coverage, coverageWidth: 120, coverageHeight: 90,
                                      faces: [CGRect(x: CGFloat.nan, y: 10, width: 20, height: 20)])
        #expect(await shot.hidingPeople { _ in lostFace } == nil)
    }

    @Test func aStencilOrAnUnusualColourSpaceIsNotRead() throws {
        // A stencil has no colour of its own and would draw as all zeros, hiding no one.
        let ones = try #require(CGDataProvider(data: Data(repeating: 255, count: 16) as CFData))
        let stencil = try #require(CGImage(maskWidth: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 8,
                                           bytesPerRow: 4, provider: ones, decode: nil, shouldInterpolate: false))
        #expect(PeopleSighting.coverage(of: stencil) == nil)
        let cmyk = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceCMYK(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        #expect(PeopleSighting.coverage(of: try #require(cmyk.makeImage())) == nil)
    }

    @Test func aGreyMaskIsReadValueForValue() throws {
        // Whatever its row padding.
        let grey = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let bytes = try #require(grey.data).assumingMemoryBound(to: UInt8.self)
        for row in 0..<2 {
            for column in 0..<3 { bytes[row * grey.bytesPerRow + column] = UInt8(row * 100 + column * 10) }
        }
        let picture = try #require(grey.makeImage())
        #expect(PeopleSighting.coverage(of: picture) == [0, 10, 20, 100, 110, 120])
    }

    /// A 16 by 16 red, green and blue picture holding 0 to 255 in its three colours, with the unused
    /// byte where `alpha` and `order` put it set to `unused`.
    func ramp(alpha: CGImageAlphaInfo, order: CGImageByteOrderInfo = .orderDefault, unused: UInt8) throws -> CGImage {
        let side = 16
        let rgb = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: alpha.rawValue | order.rawValue))
        // In memory the unused byte comes last for skip-last in big-endian order, and first once that is reversed.
        let unusedAt = (alpha == .noneSkipLast) == (order != .order32Little) ? 3 : 0
        let bytes = try #require(rgb.data).assumingMemoryBound(to: UInt8.self)
        for row in 0..<side {
            for column in 0..<side {
                let pixel = bytes + row * rgb.bytesPerRow + column * 4
                for index in 0..<4 { pixel[index] = index == unusedAt ? unused : UInt8(row * side + column) }
            }
        }
        return try #require(rgb.makeImage())
    }

    /// Vision's person mask arrives as a red, green and blue picture with the three equal, the way its
    /// `cgImage` makes it: 8 bits each and 32 a pixel. Every value from 0 to 255 comes back as it was,
    /// so the threshold means what it says, wherever the unused byte sits and whatever it holds. Drawn
    /// rather than read, a picture whose unused first byte is 0 would come out blank and hide no one.
    @Test(arguments: [CGImageAlphaInfo.noneSkipLast, .noneSkipFirst], [UInt8(0), 255])
    func aMaskInRedGreenBlueIsReadValueForValue(alpha: CGImageAlphaInfo, unused: UInt8) throws {
        let everyValue = (0...255).map { UInt8($0) }
        let mask = try ramp(alpha: alpha, unused: unused)
        #expect(mask.colorSpace?.model == .rgb && mask.bitsPerPixel == 32)
        #expect(PeopleSighting.coverage(of: mask) == everyValue)
        #expect(PeopleSighting.coverage(of: try ramp(alpha: alpha, order: .order32Little, unused: unused)) == everyValue)
    }

    /// Transparency could have scaled the colours down, so a picture with it is not read at all.
    @Test func aMaskWithTransparencyIsNotRead() throws {
        for alpha in [CGImageAlphaInfo.premultipliedLast, .premultipliedFirst] {
            let rgb = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue))
            #expect(PeopleSighting.coverage(of: try #require(rgb.makeImage())) == nil)
        }
    }

    /// Were the three ever not equal, each pixel reads as the largest, the one that hides more.
    @Test func aTintedMaskReadsAsItsLargestValue() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let rgb = try #require(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = try #require(rgb.data).assumingMemoryBound(to: UInt8.self)
        let pixels: [[UInt8]] = [[200, 10, 10], [10, 90, 10], [0, 0, 40]]
        for (column, pixel) in pixels.enumerated() {
            for channel in 0..<3 { bytes[column * 4 + channel] = pixel[channel] }
        }
        #expect(PeopleSighting.coverage(of: try #require(rgb.makeImage())) == [200, 90, 40])
    }

    #if targetEnvironment(simulator)
    /// The simulator cannot run Vision's person segmentation or face detection, so the real path
    /// must give nothing rather than the picture as it was.
    @Test func whereVisionCannotRunNothingComesBack() async throws {
        #expect(try await snapshot().hidingPeople() == nil)
    }
    #else
    /// Where Vision runs, its own person mask is read: a camera-sized picture gives a sighting with
    /// one coverage value for every mask pixel, so "Find AED" has something it may send.
    @Test func visionsOwnMaskIsRead() async throws {
        let width = 1920, height = 1440
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.45, green: 0.5, blue: 0.55, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 600, y: 400, width: 500, height: 700))
        let picture = try #require(context.makeImage())
        let sighting = try #require(await PeopleSighting.look(at: picture))
        #expect(sighting.coverageWidth > 0 && sighting.coverageHeight > 0)
        #expect(sighting.coverage.count == sighting.coverageWidth * sighting.coverageHeight)
    }
    #endif
}
