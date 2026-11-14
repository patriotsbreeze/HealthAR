import simd

/// One soft piece of the tracked body. `BodySurface` blends every piece into a single skin, so a
/// limb flows into the torso instead of poking into it.
enum BodyPiece: Sendable, Equatable {
    /// A limb segment or the neck: rounded at both ends, `r1` thick at `from` and `r2` at `to`.
    case cone(from: SIMD3<Float>, to: SIMD3<Float>, r1: Float, r2: Float)
    /// The head: `radii` along the three columns of `axes`.
    case ellipsoid(center: SIMD3<Float>, axes: simd_float3x3, radii: SIMD3<Float>)
    case torso(TorsoLoft)
}

/// The torso in world metres: elliptical sections along `headward`, from `x0` to `x1`.
struct TorsoLoft: Sendable, Equatable {
    var origin: SIMD3<Float>
    var headward: SIMD3<Float>
    var normal: SIMD3<Float>
    var across: SIMD3<Float>
    /// Where the section centres sit along `normal`.
    var y0: Float
    var x0: Float
    var x1: Float
    /// Half depth along `normal` and half width along `across`, at evenly spaced x.
    var a: [Float]
    var b: [Float]

    /// The Blender patient's torso placed by a fitted model-to-world transform, stretched as it is.
    init(model: simd_float4x4) {
        let sx = simd_length(model.columns.0.xyz), sy = simd_length(model.columns.1.xyz), sz = simd_length(model.columns.2.xyz)
        let table = TorsoProfile.table
        origin = model.columns.3.xyz
        headward = model.columns.0.xyz / max(sx, 1e-6)
        normal = model.columns.1.xyz / max(sy, 1e-6)
        across = model.columns.2.xyz / max(sz, 1e-6)
        y0 = TorsoProfile.depth * sy
        x0 = table.x0 * sx
        x1 = table.x1 * sx
        a = table.a.map { $0 * sy }
        b = table.b.map { $0 * sz }
    }
}

/// A triangle mesh, wound to face out, with smooth normals.
struct BodyMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var lower = SIMD3<Float>(repeating: 0)
    var upper = SIMD3<Float>(repeating: 0)
}

/// Turns the pieces into one closed skin: each piece is a distance field, they are joined with a
/// smooth minimum so joints round over, and the surface is read off a grid with surface nets.
enum BodySurface {
    /// How far apart two pieces still melt together. Larger rounds the joins more.
    static let blend: Float = 0.045
    /// Finest and coarsest grid spacing in metres. The skin starts fine and coarsens when a build runs
    /// slow, as on a hot phone, and also on its own if the body would need too many samples.
    static let cell: Float = 0.016
    static let coarsestCell: Float = 0.032
    static let maxSamples = 260_000
    private static let outside: Float = 1

    @_optimize(speed)
    static func mesh(_ pieces: [BodyPiece], cell: Float = cell) -> BodyMesh {
        let boxes = pieces.map { box($0, pad: blend + 2 * cell) }
        guard var lo = boxes.first?.0, var hi = boxes.first?.1 else { return BodyMesh() }
        for (l, u) in boxes { lo = simd_min(lo, l); hi = simd_max(hi, u) }
        var h = cell
        var dims = SIMD3<Int>(1, 1, 1)
        while true {
            let extent = (hi - lo) / h
            dims = SIMD3(Int(extent.x.rounded(.up)) + 1, Int(extent.y.rounded(.up)) + 1, Int(extent.z.rounded(.up)) + 1)
            if dims.x * dims.y * dims.z <= maxSamples { break }
            h *= 1.15
        }
        let nx = dims.x, ny = dims.y, nz = dims.z
        var grid = [Float](repeating: outside, count: nx * ny * nz)

        // Each piece writes only the samples inside its own padded box.
        for (piece, (l, u)) in zip(pieces, boxes) {
            let i0 = max(Int(((l.x - lo.x) / h).rounded(.down)), 0), i1 = min(Int(((u.x - lo.x) / h).rounded(.up)), nx - 1)
            let j0 = max(Int(((l.y - lo.y) / h).rounded(.down)), 0), j1 = min(Int(((u.y - lo.y) / h).rounded(.up)), ny - 1)
            let k0 = max(Int(((l.z - lo.z) / h).rounded(.down)), 0), k1 = min(Int(((u.z - lo.z) / h).rounded(.up)), nz - 1)
            guard i0 <= i1, j0 <= j1, k0 <= k1 else { continue }
            for k in k0...k1 {
                for j in j0...j1 {
                    let row = (k * ny + j) * nx
                    for i in i0...i1 {
                        let p = lo + SIMD3(Float(i), Float(j), Float(k)) * h
                        grid[row + i] = smoothMin(grid[row + i], distance(piece, p), blend)
                    }
                }
            }
        }
        return surfaceNets(grid, nx: nx, ny: ny, nz: nz, origin: lo, h: h)
    }

