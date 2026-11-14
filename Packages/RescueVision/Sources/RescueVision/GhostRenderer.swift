#if os(iOS)
import Combine
import RealityKit
import UIKit
import simd

/// Draws the ghost rescuer, and the practice patient, as see-through 3D bodies in the AR view, lit
/// by the room. Reads `VisionSession.ghostPlacement()` once a rendered frame and only ever draws.
@MainActor
final class GhostRenderer {
    private let vision: VisionSession
    private let anchor = AnchorEntity(world: .zero)
    private let model = Entity()
    private let rescuer = Entity()
    /// The patient, scaled to the body found: its fill for practice, and its outline always.
    private let patientGroup = Entity()
    private let patientFill = Entity()
    private let patientOutline = Entity()
    private var upper: Entity?
    private var upperRest = SIMD3<Float>.zero
    private var tone: GhostPlacement.Tone?
    private var update: (any Cancellable)?
    /// The stacked hands on the chest, for place_hands and the hands guide.
    private let handsAnchor = AnchorEntity(world: .zero)
    private let hands = Entity()
    private var handsLoaded = false
    /// Separate from the practice/animated ghost: tracks the currently observed real patient.
    private let detectedAnchor = AnchorEntity(world: .zero)
    private let detectedModel = Entity()
    private let detectedFill = Entity()
    private let detectedShell = Entity()
    private let chestEstimate = Entity()
    private var patientLoaded = false

