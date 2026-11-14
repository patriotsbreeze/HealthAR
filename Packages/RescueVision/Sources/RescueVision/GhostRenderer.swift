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
    private var patientLoaded = false
    /// The real head and legs, placed on their own rather than carried by the torso's transform.
    private let detectedHead = Entity()
    private let detectedLegs = TrackedLegs()

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
        detectedAnchor.addChild(detectedLegs.root)
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
              let outline = root.findEntity(named: "PatientOutline"),
              let trackedBody = root.findEntity(named: "TrackedBody"),
              let trackedBodyOutline = root.findEntity(named: "TrackedBodyOutline"),
              let trackedHead = root.findEntity(named: "TrackedHead"),
              let trackedHeadOutline = root.findEntity(named: "TrackedHeadOutline")
        else { return }
        let headFill = Entity(), headShell = Entity()
        detectedHead.addChild(headFill)
        detectedHead.addChild(headShell)
        for (part, parent) in [
            (upper, rescuer), (lower, rescuer), (patient, patientFill), (outline, patientOutline),
            (trackedBody, detectedFill), (trackedBodyOutline, detectedShell),
            (trackedHead, headFill), (trackedHeadOutline, headShell),
        ] {
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
        let fill = Self.patientGlow(opacity: 0.048)
        var glow = Self.patientGlow(opacity: 0.48)
        glow.faceCulling = .front
        apply(fill, to: detectedFill)
        apply(glow, to: detectedShell)
        apply(fill, to: headFill)
        apply(glow, to: headShell)
        detectedLegs.build(fill: fill, shell: glow)
        patientLoaded = true
        vision.patientModelDidLoad()
        tone = nil
    }

    private func refresh() {
        let trackedBody = vision.patientBodyPlacement()
        if patientLoaded, let placement = trackedBody {
            // Eases toward each new fit so frame-to-frame depth noise doesn't shake the body, but
            // snaps straight there when it first shows.
            let target = Transform(matrix: placement.transform)
            var headTarget = target
            headTarget.translation = placement.head ?? (placement.transform * SIMD4(PatientModelFit.headCenter, 1)).xyz
            let ease: Float = detectedAnchor.isEnabled ? Self.bodyEasing : 1
            detectedModel.transform = Self.eased(detectedModel.transform, toward: target, by: ease)
            detectedHead.transform = Self.eased(detectedHead.transform, toward: headTarget, by: ease)
            detectedLegs.update(placement, scale: target.scale.y, easing: ease)
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
        // Only on place_hands or the hands guide, on a lying patient's chest: the CPR steps.
        if handsLoaded, let placement = vision.handsPlacement() {
            handsAnchor.isEnabled = true
            var transform = Transform(matrix: placement.transform)
            // On the estimated sternum region when there is one, so the hands sit on its marker.
            if let surface { transform.translation = surface.center }
            hands.transform = transform
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
        material.metallic = 0.0
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    private static func eased(_ from: Transform, toward to: Transform, by t: Float) -> Transform {
        var eased = from
        eased.translation = simd_mix(from.translation, to.translation, SIMD3(repeating: t))
        eased.scale = simd_mix(from.scale, to.scale, SIMD3(repeating: t))
        eased.rotation = simd_slerp(from.rotation, to.rotation, t)
        return eased
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

/// Thighs and shins as glowing tubes between the hips, knees and ankles, with a ball at each knee
/// and ankle so the bends stay round. A joint that wasn't seen hangs from the one above it along the
/// template leg, so a half-seen leg still reads as a leg.
@MainActor
private final class TrackedLegs {
    let root = Entity()
    private struct Piece { let fill: ModelEntity; let shell: ModelEntity }
    private var bones: [BodyJoint: Piece] = [:]
    private var balls: [BodyJoint: Piece] = [:]
    private var points: [BodyJoint: SIMD3<Float>] = [:]

    /// Bone from its parent joint to this one, and its radius in template metres, from patient().
    private static let bones: [(joint: BodyJoint, parent: BodyJoint, radius: Float)] = [
        (.leftKnee, .leftHip, 0.075), (.leftAnkle, .leftKnee, 0.05),
        (.rightKnee, .rightHip, 0.075), (.rightAnkle, .rightKnee, 0.05),
    ]
    private static let shellGrowth: Float = 0.015

    func build(fill: any Material, shell: any Material) {
        let tube = MeshResource.generateCylinder(height: 1, radius: 1)
        let ball = MeshResource.generateSphere(radius: 1)
        for bone in Self.bones {
            bones[bone.joint] = add(tube, fill: fill, shell: shell)
            balls[bone.joint] = add(ball, fill: fill, shell: shell)
        }
    }

    private func add(_ mesh: MeshResource, fill: any Material, shell: any Material) -> Piece {
        let piece = Piece(fill: ModelEntity(mesh: mesh, materials: [fill]), shell: ModelEntity(mesh: mesh, materials: [shell]))
        root.addChild(piece.fill)
        root.addChild(piece.shell)
        return piece
    }

    func update(_ placement: PatientBodyPlacement, scale: Float, easing: Float) {
        let template = PatientModelFit.templateLegs
        var targets: [BodyJoint: SIMD3<Float>] = [:]
        for hip in [BodyJoint.leftHip, .rightHip] {
            targets[hip] = placement.legs[hip] ?? (placement.transform * SIMD4(template[hip]!, 1)).xyz
        }
        for bone in Self.bones {
            let parent = targets[bone.parent]!
            targets[bone.joint] = placement.legs[bone.joint]
                ?? parent + (placement.transform * SIMD4(template[bone.joint]! - template[bone.parent]!, 0)).xyz
        }
        for (joint, target) in targets {
            points[joint] = points[joint].map { simd_mix($0, target, SIMD3(repeating: easing)) } ?? target
        }
        for bone in Self.bones {
            guard let a = points[bone.parent], let b = points[bone.joint],
                  let tube = bones[bone.joint], let ball = balls[bone.joint] else { continue }
            let radius = bone.radius * scale
            let length = max(simd_distance(a, b), 0.001)
            let orientation = simd_quatf(from: [0, 1, 0], to: (b - a) / length)
            for (entity, r) in [(tube.fill, radius), (tube.shell, radius + Self.shellGrowth)] {
                entity.transform = Transform(scale: [r, length, r], rotation: orientation, translation: (a + b) / 2)
            }
            for (entity, r) in [(ball.fill, radius), (ball.shell, radius + Self.shellGrowth)] {
                entity.transform = Transform(scale: SIMD3(repeating: r), rotation: orientation, translation: b)
            }
        }
    }
}
