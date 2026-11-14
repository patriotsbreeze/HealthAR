import Foundation
import Testing
import simd
@testable import RescueVision

struct BodySurfaceTests {
    /// A lying adult: torso along x, face up along y, arms out and bent, legs apart.
    private func lyingBody() -> [BodyPiece] {
        let model = simd_float4x4(columns: ([1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]))
        let neck = TorsoProfile.neckBase
        let head = SIMD3<Float>(0.45, TorsoProfile.depth, 0)
        return [
            .torso(TorsoLoft(model: model)),
            .ellipsoid(center: head, axes: matrix_identity_float3x3, radii: [0.1, 0.08, 0.075]),
            .cone(from: neck, to: head, r1: 0.05, r2: 0.045),
            .cone(from: [0.14, -0.12, 0.2], to: [0.0, -0.1, 0.45], r1: 0.047, r2: 0.04),
            .cone(from: [0.0, -0.1, 0.45], to: [0.2, -0.05, 0.6], r1: 0.04, r2: 0.03),
            .cone(from: [-0.42, -0.14, 0.1], to: [-0.85, -0.14, 0.16], r1: 0.075, r2: 0.06),
            .cone(from: [-0.85, -0.14, 0.16], to: [-1.25, -0.14, 0.2], r1: 0.06, r2: 0.04),
        ]
    }

    /// How many separate pieces a mesh is in, by triangles that share a vertex.
    private func components(_ mesh: BodyMesh) -> Int {
        var parent = Array(0..<mesh.positions.count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = root(Int(mesh.indices[t]))
            parent[root(Int(mesh.indices[t + 1]))] = a
            parent[root(Int(mesh.indices[t + 2]))] = a
        }
        return Set(Set(mesh.indices.map(Int.init)).map(root)).count
    }

    @Test func limbsTorsoAndHeadBlendIntoOneSkin() {
        let mesh = BodySurface.mesh(lyingBody())
        #expect(mesh.positions.count > 1000)
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.positions.count })
        #expect(components(mesh) == 1)
    }

    @Test func trianglesFaceOutTheSameWayAsTheirNormals() {
        let mesh = BodySurface.mesh(lyingBody())
        var agree = 0, faces = 0
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[t]), b = Int(mesh.indices[t + 1]), c = Int(mesh.indices[t + 2])
            let face = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
            guard simd_length(face) > 1e-10 else { continue }
            faces += 1
            if simd_dot(face, mesh.normals[a] + mesh.normals[b] + mesh.normals[c]) > 0 { agree += 1 }
        }
        #expect(faces > 0)
        #expect(Double(agree) / Double(faces) > 0.99)
    }

    @Test func aRoundConeIsExactOnItsSurface() {
        let d = BodySurface.roundCone([0, 0.05, 0.2], [0, 0, 0], [0, 0, 0.4], 0.05, 0.05)
        #expect(abs(d) < 1e-4)
        #expect(BodySurface.roundCone([0, 0, 0.2], [0, 0, 0], [0, 0, 0.4], 0.05, 0.05) < 0)
    }

    @Test func theTorsoSitsBehindTheMeasuredChestSurface() {
        let table = TorsoProfile.table
        #expect(TorsoProfile.depth < PatientModelFit.bodyY)
        #expect(table.x0 < PatientModelFit.hipsX)
        #expect(table.x1 > PatientModelFit.shouldersX)
        #expect(table.a.count == table.b.count)
    }

    @Test func aWholeBodyBuildsQuickly() {
        let pieces = lyingBody()
        let start = Date()
        _ = BodySurface.mesh(pieces)
        #expect(Date().timeIntervalSince(start) < 0.05)
    }
}
