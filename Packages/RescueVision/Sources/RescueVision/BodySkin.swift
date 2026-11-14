#if os(iOS)
import QuartzCore
import RealityKit
import simd

/// The tracked body's one skin in the AR scene: a see-through fill and an outline shell round it.
/// The surface is rebuilt off the main thread from the newest pieces; while one rebuild runs, newer
/// pieces wait for the next, so a slow rebuild never stalls the camera.
@MainActor
final class BodySkin {
    let root = Entity()
    private let fill: ModelEntity
    private let shell: ModelEntity
    private var fillMesh: LowLevelMesh?
    private var shellMesh: LowLevelMesh?
    private var vertexCapacity = 0
    private var indexCapacity = 0
    private var busy = false
    /// Bumped by `clear`, so a rebuild that started before it never lands after it.
    private var generation = 0
    private static let shellGrow: Float = 0.008

    /// The last rebuild's time and size, for the log.
    private(set) var lastBuildMs = 0.0
    private(set) var lastVertices = 0
    /// Grid spacing for the next build: coarser while builds run slow, finer again once they're quick.
    private(set) var cell = BodySurface.cell
    private static let slowBuildMs = 20.0, quickBuildMs = 9.0

    init(fill fillMaterial: some Material, shell shellMaterial: some Material, group: ModelSortGroup) {
        fill = ModelEntity()
        shell = ModelEntity()
        fill.model = ModelComponent(mesh: .generateBox(size: 0.001), materials: [fillMaterial])
        shell.model = ModelComponent(mesh: .generateBox(size: 0.001), materials: [shellMaterial])
        fill.components.set(ModelSortGroupComponent(group: group, order: 0))
        shell.components.set(ModelSortGroupComponent(group: group, order: 1))
        fill.isEnabled = false
        shell.isEnabled = false
        root.addChild(fill)
        root.addChild(shell)
    }

    func submit(_ pieces: [BodyPiece]) {
        guard !busy, !pieces.isEmpty else { return }
        busy = true
        let started = generation, cell = cell
        Task.detached(priority: .userInitiated) { [weak self] in
            let start = CACurrentMediaTime()
            let mesh = BodySurface.mesh(pieces, cell: cell)
            let ms = (CACurrentMediaTime() - start) * 1000
            await self?.finish(mesh, ms: ms, generation: started)
        }
    }

    func clear() {
        generation += 1
        fill.isEnabled = false
        shell.isEnabled = false
    }

    private func finish(_ mesh: BodyMesh, ms: Double, generation started: Int) {
        busy = false
        guard started == generation else { return }
        lastBuildMs = ms
        lastVertices = mesh.positions.count
        // Each step changes the work by roughly the cube of the spacing.
        if ms > Self.slowBuildMs {
            cell = min(cell * 1.2, BodySurface.coarsestCell)
        } else if ms < Self.quickBuildMs {
            cell = max(cell / 1.05, BodySurface.cell)
        }
        guard !mesh.indices.isEmpty, reserve(vertices: mesh.positions.count, indices: mesh.indices.count),
              let fillMesh, let shellMesh else {
            fill.isEnabled = false
            shell.isEnabled = false
            return
        }
        let bounds = BoundingBox(min: mesh.lower - 0.02, max: mesh.upper + 0.02)
        Self.upload(mesh, grow: 0, bounds: bounds, to: fillMesh)
        Self.upload(mesh, grow: Self.shellGrow, bounds: bounds, to: shellMesh)
        fill.isEnabled = true
        shell.isEnabled = true
    }

    /// Room for this many, growing both meshes with headroom when a bigger body needs it.
    private func reserve(vertices: Int, indices: Int) -> Bool {
        if vertices <= vertexCapacity, indices <= indexCapacity { return true }
        let v = max(vertices * 3 / 2, 8_000), i = max(indices * 3 / 2, 48_000)
        guard let newFill = Self.makeMesh(vertices: v, indices: i), let newShell = Self.makeMesh(vertices: v, indices: i),
              let fillResource = try? MeshResource(from: newFill), let shellResource = try? MeshResource(from: newShell) else { return false }
        fillMesh = newFill
        shellMesh = newShell
        fill.model?.mesh = fillResource
        shell.model?.mesh = shellResource
        vertexCapacity = v
        indexCapacity = i
        return true
    }

    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    private static func makeMesh(vertices: Int, indices: Int) -> LowLevelMesh? {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertices
        descriptor.indexCapacity = indices
        descriptor.indexType = .uint32
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        return try? LowLevelMesh(descriptor: descriptor)
    }

    private static func upload(_ mesh: BodyMesh, grow: Float, bounds: BoundingBox, to target: LowLevelMesh) {
        target.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let buffer = raw.bindMemory(to: Vertex.self)
            for i in mesh.positions.indices {
                buffer[i] = Vertex(position: mesh.positions[i] + mesh.normals[i] * grow, normal: mesh.normals[i])
            }
        }
        target.withUnsafeMutableIndices { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            for i in mesh.indices.indices { buffer[i] = mesh.indices[i] }
        }
        target.parts.replaceAll([LowLevelMesh.Part(indexCount: mesh.indices.count, topology: .triangle, bounds: bounds)])
    }
}
#endif
