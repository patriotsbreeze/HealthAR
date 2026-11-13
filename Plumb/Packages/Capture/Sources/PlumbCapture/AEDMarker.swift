import RealityKit
import UIKit

/// The AED's place in the room: a thin green stem rising from the device to a small disc, at true
/// size, in the one colour the app keeps for the AED. Unlit, so it reads the same in any light.
enum AEDMarker {
    static let stemHeightM: Float = 0.45
    static let stemRadiusM: Float = 0.006
    static let discRadiusM: Float = 0.05
    static let discThicknessM: Float = 0.006

    /// A new marker whose foot is at its own origin.
    @MainActor
    static func make() -> Entity {
        let green = UnlitMaterial(color: GuideColours.aed)
        let root = Entity()
        let stem = ModelEntity(mesh: .generateCylinder(height: stemHeightM, radius: stemRadiusM), materials: [green])
        stem.position = [0, stemHeightM / 2, 0]
        let disc = ModelEntity(mesh: .generateCylinder(height: discThicknessM, radius: discRadiusM), materials: [green])
        disc.position = [0, stemHeightM, 0]
        root.addChild(stem)
        root.addChild(disc)
        return root
    }

    /// The points of a marker standing at `foot` that count as seeing it: its foot and its disc.
    static func marks(standingAt foot: SIMD3<Float>) -> [SIMD3<Float>] {
        [foot, foot + SIMD3(0, stemHeightM, 0)]
    }
}
