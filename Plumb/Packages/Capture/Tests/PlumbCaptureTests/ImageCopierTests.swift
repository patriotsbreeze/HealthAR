import CoreVideo
import Foundation
import Testing
@testable import PlumbCapture

struct ImageCopierTests {
    private func planeBytes(_ buffer: CVPixelBuffer, _ plane: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        // Bi-planar 4:2:0: plane 0 is one byte a pixel, plane 1 two bytes per pair of pixels.
        let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
        return (0..<CVPixelBufferGetHeightOfPlane(buffer, plane)).flatMap { row in
            (0..<rowBytes).map { base[row * stride + $0] }
        }
    }

    @Test func copiesEveryPlaneIntoABufferOfItsOwn() throws {
        let source = TestScene.image(width: 30, height: 20) { u, v in UInt8((u * 7 + v * 13) % 256) }
        let copier = ImageCopier()
        let copy = try #require(copier.copy(source))
        #expect(copy !== source)
        #expect(CVPixelBufferGetWidth(copy) == 30 && CVPixelBufferGetHeight(copy) == 20)
        #expect(CVPixelBufferGetPixelFormatType(copy) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(planeBytes(copy, 0) == planeBytes(source, 0))
        #expect(planeBytes(copy, 1) == planeBytes(source, 1))
    }

    @Test func theCopyDoesNotFollowLaterChangesToTheSource() throws {
        let source = TestScene.image(width: 16, height: 8) { _, _ in 50 }
        let copy = try #require(ImageCopier().copy(source))
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(source, 0)!, 200, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * 8)
        CVPixelBufferUnlockBaseAddress(source, [])
        #expect(planeBytes(copy, 0).allSatisfy { $0 == 50 })
    }

    @Test func aNewSizeGetsANewPool() throws {
        let copier = ImageCopier()
        _ = try #require(copier.copy(TestScene.image(width: 16, height: 8) { _, _ in 1 }))
        let bigger = try #require(copier.copy(TestScene.image(width: 32, height: 24) { _, _ in 2 }))
        #expect(CVPixelBufferGetWidth(bigger) == 32 && planeBytes(bigger, 0).allSatisfy { $0 == 2 })
    }
}
