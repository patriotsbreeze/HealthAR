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
    private let chestAnchor = AnchorEntity(world: .zero)
    private let chestEstimate = Entity()
    private var limbs = TrackedLimbs()
    /// The torso, head, neck and limbs blended into one surface.
    private var skin: BodySkin?
    private weak var arView: ARView?
    /// Where the head is, apart from the body, so it can sit where depth found the real one.
    private let detectedHead = Entity()
    private var patientLoaded = false
    private var stats = BodyLog()
    private var alignmentFrame = 0

    /// One console line a second about the tracked 3D body, for watching it on a device.
    private struct BodyLog {
        var start = CACurrentMediaTime(), last = CACurrentMediaTime()
        var frames = 0, shown = 0, measured = 0, drawn = 0, worstFrame = 0.0, placementChanges = 0
        var worstBuild = 0.0, vertices = 0
        /// Screen distance from each limb end to its 2D joint dot, and how many ends had inferred depth.
        var offsets: [Double] = [], ends = 0, inferred = 0

        mutating func alignment(_ placement: PatientBodyPlacement, view: ARView, bodies: [VisionOverlay.DetectedBody]) {
            let size = view.bounds.size
            guard size.width > 0, let body = bodies.max(by: { $0.joints.count < $1.joints.count }) else { return }
            for limb in placement.limbs {
                ends += 1
                if limb.inferredDepth { inferred += 1 }
                guard let dot = body.joints[limb.to], let drawn = view.project(limb.end) else { continue }
                offsets.append(hypot(drawn.x - dot.x * size.width, drawn.y - dot.y * size.height))
            }
        }
        var lastPlacement: PatientBodyPlacement?

        var cell: Float = 0

        mutating func frame(_ placement: PatientBodyPlacement?, drawn limbs: Int, buildMs: Double, vertices skin: Int, cell grid: Float) {
            let now = CACurrentMediaTime()
            worstFrame = max(worstFrame, now - last)
            last = now
            frames += 1
            if let placement {
                shown += 1
                measured += placement.limbs.count
                drawn += limbs
                if placement != lastPlacement { placementChanges += 1 }
                worstBuild = max(worstBuild, buildMs)
                vertices = skin
                cell = grid
            }
            lastPlacement = placement
            guard now - start >= 1 else { return }
            let f = Double(max(frames, 1)), s = Double(max(shown, 1))
            let sorted = offsets.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2], worstOffset = sorted.last ?? 0
            let thermal = ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]
            print(String(format: "[Body3D] fps %.0f worst %.0fms | thermal %@ | body shown %d%% | new fits/s %d | limbs measured %.1f drawn %.1f | skin %.0fms %d verts %.1fcm grid | limb-to-dot median %.0fpt worst %.0fpt | inferred depth %d/%d",
                         f / (now - start), worstFrame * 1000, thermal, Int(Double(shown) / f * 100), placementChanges,
                         Double(measured) / s, Double(drawn) / s, worstBuild, vertices, cell * 100, median, worstOffset, inferred, ends))
            self = BodyLog(start: now, last: now, lastPlacement: lastPlacement)
        }
    }

    init(arView: ARView, vision: VisionSession) {
        self.vision = vision
        self.arView = arView
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
            skin?.submit(skinPieces(placement))
            alignmentFrame += 1
            if alignmentFrame % 6 == 0, let arView { stats.alignment(placement, view: arView, bodies: vision.overlay().bodies) }
            detectedAnchor.isEnabled = true
        } else {
            detectedAnchor.isEnabled = false
            limbs.reset()
            skin?.clear()
        }
        stats.frame(patientLoaded ? trackedBody : nil, drawn: limbs.drawn, buildMs: skin?.lastBuildMs ?? 0, vertices: skin?.lastVertices ?? 0, cell: skin?.cell ?? 0)
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

    /// The practice Blender mesh is intentionally untouched. The detected body has no fixed-pose arms or
    /// legs: its torso and head use the Blender proportions, its limbs follow measured joints, and all of
    /// it is blended into one skin.
    private func buildTrackedBody() {
        let fill = Self.patientGlow(opacity: 0.07)
        var shell = Self.patientGlow(opacity: 0.48)
        shell.faceCulling = .front
        // The group's depth goes down first, so only the skin's nearest surface draws and the outline
        // shell shows round the silhouette alone.
        let skin = BodySkin(fill: fill, shell: shell, group: ModelSortGroup(depthPass: .prePass))
        detectedAnchor.addChild(skin.root)
        self.skin = skin
        patientLoaded = true
        vision.patientModelDidLoad()
    }

    /// Everything the skin is made of this frame, in world metres: the eased torso, the head, the neck
    /// joining them, and the measured limbs.
    private func skinPieces(_ placement: PatientBodyPlacement) -> [BodyPiece] {
        let model = detectedModel.transform.matrix
        var pieces: [BodyPiece] = [.torso(TorsoLoft(model: model))]
        let head = detectedHead.position
        let size = detectedHead.scale.x
        pieces.append(.ellipsoid(center: head, axes: simd_float3x3(detectedHead.orientation), radii: Self.headRadii * size))
        let neckBase = model * SIMD4(TorsoProfile.neckBase, 1)
        let neck = SIMD3(neckBase.x, neckBase.y, neckBase.z)
        // A head found far off the shoulders isn't joined on with a stretched neck.
        if simd_distance(neck, head) < 0.35 {
            pieces.append(.cone(from: neck, to: head, r1: 0.05 * size, r2: 0.045 * size))
        }
        pieces += limbs.update(placement.limbs, camera: arView?.cameraTransform.translation, now: CACurrentMediaTime())
        return pieces
    }

    /// The template head's half sizes, from HEAD_SIZE in tools/make_ghost_model.py.
    private static let headRadii = SIMD3<Float>(0.1, 0.08, 0.075)

    /// The head where depth found it, or where the fitted body's own head would be when no face was
    /// seen. It turns and sizes with the body, but isn't stretched by the torso's own length and width.
    private func placeHead(_ placement: PatientBodyPlacement) {
        guard patientLoaded else { return }
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
