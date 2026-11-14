import simd

/// The torso and neck's shape, from the Blender patient's proportions, as a table the body surface reads.
enum TorsoProfile {
    /// Model space: x toward the head, y out of the chest, z across. Each row is x, half depth, half width.
    static let rows: [SIMD3<Float>] = [
        [-0.47, 0.070, 0.150],
        [-0.40, 0.085, 0.175],
        [-0.28, 0.080, 0.155],
        [-0.12, 0.088, 0.170],
        [0.04, 0.094, 0.185],
        [0.14, 0.085, 0.195],
        [0.20, 0.064, 0.120],
        [0.25, 0.045, 0.055],
        [0.34, 0.040, 0.046],
    ]

    /// The centre line, a little behind the measured front surface the fit puts at
    /// `PatientModelFit.bodyY`, so the shape sits round the body rather than floating over the chest.
    static let depth: Float = PatientModelFit.bodyY - 0.04

    /// Where the neck leaves the shoulders, for the piece that joins it to the head.
    static let neckBase = SIMD3<Float>(0.27, depth, 0)

    /// Half depth and half width at evenly spaced x from the first row to the last, smoothed.
    static let table: (x0: Float, x1: Float, a: [Float], b: [Float]) = {
        let curve = spline(rows, samples: 120).map(\.point)
        let x0 = rows[0].x, x1 = rows[rows.count - 1].x, count = 48
        var a: [Float] = [], b: [Float] = []
        var j = 0
        for i in 0..<count {
            let x = x0 + (x1 - x0) * Float(i) / Float(count - 1)
            while j < curve.count - 2, curve[j + 1].x < x { j += 1 }
            let p = curve[j], q = curve[j + 1]
            let f = q.x > p.x ? min(max((x - p.x) / (q.x - p.x), 0), 1) : 0
            a.append(p.y + (q.y - p.y) * f)
            b.append(p.z + (q.z - p.z) * f)
        }
        return (x0, x1, a, b)
    }()

    /// A Catmull-Rom curve through `points`, sampled evenly by segment, with its direction at each sample.
    static func spline(_ points: [SIMD3<Float>], samples: Int) -> [(point: SIMD3<Float>, tangent: SIMD3<Float>)] {
        guard points.count >= 2, samples >= 2 else { return [] }
        let p = [2 * points[0] - points[1]] + points + [2 * points[points.count - 1] - points[points.count - 2]]
        let segments = Float(points.count - 1)
        var result: [(SIMD3<Float>, SIMD3<Float>)] = []
        var lastTangent = simd_normalize(points[1] - points[0])
        for k in 0..<samples {
            let t = Float(k) / Float(samples - 1) * segments
            let i = min(Int(t), points.count - 2)
            let f = t - Float(i)
            let p0 = p[i], p1 = p[i + 1], p2 = p[i + 2], p3 = p[i + 3]
            // The curve's polynomial in f, term by term.
            let c1: SIMD3<Float> = p2 - p0
            let c2: SIMD3<Float> = 2 * p0 - 5 * p1 + 4 * p2 - p3
            let c3: SIMD3<Float> = 3 * p1 - p0 - 3 * p2 + p3
            let f2 = f * f, f3 = f2 * f
            let point: SIMD3<Float> = 0.5 * (2 * p1 + c1 * f + c2 * f2 + c3 * f3)
            let d: SIMD3<Float> = 0.5 * (c1 + 2 * f * c2 + 3 * f2 * c3)
            if simd_length(d) > 1e-5 { lastTangent = simd_normalize(d) }
            result.append((point, lastTangent))
        }
        return result
    }
}