    init(arView: ARView, vision: VisionSession) {
        self.vision = vision
        anchor.isEnabled = false
        anchor.addChild(model)
        model.addChild(rescuer)
        model.addChild(patientGroup)
        patientGroup.addChild(patientFill)
        patientGroup.addChild(patientOutline)
        // A soft key light from above, so the bodies read as rounded even before ARKit has the room's light.
        let light = DirectionalLight()
        light.light.intensity = 1500
        light.look(at: [0, 0, 0], from: [0.4, 2, 0.6], relativeTo: nil)
        model.addChild(light)
        arView.scene.addAnchor(anchor)
        handsAnchor.isEnabled = false
        handsAnchor.addChild(hands)
        let handsLight = DirectionalLight()
        handsLight.light.intensity = 1200
        handsLight.look(at: [0, 0, 0], from: [0.3, 1, 0.5], relativeTo: nil)
        handsAnchor.addChild(handsLight)
        arView.scene.addAnchor(handsAnchor)
        detectedAnchor.isEnabled = false
        detectedAnchor.addChild(detectedModel)
        detectedModel.addChild(detectedFill)
        detectedModel.addChild(detectedShell)
        detectedAnchor.addChild(chestEstimate)
        // A coarse surface disc, not a pin claiming to identify a bone.
        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.004, radius: 0.045),
            materials: [Self.patientGlow(opacity: 0.45)]
        )
        chestEstimate.addChild(disc)
        arView.scene.addAnchor(detectedAnchor)
        update = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Task {
            await load()
            await loadHands()
        }
    }

    private func loadHands() async {
        guard let url = Bundle.module.url(forResource: "Hands", withExtension: "usdz"),
              let root = try? await Entity(contentsOf: url)
        else { return }
        hands.addChild(root)
        apply(PhysicallyBasedMaterial.glassHand, to: hands)
        handsLoaded = true
    }

    private func load() async {
        guard let url = Bundle.module.url(forResource: "Ghost", withExtension: "usdz"),
              let root = try? await Entity(contentsOf: url),
              let upper = root.findEntity(named: "RescuerUpper"),
              let lower = root.findEntity(named: "RescuerLower"),
              let patient = root.findEntity(named: "Patient"),
              let outline = root.findEntity(named: "PatientOutline")
        else { return }
        for (part, parent) in [(upper, rescuer), (lower, rescuer), (patient, patientFill), (outline, patientOutline)] {
            let world = part.transformMatrix(relativeTo: nil)
            part.removeFromParent()
            part.transform = Transform(matrix: world)
            parent.addChild(part)
        }
        self.upper = upper
        upperRest = upper.position
        paint(patientFill, color: Self.patientColor)
        // An inverted hull: only the back faces of a slightly bigger body show, as a line round the real one.
        var line = UnlitMaterial(color: Self.patientColor)
        line.faceCulling = .front
        apply(line, to: patientOutline)
        detectedFill.addChild(patient.clone(recursive: true))
        detectedShell.addChild(outline.clone(recursive: true))
        apply(Self.patientGlow(opacity: 0.08), to: detectedFill)
        var glow = Self.patientGlow(opacity: 0.8)
        glow.faceCulling = .front
        apply(glow, to: detectedShell)
        patientLoaded = true
        vision.patientModelDidLoad()
        tone = nil
    }

    private func refresh() {
        let trackedBody = vision.patientBodyPlacement()
        if patientLoaded, let placement = trackedBody {
            detectedAnchor.isEnabled = true
            detectedModel.transform = Transform(matrix: placement.transform)
            chestEstimate.isEnabled = placement.showsChestEstimate
            chestEstimate.position = placement.chest
            chestEstimate.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: placement.normal)
        } else {
            detectedAnchor.isEnabled = false
        }
        if handsLoaded, !(patientLoaded && trackedBody?.showsChestEstimate == true), let placement = vision.handsPlacement() {
            handsAnchor.isEnabled = true
            hands.transform = Transform(matrix: placement.transform)
        } else {
            handsAnchor.isEnabled = false
        }
        guard upper != nil, let placement = vision.ghostPlacement() else {
            anchor.isEnabled = false
            return
        }
        anchor.isEnabled = true
        model.transform = Transform(matrix: placement.transform)
        upper?.position = upperRest - SIMD3(0, GhostPlacement.depth * Float(placement.push), 0)
        if placement.tone != tone {
            tone = placement.tone
            paint(rescuer, color: Self.color(placement.tone))
        }
        rescuer.components.set(OpacityComponent(opacity: GhostPlacement.opacity + GhostPlacement.pushOpacity * Float(placement.push)))
        patientGroup.scale = SIMD3(repeating: placement.patientScale)
        patientFill.isEnabled = placement.practice
        patientFill.components.set(OpacityComponent(opacity: GhostPlacement.patientOpacity))
        // The depth-fitted real body replaces the older rigid ghost-patient shell.
        patientOutline.isEnabled = placement.practice || trackedBody == nil
        patientOutline.components.set(OpacityComponent(opacity: GhostPlacement.outlineOpacity))
    }

    private func paint(_ entity: Entity, color: UIColor) {
        apply(SimpleMaterial(color: color, roughness: 0.55, isMetallic: false), to: entity)
    }

    private func apply(_ material: any Material, to entity: Entity) {
        visit(entity) { node in
            guard var component = node.components[ModelComponent.self] else { return }
            component.materials = Array(repeating: material, count: max(1, component.materials.count))
            node.components.set(component)
        }
    }

    private func visit(_ entity: Entity, _ body: (Entity) -> Void) {
        body(entity)
        for child in entity.children { visit(child, body) }
    }

    /// The app's target cyan, the system's green and amber.
    private static func color(_ tone: GhostPlacement.Tone) -> UIColor {
        switch tone {
        case .neutral: UIColor(red: 0x3C / 255, green: 0xD3 / 255, blue: 0xFE / 255, alpha: 1)
        case .matching: UIColor(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255, alpha: 1)
        case .correcting: UIColor(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x20 / 255, alpha: 1)
        }
    }

    /// Emissive glass remains visible in dim rooms without covering the real chest.
    private static func patientGlow(opacity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        let cyan = UIColor(red: 0.12, green: 0.65, blue: 1, alpha: 1)
        material.baseColor = .init(tint: cyan)
        material.emissiveColor = .init(color: cyan)
        material.emissiveIntensity = 1.6
        material.roughness = 0.25
        material.metallic = 0
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    private static let patientColor = UIColor(white: 0.92, alpha: 1)
}

extension PhysicallyBasedMaterial {
    /// Clear blue glass: see-through so the chest shows, glossy so the room's light catches its edges
    /// and gives each hand a rim, and faintly lit from within so it reads in a dim room.
    static var glassHand: PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: 0.18, green: 0.48, blue: 1, alpha: 1))
        material.roughness = 0.12
        material.metallic = 0.0
        material.specular = 1.0
        material.clearcoat = 1.0
        material.clearcoatRoughness = 0.05
        material.emissiveColor = .init(color: UIColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
        material.emissiveIntensity = 0.25
        material.blending = .transparent(opacity: .init(floatLiteral: HandsPlacement.opacity))
        material.faceCulling = .back
        return material
    }
}
#endif
