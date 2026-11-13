import CoreVideo
import Foundation
import Testing
@testable import PlumbCapture

struct DepthMapTests {
    /// 4 x 3 cells holding 1...12, confidence 0, 1, 2 repeating.
    let small = DepthMap(width: 4, height: 3, depthsM: (1...12).map(Float.init),
                         confidence: (0..<12).map { UInt8($0 % 3) })

    @Test func cutInsideCopiesRowByRow() {
        let patch = small.cut(CellWindow(column: 1, row: 1, columns: 2, rows: 2))
        #expect(patch.width == 2 && patch.height == 2)
        #expect(patch.depthsM == [6, 7, 10, 11])
        #expect(patch.confidence == [2, 0, 0, 1])
    }

    @Test func cutPastTheEdgeKeepsItsSizeAndMarksNoReading() {
        let patch = small.cut(CellWindow(column: -1, row: 2, columns: 3, rows: 2))
        #expect(patch.width == 3 && patch.height == 2)
        #expect(patch.depthsM[0].isNaN)
        #expect(Array(patch.depthsM[1...2]) == [9, 10])
        #expect(patch.depthsM[3...].allSatisfy { $0.isNaN })
        #expect(patch.confidence == [0, 2, 0, 0, 0, 0])
    }

    @Test func cutWhollyOffTheMapIsAllNoReading() {
        let patch = small.cut(CellWindow(column: 10, row: -5, columns: 2, rows: 2))
        #expect(patch.depthsM.count == 4 && patch.depthsM.allSatisfy { $0.isNaN })
        #expect(patch.nearestSurface() == nil)
    }

    @Test func cutWithoutConfidenceLeavesItEmpty() {
        let bare = DepthMap(width: 2, height: 2, depthsM: [1, 2, 3, 4])
        let patch = bare.cut(CellWindow(column: 0, row: 0, columns: 2, rows: 2))
        #expect(patch.confidence.isEmpty)
        #expect(patch.depthsM == [1, 2, 3, 4])
    }

    @Test func confidenceOfTheWrongLengthIsDropped() {
        #expect(DepthMap(width: 2, height: 1, depthsM: [1, 2], confidence: [2]).confidence.isEmpty)
    }

    @Test func medianSkipsUnsureAndMissingCells() {
        let map = DepthMap(width: 3, height: 2, depthsM: [1.0, .nan, 0, 2.0, 3.0, 9.0],
                           confidence: [2, 2, 2, 1, 2, 0])
        let all = CellWindow(column: 0, row: 0, columns: 3, rows: 2)
        // Usable at medium or better: 1, 2, 3. NaN, zero and the low-confidence 9 are left out.
        #expect(map.medianDepth(in: all, minConfidence: 1) == 2.0)
        // At high only: 1 and 3.
        #expect(map.medianDepth(in: all, minConfidence: 2) == 2.0)
        #expect(map.medianDepth(in: CellWindow(column: 1, row: 0, columns: 2, rows: 1), minConfidence: 1) == nil)
    }

    @Test func copiesFromAPixelBufferUsingItsOwnRowStride() throws {
        // 5 floats a row (20 bytes) padded to 32: the padding holds junk that must not leak in.
        let depth = try PaddedBuffer(width: 5, height: 3, bytesPerRow: 32, format: kCVPixelFormatType_DepthFloat32,
                                     fill: Float(-99)) { column, row in Float(row * 10 + column) }
        let confidence = try PaddedBuffer(width: 5, height: 3, bytesPerRow: 8, format: kCVPixelFormatType_OneComponent8,
                                          fill: UInt8(7)) { column, row in UInt8((row + column) % 3) }
        let map = try #require(DepthMap(depth: depth.buffer, confidence: confidence.buffer))
        #expect(map.width == 5 && map.height == 3)
        #expect(map.depthsM == [0, 1, 2, 3, 4, 10, 11, 12, 13, 14, 20, 21, 22, 23, 24])
        #expect(map.confidence == [0, 1, 2, 0, 1, 1, 2, 0, 1, 2, 2, 0, 1, 2, 0])
    }

    @Test func refusesABufferThatIsNotFloatDepth() throws {
        let wrong = try PaddedBuffer(width: 4, height: 2, bytesPerRow: 4, format: kCVPixelFormatType_OneComponent8,
                                     fill: UInt8(0)) { _, _ in UInt8(1) }
        #expect(DepthMap(depth: wrong.buffer, confidence: nil) == nil)
    }

    @Test func dropsAConfidenceMapOfAnotherSize() throws {
        let depth = try PaddedBuffer(width: 4, height: 2, bytesPerRow: 16, format: kCVPixelFormatType_DepthFloat32,
                                     fill: Float(0)) { _, _ in Float(1) }
        let confidence = try PaddedBuffer(width: 2, height: 2, bytesPerRow: 2, format: kCVPixelFormatType_OneComponent8,
                                          fill: UInt8(0)) { _, _ in UInt8(2) }
        let map = try #require(DepthMap(depth: depth.buffer, confidence: confidence.buffer))
        #expect(map.confidence.isEmpty)
    }
}

/// A pixel buffer over memory this test owns, with a row stride of its choosing.
final class PaddedBuffer {
    let buffer: CVPixelBuffer
    private let memory: UnsafeMutableRawPointer

    init<Sample>(width: Int, height: Int, bytesPerRow: Int, format: OSType, fill: Sample,
                 _ value: (Int, Int) -> Sample) throws {
        memory = .allocate(byteCount: bytesPerRow * height, alignment: 16)
        let stride = MemoryLayout<Sample>.stride
        for offset in Swift.stride(from: 0, to: bytesPerRow * height - stride + 1, by: stride) {
            memory.storeBytes(of: fill, toByteOffset: offset, as: Sample.self)
        }
        for row in 0..<height {
            for column in 0..<width {
                memory.storeBytes(of: value(column, row), toByteOffset: row * bytesPerRow + column * stride, as: Sample.self)
            }
        }
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil, width, height, format, memory, bytesPerRow, nil, nil, nil, &made)
        buffer = try #require(status == kCVReturnSuccess ? made : nil)
    }

    deinit {
        memory.deallocate()
    }
}