    // MARK: - Distances

    static func smoothMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let t = max(k - abs(a - b), 0) / k
        return min(a, b) - t * t * k * 0.25
    }

    @_optimize(speed)
    static func distance(_ piece: BodyPiece, _ p: SIMD3<Float>) -> Float {
        switch piece {
        case let .cone(a, b, r1, r2): roundCone(p, a, b, r1, r2)
        case let .ellipsoid(c, axes, r): ellipsoid(axes.transpose * (p - c), r)
        case let .torso(loft): torso(loft, p)
        }
    }

    /// Exact distance to a cone with spherical ends (after Inigo Quilez).
    static func roundCone(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r1: Float, _ r2: Float) -> Float {
        let ba = b - a
        let l2 = simd_dot(ba, ba)
        let rr = r1 - r2
        let a2 = l2 - rr * rr
        // One end swallows the other: the bigger sphere alone.
        guard l2 > 1e-8, a2 > 1e-8 else { return min(simd_length(p - a) - r1, simd_length(p - b) - r2) }
        let il2 = 1 / l2
        let pa = p - a
        let y = simd_dot(pa, ba), z = y - l2
        let xv = pa * l2 - ba * y
        let x2 = simd_dot(xv, xv)
        let y2 = y * y * l2, z2 = z * z * l2
        let k = (rr < 0 ? -1 : 1) * rr * rr * x2
        if (z < 0 ? -1 : 1) * a2 * z2 > k { return (x2 + z2).squareRoot() * il2 - r2 }
        if (y < 0 ? -1 : 1) * a2 * y2 < k { return (x2 + y2).squareRoot() * il2 - r1 }
        return ((x2 * a2 * il2).squareRoot() + y * rr) * il2 - r1
    }

    /// Close to the distance near the surface, which is all the mesh needs.
    static func ellipsoid(_ q: SIMD3<Float>, _ r: SIMD3<Float>) -> Float {
        let k0 = simd_length(q / r), k1 = simd_length(q / (r * r))
        guard k1 > 1e-8 else { return -r.min() }
        return k0 * (k0 - 1) / k1
    }

    static func torso(_ t: TorsoLoft, _ p: SIMD3<Float>) -> Float {
        let q = p - t.origin
        let x = simd_dot(q, t.headward), y = simd_dot(q, t.normal) - t.y0, z = simd_dot(q, t.across)
        let count = t.a.count
        let s = (min(max(x, t.x0), t.x1) - t.x0) / max(t.x1 - t.x0, 1e-6) * Float(count - 1)
        let i = min(Int(s), count - 2), f = s - Float(i)
        let a = t.a[i] + (t.a[i + 1] - t.a[i]) * f, b = t.b[i] + (t.b[i + 1] - t.b[i]) * f
        let k0 = ((y / a) * (y / a) + (z / b) * (z / b)).squareRoot()
        let k1 = ((y / (a * a)) * (y / (a * a)) + (z / (b * b)) * (z / (b * b))).squareRoot()
        let radial = k1 > 1e-8 ? k0 * (k0 - 1) / k1 : -min(a, b)
        let past = max(t.x0 - x, x - t.x1)
        return past > 0 ? (max(radial, 0) * max(radial, 0) + past * past).squareRoot() : max(radial, past)
    }

    /// World bounds of a piece, grown by `pad`.
    static func box(_ piece: BodyPiece, pad: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        switch piece {
        case let .cone(a, b, r1, r2):
            return (simd_min(a - r1, b - r2) - pad, simd_max(a + r1, b + r2) + pad)
        case let .ellipsoid(c, _, r):
            return (c - r.max() - pad, c + r.max() + pad)
        case let .torso(t):
            let depth = (t.a.max() ?? 0), width = (t.b.max() ?? 0)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for x in [t.x0, t.x1] {
                for y in [t.y0 - depth, t.y0 + depth] {
                    for z in [-width, width] {
                        let p = t.origin + t.headward * x + t.normal * y + t.across * z
                        lo = simd_min(lo, p); hi = simd_max(hi, p)
                    }
                }
            }
            return (lo - pad, hi + pad)
        }
    }

    // MARK: - Surface nets

    /// The 12 cube edges as pairs of corners, a corner's bits being its x, y and z offsets.
    private static let edges: [(Int, Int)] = {
        var result: [(Int, Int)] = []
        for c in 0..<8 { for bit in [1, 2, 4] where c & bit == 0 { result.append((c, c | bit)) } }
        return result
    }()

    /// One vertex per cell the surface crosses, at the mean of its edge crossings, and one quad per
    /// crossed grid edge joining the four cells round it.
    @_optimize(speed)
    static func surfaceNets(_ g: [Float], nx: Int, ny: Int, nz: Int, origin: SIMD3<Float>, h: Float) -> BodyMesh {
        var mesh = BodyMesh()
        let cx = nx - 1, cy = ny - 1, cz = nz - 1
        guard cx > 0, cy > 0, cz > 0 else { return mesh }
        var cellVertex = [Int32](repeating: -1, count: cx * cy * cz)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var corner = [Float](repeating: 0, count: 8)
        func value(_ i: Int, _ j: Int, _ k: Int) -> Float {
            g[(min(max(k, 0), nz - 1) * ny + min(max(j, 0), ny - 1)) * nx + min(max(i, 0), nx - 1)]
        }
        func slope(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
            SIMD3(value(i + 1, j, k) - value(i - 1, j, k), value(i, j + 1, k) - value(i, j - 1, k), value(i, j, k + 1) - value(i, j, k - 1))
        }
        for k in 0..<cz {
            for j in 0..<cy {
                for i in 0..<cx {
                    var inside = 0
                    for c in 0..<8 {
                        let v = g[((k + (c >> 2 & 1)) * ny + j + (c >> 1 & 1)) * nx + i + (c & 1)]
                        corner[c] = v
                        if v < 0 { inside += 1 }
                    }
                    guard inside > 0, inside < 8 else { continue }
                    var sum = SIMD3<Float>(repeating: 0)
                    var crossings: Float = 0
                    for (a, b) in edges where (corner[a] < 0) != (corner[b] < 0) {
                        let t = corner[a] / (corner[a] - corner[b])
                        let pa = SIMD3<Float>(Float(a & 1), Float(a >> 1 & 1), Float(a >> 2 & 1))
                        let pb = SIMD3<Float>(Float(b & 1), Float(b >> 1 & 1), Float(b >> 2 & 1))
                        sum += pa + (pb - pa) * t
                        crossings += 1
                    }
                    let offset = sum / crossings
                    // The field's slope at each corner, blended to the vertex, so the shading runs smooth
                    // across cells instead of stepping at every one.
                    var gradient = SIMD3<Float>(repeating: 0)
                    for c in 0..<8 {
                        let dx = c & 1, dy = c >> 1 & 1, dz = c >> 2 & 1
                        let w = (dx == 1 ? offset.x : 1 - offset.x) * (dy == 1 ? offset.y : 1 - offset.y) * (dz == 1 ? offset.z : 1 - offset.z)
                        gradient += slope(i + dx, j + dy, k + dz) * w
                    }
                    let position = origin + (SIMD3(Float(i), Float(j), Float(k)) + offset) * h
                    cellVertex[(k * cy + j) * cx + i] = Int32(mesh.positions.count)
                    mesh.positions.append(position)
                    mesh.normals.append(simd_length(gradient) > 1e-8 ? simd_normalize(gradient) : [0, 1, 0])
                    lo = simd_min(lo, position); hi = simd_max(hi, position)
                }
            }
        }
        func cell(_ i: Int, _ j: Int, _ k: Int) -> Int32 { cellVertex[(k * cy + j) * cx + i] }
        func quad(_ q: (Int32, Int32, Int32, Int32), outward: Bool) {
            guard q.0 >= 0, q.1 >= 0, q.2 >= 0, q.3 >= 0 else { return }
            let (a, b, c, d) = (UInt32(q.0), UInt32(q.1), UInt32(q.2), UInt32(q.3))
            mesh.indices.append(contentsOf: outward ? [a, b, c, a, c, d] : [a, c, b, a, d, c])
        }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let v0 = g[(k * ny + j) * nx + i]
                    let inside = v0 < 0
                    // Each quad goes round its edge counter-clockwise seen from the edge's far end, so
                    // it faces that way when the inside is at the near end.
                    if i < cx, j > 0, k > 0, j < ny - 1, k < nz - 1, (g[(k * ny + j) * nx + i + 1] < 0) != inside {
                        quad((cell(i, j - 1, k - 1), cell(i, j, k - 1), cell(i, j, k), cell(i, j - 1, k)), outward: inside)
                    }
                    if j < cy, i > 0, k > 0, i < nx - 1, k < nz - 1, (g[(k * ny + j + 1) * nx + i] < 0) != inside {
                        quad((cell(i - 1, j, k - 1), cell(i - 1, j, k), cell(i, j, k), cell(i, j, k - 1)), outward: inside)
                    }
                    if k < cz, i > 0, j > 0, i < nx - 1, j < ny - 1, (g[((k + 1) * ny + j) * nx + i] < 0) != inside {
                        quad((cell(i - 1, j - 1, k), cell(i, j - 1, k), cell(i, j, k), cell(i - 1, j, k)), outward: inside)
                    }
                }
            }
        }
        mesh.lower = lo
        mesh.upper = hi
        return mesh
    }
}
