import CoreVideo
import Foundation
import PlumbGeometry
import Testing
@testable import PlumbCapture

struct LumaSamplerTests {
    /// Runs `body` on a plane of `width` columns whose rows are `bytesPerRow` apart; padding reads 255.
    private func withPlane<R>(_ rows: [[UInt8]], bytesPerRow: Int, _ body: (PlaneView) -> R) -> R {
        var bytes = [UInt8](repeating: 255, count: bytesPerRow * rows.count)
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() { bytes[row * bytesPerRow + column] = value }
        }
        return bytes.withUnsafeBytes {
            body(PlaneView(base: $0.baseAddress!, width: rows[0].count, height: rows.count, bytesPerRow: bytesPerRow))
        }
    }

    @Test func wholeNumbersReadPixelCentres() {
        withPlane([[10, 20], [30, 40]], bytesPerRow: 2) { plane in
            #expect(LumaSampler.brightness(of: plane, u: 0, v: 0) == 10)
            #expect(LumaSampler.brightness(of: plane, u: 1, v: 0) == 20)
            #expect(LumaSampler.brightness(of: plane, u: 0, v: 1) == 30)
            #expect(LumaSampler.brightness(of: plane, u: 1, v: 1) == 40)
        }
    }

    @Test func blendsBetweenNeighbours() {
        withPlane([[0, 100], [200, 255]], bytesPerRow: 2) { plane in
            // (0 + 100) / 2 above, (200 + 255) / 2 below, then halfway between: 138.75.
            #expect(LumaSampler.brightness(of: plane, u: 0.5, v: 0.5) == 139)
            #expect(LumaSampler.brightness(of: plane, u: 0.25, v: 0) == 25)
        }
    }

    @Test func steppingRowsUsesTheStrideNotTheWidth() {
        // Rows of 3 samples padded to 8 bytes; reading row 1 by width would land in row 0's padding.
        withPlane([[1, 2, 3], [4, 5, 6], [7, 8, 9]], bytesPerRow: 8) { plane in
            #expect(LumaSampler.brightness(of: plane, u: 0, v: 1) == 4)
            #expect(LumaSampler.brightness(of: plane, u: 2, v: 2) == 9)
        }
    }

    @Test func beyondTheEdgeReadsTheEdgeNeverThePadding() {
        withPlane([[1, 2, 3], [4, 5, 6]], bytesPerRow: 8) { plane in
            #expect(LumaSampler.brightness(of: plane, u: 50, v: 0) == 3)
            #expect(LumaSampler.brightness(of: plane, u: 2.5, v: 1) == 6)
            #expect(LumaSampler.brightness(of: plane, u: -4, v: 9) == 4)
            #expect(LumaSampler.brightness(of: plane, u: .nan, v: 0) == 0)
        }
    }

    @Test func samplesAGridFromTheLumaPlaneOfARealBuffer() throws {
        // Brightness grows down the image: v * 2.
        let image = TestScene.image(width: 64, height: 48) { _, v in UInt8(v * 2) }
        // Upright camera: world-up points up the image. Rows 3 pixels apart around v = 24.
        let grid = LumaGrid(centreU: 32, centreV: 24, upDirection: SIMD2(0, -1), columns: 4, rows: 6,
                            pitchPx: 3, columnPitchPx: 2)
        let patch = try #require(LumaSampler.sample(grid, from: image))
        #expect(patch.width == 4 && patch.height == 6 && patch.pitchPx == 3)
        // Row 0 is highest in the world, so highest in the image: v = 24 - 2.5 * 3 = 16.5.
        #expect(Array(patch.pixels[0..<4]) == [33, 33, 33, 33])
        #expect(Array(patch.pixels[20..<24]) == [63, 63, 63, 63])
    }

    @Test func refusesAnImageThatIsNotYCbCr() throws {
        let depth = try PaddedBuffer(width: 4, height: 4, bytesPerRow: 16, format: kCVPixelFormatType_DepthFloat32,
                                     fill: Float(0)) { _, _ in Float(1) }
        let grid = LumaGrid(centreU: 2, centreV: 2, upDirection: SIMD2(0, -1), columns: 2, rows: 2,
                            pitchPx: 1, columnPitchPx: 1)
        #expect(LumaSampler.sample(grid, from: depth.buffer) == nil)
    }
}
