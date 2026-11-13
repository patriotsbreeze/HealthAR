import RealityKit
import UIKit

/// The ring on the chest and the target line as RealityKit entities, true to size, under one root
/// that stands at the world's origin so positions are world positions. Built once; each frame only
/// moves them and switches them on or off. Unlit, so they read the same in any light, and drawn
/// behind people where people occlusion is running. Main thread only.
@MainActor
final class GuideEntities {
    /// Radius of the middle of the ring's band, in metres: about where the heel of the hand goes.
    static let ringRadiusM: Float = 0.04
    /// Width of the ring's band, in metres.
    static let ringWidthM: Float = 0.005
    /// Length of the target line, in metres.
    static let lineLengthM = 0.25
    /// Thickness of the target line, both up and across, in metres.
    static let lineThicknessM: Float = 0.0035
    /// Dashes and the gaps between them when depth is not trusted, in metres.
    static let dashM = 0.02
    static let gapM = 0.015

    /// Place this at the world's origin.
    let root = Entity()
    private let ring: Entity
    private let line = Entity()
    private let solid: Entity
    private let dashed: Entity

    init() {
        var paper = UnlitMaterial(color: GuideColours.paper)
        // The ring is a flat band with one face. Unculled it shows from either side, so it cannot
        // vanish whichever way the camera sees it; the closed boxes of the line do not mind.
        paper.faceCulling = .none
        ring = Self.ringEntity(material: paper)
        solid = Self.bar(DashPattern.solid(lengthM: Self.lineLengthM), material: paper)
        dashed = Self.bar(DashPattern.dashed(lengthM: Self.lineLengthM, dashM: Self.dashM, gapM: Self.gapM),
                          material: paper)
        line.addChild(solid)
        line.addChild(dashed)
        root.addChild(ring)
        root.addChild(line)
        ring.isEnabled = false
        line.isEnabled = false
    }

    /// Moves the guides to `placement` and shows each one that `state` allows and that has a place.
    func apply(_ placement: GuidePlacement, state: GuideState) {
        if state.showsRing, let at = placement.ring {
            ring.transform = Transform(rotation: at.rotation, translation: SIMD3<Float>(at.centre))
            ring.isEnabled = true
        } else {
            ring.isEnabled = false
        }
        if let style = state.lineStyle, let at = placement.line {
            line.transform = Transform(rotation: at.rotation, translation: SIMD3<Float>(at.centre))
            solid.isEnabled = style == .solid
            dashed.isEnabled = style == .dashed
            line.isEnabled = true
        } else {
            line.isEnabled = false
        }
    }

    /// The ring as one flat mesh. Should the mesh not build, the ring is an empty entity and draws nothing.
    private static func ringEntity(material: UnlitMaterial) -> Entity {
        let shape = RingShape(innerRadiusM: ringRadiusM - ringWidthM / 2, outerRadiusM: ringRadiusM + ringWidthM / 2,
                              segments: 96)
        var descriptor = MeshDescriptor(name: "ring")
        descriptor.positions = MeshBuffers.Positions(shape.positions)
        descriptor.primitives = .triangles(shape.triangles)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// A bar along its own x axis made of `pieces`, centred on its origin.
    private static func bar(_ pieces: [DashPattern.Piece], material: UnlitMaterial) -> Entity {
        let bar = Entity()
        for piece in pieces {
            let box = ModelEntity(mesh: .generateBox(width: Float(piece.length), height: lineThicknessM,
                                                     depth: lineThicknessM), materials: [material])
            box.position = [Float(piece.centre), 0, 0]
            bar.addChild(box)
        }
        return bar
    }
}
