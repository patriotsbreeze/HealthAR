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
    private let chestAnchor = AnchorEntity(world: .zero)
    private let chestEstimate = Entity()
    private var limbModels: [LimbModel] = []
    /// The head, apart from the body, so it can sit where depth found the real one.
    private let detectedHead = Entity()
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
        chestAnchor.isEnabled = false
        chestAnchor.addChild(chestEstimate)
        arView.scene.addAnchor(chestAnchor)
        detectedAnchor.addChild(detectedHead)
        buildTrackedBody()
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
        tone = nil
    }

    private func refresh() {
        let trackedBody = vision.patientBodyPlacement()
        if patientLoaded, let placement = trackedBody {
            // Eases toward each new fit so frame-to-frame depth noise doesn't shake the body, but
            // snaps straight there when it first shows.
            let target = Transform(matrix: placement.transform)
            if detectedAnchor.isEnabled {
                var eased = detectedModel.transform
                eased.translation = simd_mix(eased.translation, target.translation, SIMD3(repeating: Self.bodyEasing))
                eased.scale = simd_mix(eased.scale, target.scale, SIMD3(repeating: Self.bodyEasing))
                eased.rotation = simd_slerp(eased.rotation, target.rotation, Self.bodyEasing)
                detectedModel.transform = eased
            } else {
                detectedModel.transform = target
            }
            placeHead(placement)
            placeLimbs(placement.limbs)
            detectedAnchor.isEnabled = true
        } else {
            detectedAnchor.isEnabled = false
        }
        let surface = vision.chestSurfacePlacement()
        if let surface {
            chestAnchor.isEnabled = true
            chestEstimate.position = surface.center
            chestEstimate.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: surface.normal)
        } else {
            chestAnchor.isEnabled = false
        }
        if handsLoaded, surface == nil, let placement = vision.handsPlacement() {
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

    /// The practice Blender mesh is intentionally untouched. The detected body has no fixed-pose
    /// arms or legs: rounded torso/head shapes use its proportions, and limbs follow measured joints.
    private func buildTrackedBody() {
        let sphere = MeshResource.generateSphere(radius: 1)
        let cylinder = MeshResource.generateCylinder(height: 1, radius: 1)
        let fill = Self.patientGlow(opacity: 0.07)
        var shell = Self.patientGlow(opacity: 0.48)
        shell.faceCulling = .front
        func ellipsoid(center: SIMD3<Float>, size: SIMD3<Float>) {
            let inside = ModelEntity(mesh: sphere, materials: [fill])
            inside.position = center
            inside.scale = size
            detectedFill.addChild(inside)
            let outside = ModelEntity(mesh: sphere, materials: [shell])
            outside.position = center
            outside.scale = size + SIMD3(repeating: 0.012)
            detectedShell.addChild(outside)
        }
        // Model-space values follow patient() in tools/make_ghost_model.py.
        ellipsoid(center: [-0.1, -0.1, 0], size: [0.31, 0.095, 0.17])
        ellipsoid(center: [-0.4, -0.1, 0], size: [0.12, 0.09, 0.16])
        ellipsoid(center: [0.25, -0.1, 0], size: [0.08, 0.05, 0.05])
        let headFill = ModelEntity(mesh: sphere, materials: [fill])
        headFill.scale = [0.1, 0.08, 0.075]
        let headShell = ModelEntity(mesh: sphere, materials: [shell])
        headShell.scale = [0.112, 0.092, 0.087]
        detectedHead.addChild(headFill)
        detectedHead.addChild(headShell)
        for _ in 0..<8 {
            let limb = LimbModel(sphere: sphere, cylinder: cylinder, fill: fill, shell: shell)
            detectedAnchor.addChild(limb.root)
            limbModels.append(limb)
        }
        patientLoaded = true
        vision.patientModelDidLoad()
    }

    private func placeLimbs(_ limbs: [TrackedBodyLimb]) {
        for index in limbModels.indices {
            guard index < limbs.count else { limbModels[index].root.isEnabled = false; continue }
            limbModels[index].place(limbs[index])
        }
    }

    /// Cached geometry: rotate and resize each segment between its measured endpoints each frame.
    /// It is deliberately independent of the torso's nonuniform scale and smoothing.
    @MainActor
    private struct LimbModel {
        let root = Entity()
        let tubes: [ModelEntity]
        let starts: [ModelEntity]
        let ends: [ModelEntity]

        init(sphere: MeshResource, cylinder: MeshResource, fill: PhysicallyBasedMaterial, shell: PhysicallyBasedMaterial) {
            tubes = [ModelEntity(mesh: cylinder, materials: [fill]), ModelEntity(mesh: cylinder, materials: [shell])]
            starts = [ModelEntity(mesh: sphere, materials: [fill]), ModelEntity(mesh: sphere, materials: [shell])]
            ends = [ModelEntity(mesh: sphere, materials: [fill]), ModelEntity(mesh: sphere, materials: [shell])]
            for part in tubes + starts + ends { root.addChild(part) }
            root.isEnabled = false
        }

        func place(_ limb: TrackedBodyLimb) {
            let delta = limb.end - limb.start
            let length = simd_length(delta)
            guard length > 0.01 else { root.isEnabled = false; return }
            root.isEnabled = true
            for i in 0..<2 {
                let radius = limb.radius + (i == 0 ? 0 : 0.008)
                tubes[i].position = (limb.start + limb.end) / 2
                tubes[i].scale = [radius, length, radius]
                tubes[i].orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
                starts[i].position = limb.start
                ends[i].position = limb.end
                starts[i].scale = SIMD3(repeating: radius)
                ends[i].scale = SIMD3(repeating: radius)
            }
        }
    }

    /// The head where depth found it, or where the fitted body's own head would be when no face was
    /// seen. It turns and sizes with the body, but isn't stretched by the torso's own length and width.
    private func placeHead(_ placement: PatientBodyPlacement) {
        guard !detectedHead.children.isEmpty else { return }
        let template = placement.transform * SIMD4(PatientModelFit.headCenter, 1)
        let target = placement.head ?? SIMD3(template.x, template.y, template.z)
        let body = detectedModel.transform
        let size = (body.scale.x + body.scale.y + body.scale.z) / 3
        detectedHead.orientation = body.rotation
        detectedHead.scale = SIMD3(repeating: size)
        detectedHead.position = detectedAnchor.isEnabled && detectedHead.isEnabled
            ? simd_mix(detectedHead.position, target, SIMD3(repeating: Self.bodyEasing))
            : target
        detectedHead.isEnabled = true
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
        material.metallic = 0.0
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    private static let patientColor = UIColor(white: 0.92, alpha: 1)
    /// The share of the way to the latest fit the tracked body moves each rendered frame.
    private static let bodyEasing: Float = 0.2
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
