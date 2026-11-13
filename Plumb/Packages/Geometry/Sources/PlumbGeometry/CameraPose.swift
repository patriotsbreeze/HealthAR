import Foundation
import simd

/// Where the camera is and which way it faces, as a rigid camera-to-world transform.
///
/// Camera space follows ARKit: +x right, +y up, and the lens looks along -z.
/// World space is gravity aligned: +y is up.
public struct CameraPose: Sendable, Equatable {
    /// The 4x4 camera-to-world matrix as 16 values, column after column.
    public var columns: [Float]

    /// Wraps 16 column-major values. Any other count is a programming error.
    public init(columns: [Float]) {
        precondition(columns.count == 16, "A camera pose is 16 values, column-major")
        self.columns = columns
    }

    /// Copies a camera transform such as ARKit's `ARCamera.transform`.
    public init(_ matrix: simd_float4x4) {
        let c = matrix.columns
        self.init(columns: [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] })
    }

    /// The pose as a matrix that maps camera points to world points.
    public var matrix: simd_float4x4 {
        simd_float4x4(column(0), column(1), column(2), column(3))
    }

    /// The camera's position in the world, in metres.
    public var position: SIMD3<Double> {
        SIMD3(Double(columns[12]), Double(columns[13]), Double(columns[14]))
    }

    /// The camera's own axes written in world space (the rotation part of the pose).
    /// Doubles, because millimetres at a metre leave little room in a Float.
    var rotation: simd_double3x3 {
        simd_double3x3(axis(0), axis(1), axis(2))
    }

    private func column(_ index: Int) -> SIMD4<Float> {
        let start = index * 4
        return SIMD4(columns[start], columns[start + 1], columns[start + 2], columns[start + 3])
    }

    private func axis(_ index: Int) -> SIMD3<Double> {
        let start = index * 4
        return SIMD3(Double(columns[start]), Double(columns[start + 1]), Double(columns[start + 2]))
    }
}

// MARK: - Building poses

extension CameraPose {
    /// A camera at `position` whose lens points along `direction`, turned about that line so its
    /// top faces `up` as nearly as it can. `direction` need not be unit length.
    public static func looking(from position: SIMD3<Double>, along direction: SIMD3<Double>,
                               up: SIMD3<Double> = SIMD3(0, 1, 0)) -> CameraPose {
        let forward = simd_normalize(direction)
        // A hint along the lens axis says nothing about which way is up, so fall back to another axis.
        let hints = [up, SIMD3(0, 0, -1), SIMD3(1, 0, 0)]
        let side = hints.lazy.map { simd_cross(forward, $0) }.first { simd_length($0) > 1e-9 } ?? SIMD3(1, 0, 0)
        let right = simd_normalize(side)
        let top = simd_cross(right, forward)
        let back = -forward
        return CameraPose(columns: [
            Float(right.x), Float(right.y), Float(right.z), 0,
            Float(top.x), Float(top.y), Float(top.z), 0,
            Float(back.x), Float(back.y), Float(back.z), 0,
            Float(position.x), Float(position.y), Float(position.z), 1,
        ])
    }

    /// A camera at `position` described the way a propped phone is: tilted down from level, rolled
    /// about its lens axis (positive is clockwise seen from behind the camera), and turned about
    /// the vertical (positive is to the left). All zero looks level along world -z.
    public static func aimed(from position: SIMD3<Double>, tiltDownRadians: Double,
                             rollRadians: Double = 0, headingRadians: Double = 0) -> CameraPose {
        let forward = SIMD3(-sin(headingRadians) * cos(tiltDownRadians),
                            -sin(tiltDownRadians),
                            -cos(headingRadians) * cos(tiltDownRadians))
        // Start from the unrolled camera so the roll is measured from "top of the camera is up".
        let unrolledTop = looking(from: position, along: forward).rotation.columns.1
        let rolledTop = unrolledTop * cos(rollRadians) + simd_cross(forward, unrolledTop) * sin(rollRadians)
        return looking(from: position, along: forward, up: rolledTop)
    }
}

// MARK: - Codable

extension CameraPose: Codable {
    /// Reads a pose stored as a bare list of 16 numbers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Float].self)
        guard values.count == 16 else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A camera pose needs 16 values, found \(values.count)")
        }
        columns = values
    }

    /// Stores the pose as a bare list of 16 numbers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(columns)
    }
}
