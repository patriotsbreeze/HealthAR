import ARKit
import RealityKit
import SwiftUI

/// What the guide walks to: an AED in a building the person confirmed, with a route from its entrance.
/// Only AEDs the phone file carries, which are ones seen in the scan or a demo prop the team placed.
struct AEDGuideTarget: Identifiable, Equatable {
    let building: BuildingBrief
    let aed: BuildingBrief.AED
    let route: BuildingBrief.Route
    /// From where a photo was matched, not from the entrance.
    let fromPhoto: Bool
    /// The survey spot the photo matched, for the "face this way" picture.
    let startPano: String?

    init?(building: BuildingBrief) {
        guard let aed = BuildingWording.guideTarget(building), let route = aed.routeFromEntrance else { return nil }
        self.init(building: building, aed: aed, route: route)
    }

    init(building: BuildingBrief, aed: BuildingBrief.AED, route: BuildingBrief.Route, fromPhoto: Bool = false, startPano: String? = nil) {
        self.building = building
        self.aed = aed
        self.route = route
        self.fromPhoto = fromPhoto
        self.startPano = startPano
    }

    /// The recorded view from the start spot looking along the way to go, when the drone pack has one.
    var startView: URL? {
        guard let startPano, let drone = DroneData.bundled, drone.building == building.id,
              let frame = drone.targets[aed.id]?.frames[startPano]
        else { return nil }
        return DroneData.imageURL(frame.img)
    }

    var id: String { "\(building.id)/\(aed.id)/\(fromPhoto ? "photo" : "entrance")" }
    /// "AED", or for one marked by hand, that.
    var name: String { BuildingWording.label(aed) }
    /// On the pin, where two short lines read better than one long one.
    var pinText: String {
        aed.markedByHand ? "AED marked\nby hand" : "AED"
    }
}

/// Every line the guide shows.
enum AEDGuideWording {
    static let here = "I'm here"
    static let recalibrate = "Re-calibrate"
    static let done = "Done"
    static let finding = "Finding where you are…"
    static let upright = "Hold the phone upright, facing into the building, and tap I'm here again."
    static let settling = "AR is still getting its bearings. Move the phone slowly, then tap I'm here again."
    static let noAR = "AR isn't available on this phone. Use the directions on the dispatcher sheet."
    static let noCamera = "Camera access is off for this app, so the guide can't draw. Use the directions on the dispatcher sheet."

    static let turnUntilUp = "Turn until the arrow points up"
    static let facing = "Facing the right way"
    static let anyway = "Calibrate anyway"
    static let noCompass = "No compass reading. Face down the route as best you can, then tap I'm here."
    static let startView = "This is the way to go from here"
    static let turnLeft = "Turn line left"
    static let turnRight = "Turn line right"
    static let lineUp = "If the line doesn't follow the hallway, turn it until it does."
    /// Each tap of the turn buttons swings the drawn route this far round where it starts.
    static let nudgeDegrees = 10.0

    static func calibrate(_ route: BuildingBrief.Route, fromPhoto: Bool = false) -> String {
        if fromPhoto {
            return "Stand where you took the photo, hold the phone upright, roughly facing the way the arrow shows, then tap I'm here."
        }
        let doorway = BuildingWording.clean(route.anchorText)
        let place = doorway.isEmpty ? "the entrance doorway" : "the entrance doorway (\(doorway))"
        return "Stand in \(place), face into the building, hold the phone upright, then tap I'm here."
    }

    /// The AED button's mode: the same ask, in fewer words.
    static func shortCalibrate(fromPhoto: Bool) -> String {
        fromPhoto ? "Stand where you took the photo, then tap I'm here." : "Stand in the entrance facing in, then tap I'm here."
    }

    static let shortNoAR = "AR isn't available on this phone."
    static let shortNoCamera = "Camera access is off for this app."

    static func remaining(_ progress: AEDPath.Progress?) -> String {
        guard let progress else { return finding }
        return "About \(Int(progress.remaining.rounded())) m to go"
    }

    static func next(_ progress: AEDPath.Progress?, name: String) -> String? {
        guard let progress else { return nil }
        if progress.remaining < 2 { return "The \(name) should be right here. Look around." }
        if let turn = progress.turn {
            let side = turn == .left ? "left" : "right"
            let metres = Int(progress.toTurn.rounded())
            return metres < 2 ? "Turn \(side) now" : "Turn \(side) in \(metres) m"
        }
        return "Straight on to the \(name)"
    }

    static func stairs(_ aed: BuildingBrief.AED) -> String {
        let floor = BuildingWording.clean(aed.floor)
        return floor.isEmpty ? "Take the stairs." : "Take the stairs to \(floor)."
    }

    static let markHere = "Mark the AED here"
    static let markHint = "Stand at a real AED, then tap. It's saved on this phone with the walk you took from the entrance."
    static let markTooShort = "Walk to the AED from the entrance first, then mark it."

    static func marked(metres: Int) -> String {
        "Marked: \(BuildingWording.marked), about \(metres) m from the entrance. The guide now counts it."
    }

    static var fixedStrings: [String] {
        [here, recalibrate, done, finding, upright, settling, noAR, noCamera, turnUntilUp, facing, anyway, noCompass,
         startView, turnLeft, turnRight, lineUp, markHere, markHint, markTooShort, shortNoAR, shortNoCamera,
         shortCalibrate(fromPhoto: true), shortCalibrate(fromPhoto: false)]
    }
}

/// The guide's state: calibrating at the door, then walking. It reads the camera; nothing it does
/// reaches the rescue's engine.
@MainActor
@Observable
final class AEDGuide {
    enum Stage: Equatable { case calibrate, guiding }

    /// Debug builds, `-ARGuidePreview`: no camera, a plain backdrop, and a pretend walk at this pace.
    nonisolated static var previewing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ARGuidePreview")
        #else
        false
        #endif
    }

    static let previewPace = 1.2

    let target: AEDGuideTarget
    let preview: Bool
    private(set) var stage = Stage.calibrate
    private(set) var problem: String?
    private(set) var frame: EntranceFrame?

    /// For the calibrate arrow, when the route says which way its first leg runs.
    let compass = CompassHeading()

    /// The walk since calibrating, in the route's frame, for marking an AED at its end.
    @ObservationIgnored private(set) var trail: [SIMD2<Double>] = []
    @ObservationIgnored private var recording: Task<Void, Never>?
    /// What the last mark said, for the HUD.
    private(set) var markMessage: String?

    @ObservationIgnored weak var arView: ARView?
    @ObservationIgnored private var calibratedAt = Date()
    @ObservationIgnored private var routeAnchor: AnchorEntity?

    init(target: AEDGuideTarget, preview: Bool = AEDGuide.previewing) {
        self.target = target
        self.preview = preview
    }

    /// The tap in the doorway. The origin is the camera over the floor, forward is where it looks, made level.
    func iAmHere() {
        if preview {
            calibrated(EntranceFrame(origin: .zero, forward: [0, 0, -1], right: [1, 0, 0]))
            return
        }
        guard let arView, let camera = arView.session.currentFrame?.camera else {
            problem = AEDGuideWording.settling
            return
        }
        switch camera.trackingState {
        case .notAvailable, .limited(.initializing), .limited(.relocalizing):
            problem = AEDGuideWording.settling
            return
        default:
            break
        }
        guard var frame = EntranceFrame.calibrate(camera: camera.transform, floorY: floorY(below: camera.transform, in: arView)) else {
            problem = AEDGuideWording.upright
            return
        }
        // The person needn't face the first leg exactly: the compass says how far off they are, and the
        // frame swings by that much. Works from any spot a photo placed them, not only the doorway.
        if let bearing = target.route.startBearingDeg, let heading = compass.degrees {
            frame = frame.rotated(clockwiseDegrees: Compass.rotation(bearing: bearing, heading: heading))
        }
        calibrated(frame)
        draw(frame, in: arView)
    }

    /// Swings the drawn route round its start, for when the compass was off and the line cuts through a wall.
    func nudge(clockwiseDegrees degrees: Double) {
        guard let frame else { return }
        let turned = frame.rotated(clockwiseDegrees: degrees)
        self.frame = turned
        if let arView, !preview { draw(turned, in: arView) }
    }

    /// Only from the entrance: a walk from a photo spot is in another frame.
    var canMark: Bool { !target.fromPhoto }

    /// Saves an AED where the phone is now, with the walk that got here as its route.
    func markHere(store: MarkedAEDStore = .shared) {
        guard canMark, let here = position(now: Date()) else { return }
        record(here)
        guard let mark = store.mark(building: target.building.id, walk: trail, anchorText: target.route.anchorText) else {
            markMessage = AEDGuideWording.markTooShort
            return
        }
        markMessage = AEDGuideWording.marked(metres: Int(mark.route.lengthM.rounded()))
    }

    /// Every half second while guiding, a point once the phone has moved a step from the last.
    private func startTrail() {
        recording?.cancel()
        trail = [.zero]
        recording = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.stage == .guiding, let here = self.position(now: Date()) else { continue }
                self.record(here)
            }
        }
    }

    private func record(_ point: SIMD2<Double>) {
        if let last = trail.last, simd_distance(last, point) < 0.5 { return }
        trail.append(point)
    }

    func stopTrail() {
        recording?.cancel()
        recording = nil
    }

    func recalibrate() {
        stopTrail()
        markMessage = nil
        routeAnchor?.removeFromParent()
        routeAnchor = nil
        frame = nil
        problem = nil
        stage = .calibrate
    }

    /// Reads, never writes, so the HUD can ask on every redraw.
    func progress(now: Date) -> AEDPath.Progress? {
        position(now: now).map { AEDPath.progress(at: $0, along: target.route.waypoints) }
    }

    /// The step the person is on, by the same position.
    func step(now: Date) -> BuildingBrief.Route.Step? {
        guard let position = position(now: now),
              let index = AEDPath.currentStep(at: position, along: target.route.waypoints, steps: target.route.steps)
        else { return nil }
        return target.route.steps[index]
    }

    /// Where the phone is, in the route's frame.
    private func position(now: Date) -> SIMD2<Double>? {
        guard let frame else { return nil }
        if preview {
            let walked = now.timeIntervalSince(calibratedAt) * Self.previewPace
            return AEDPath.point(at: walked, along: target.route.waypoints)
        }
        guard let arView else { return nil }
        return frame.local(arView.cameraTransform.translation)
    }

    /// The compass, or in a preview a heading that swings onto the bearing over a few seconds.
    func heading(now: Date) -> Double? {
        guard let bearing = target.route.startBearingDeg else { return nil }
        if preview {
            let swing = max(0, 60 - now.timeIntervalSince(openedAt) * 15)
            return Compass.normalized(bearing - swing)
        }
        return compass.degrees
    }

    @ObservationIgnored private let openedAt = Date()

    private func calibrated(_ frame: EntranceFrame) {
        self.frame = frame
        calibratedAt = Date()
        problem = nil
        stage = .guiding
        if canMark { startTrail() }
    }

    /// The lowest level plane between 0.6 and 2.2 m under the camera, so a desk isn't taken for the floor.
    private func floorY(below camera: simd_float4x4, in arView: ARView) -> Float? {
        let position = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let query = ARRaycastQuery(origin: position, direction: [0, -1, 0], allowing: .existingPlaneInfinite, alignment: .horizontal)
        return arView.session.raycast(query)
            .map { $0.worldTransform.columns.3.y }
            .filter { $0 < position.y - 0.6 && $0 > position.y - 2.2 }
            .min()
    }

    // MARK: - Drawing. Plain primitives, no assets.

    private func draw(_ frame: EntranceFrame, in arView: ARView) {
        routeAnchor?.removeFromParent()
        let anchor = AnchorEntity(world: .zero)
        let points = target.route.waypoints.map(frame.world)
        // White is "the item's pointer" in this app, and the AED is the item.
        let ribbon = UnlitMaterial(color: UIColor(hex: DS.Hex.item, alpha: 0.4))
        let arrow = UnlitMaterial(color: UIColor(hex: DS.Hex.item))
        for (start, end) in zip(points, points.dropFirst()) {
            let length = simd_distance(start, end)
            guard length > 0.05 else { continue }
            let direction = (end - start) / length
            // Turns an entity's -Z onto the leg.
            let heading = simd_quatf(angle: atan2(-direction.x, -direction.z), axis: [0, 1, 0])
            let strip = ModelEntity(mesh: .generateBox(size: [0.1, 0.004, length]), materials: [ribbon])
            strip.position = (start + end) / 2 + [0, 0.005, 0]
            strip.orientation = heading
            anchor.addChild(strip)
            // An arrow every metre, pointing along the leg.
            var along: Float = 1
            while along < length - 0.3 {
                let chevron = Self.chevron(arrow)
                chevron.position = start + direction * along + [0, 0.012, 0]
                chevron.orientation = heading
                anchor.addChild(chevron)
                along += 1
            }
        }
        if let end = points.last { anchor.addChild(Self.pin(at: end, text: target.pinText)) }
        arView.scene.addAnchor(anchor)
        routeAnchor = anchor
    }

    /// A flat ^ on the floor, its point toward -Z.
    private static func chevron(_ material: UnlitMaterial) -> Entity {
        let chevron = Entity()
        let arm = MeshResource.generateBox(size: [0.05, 0.006, 0.32])
        for angle: Float in [.pi / 5, -.pi / 5] {
            let part = ModelEntity(mesh: arm, materials: [material])
            part.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            // Each arm's front end at the tip, 0.12 m ahead of the arrow's centre.
            part.position = SIMD3<Float>(0, 0, -0.12) + SIMD3(sin(angle), 0, cos(angle)) * 0.16
            chevron.addChild(part)
        }
        return chevron
    }

    /// A tall green pin, a ring on the floor round it, and its name over the top, always facing you.
    /// Green as on AED signs.
    private static func pin(at base: SIMD3<Float>, text: String) -> Entity {
        let pin = Entity()
        pin.position = base
        let green = UnlitMaterial(color: UIColor(hex: DS.Hex.ok))
        let pole = ModelEntity(mesh: .generateCylinder(height: 1.7, radius: 0.025), materials: [green])
        pole.position = [0, 0.85, 0]
        let head = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [green])
        head.position = [0, 1.8, 0]
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.35), materials: [UnlitMaterial(color: UIColor(hex: DS.Hex.ok, alpha: 0.35))])
        ring.position = [0, 0.006, 0]

        let label = Entity()
        label.position = [0, 2.15, 0]
        label.components.set(BillboardComponent())
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.004,
            font: .systemFont(ofSize: 0.14, weight: .bold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let words = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(hex: DS.Hex.textPrimary))])
        words.position = -mesh.bounds.center
        let extents = mesh.bounds.extents
        let plate = ModelEntity(
            mesh: .generatePlane(width: extents.x + 0.12, height: extents.y + 0.08, cornerRadius: 0.04),
            materials: [UnlitMaterial(color: UIColor(hex: DS.Hex.surface, alpha: 0.85))]
        )
        plate.position = [0, 0, -0.01]
        label.addChild(plate)
        label.addChild(words)

        for part in [pole, head, ring, label] { pin.addChild(part) }
        return pin
    }
}

/// Full screen over the dispatcher sheet: the camera with the way drawn on the floor, or in a Debug
/// preview a plain backdrop. The simulation strip stays on top, as on every screen.
struct AEDGuideView: View {
    let target: AEDGuideTarget
    let coordinator: AppCoordinator
    /// Opened from the AED button: no turn-the-line buttons, and fewer words.
    let aedMode: Bool
    @State private var guide: AEDGuide
    @Environment(\.dismiss) private var dismiss

    init(target: AEDGuideTarget, coordinator: AppCoordinator, aedMode: Bool = false) {
        self.target = target
        self.coordinator = coordinator
        self.aedMode = aedMode
        _guide = State(initialValue: AEDGuide(target: target))
    }

    private var arAvailable: Bool { ARWorldTrackingConfiguration.isSupported }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: DS.Space.l)
                panel
            }
        }
        .background(DS.Colors.canvas)
        // The phone has one camera and one AR session at a time. The rescue's AR stops while the guide is
        // up and starts again, with a fresh world, when it closes, so its marks are lost. Fine for the
        // demo; a guide used mid-rescue would want the two to share a session.
        .onAppear {
            if coordinator.showsCamera { coordinator.vision.stop() }
            if target.route.startBearingDeg != nil { guide.compass.start() }
        }
        .onDisappear {
            guide.stopTrail()
            guide.compass.stop()
            if coordinator.showsCamera { coordinator.vision.start() }
        }
    }

    @ViewBuilder private var backdrop: some View {
        if guide.preview || !arAvailable || !Permissions.cameraGranted {
            LinearGradient(colors: [DS.Glass.backdropTop, DS.Glass.backdropBottom], startPoint: .top, endPoint: .bottom)
        } else {
            GuideARView(guide: guide)
        }
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            StatusDot(text: target.fromPhoto ? "Guide · from your photo" : "Guide · from the entrance", color: DS.Colors.ok)
            if let blocked {
                Text(blocked).dsFont(DS.Fonts.prompt)
                doneButton(kind: .primary)
            } else {
                switch guide.stage {
                case .calibrate: calibrate
                case .guiding: GuideHUD(guide: guide, aedMode: aedMode, done: { dismiss() })
                }
            }
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .buildingDeck()
    }

    /// Why there's nothing to draw on. Never a prompt: a camera prompt is onboarding's alone.
    private var blocked: String? {
        if guide.preview { return nil }
        if !arAvailable { return aedMode ? AEDGuideWording.shortNoAR : AEDGuideWording.noAR }
        if !Permissions.cameraGranted { return aedMode ? AEDGuideWording.shortNoCamera : AEDGuideWording.noCamera }
        return nil
    }

    @ViewBuilder private var calibrate: some View {
        Text(aedMode ? AEDGuideWording.shortCalibrate(fromPhoto: target.fromPhoto) : AEDGuideWording.calibrate(target.route, fromPhoto: target.fromPhoto))
            .dsFont(DS.Fonts.detail)
            .fixedSize(horizontal: false, vertical: true)
        if let url = target.startView, let image = UIImage(contentsOfFile: url.path) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row / 2, style: .continuous))
                    .accessibilityHidden(true)
                if !aedMode {
                    Text(AEDGuideWording.startView)
                        .dsFont(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        if let problem = guide.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .dsFont(DS.Fonts.label)
                .foregroundStyle(DS.Colors.caution)
        }
        if let bearing = target.route.startBearingDeg {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let heading = guide.heading(now: context.date)
                let facing = heading.map { Compass.isFacing(bearing: bearing, heading: $0) } ?? false
                CompassArrow(rotation: heading.map { Compass.rotation(bearing: bearing, heading: $0) }, facing: facing)
                // Never held back: the compass corrects for however far off the person is facing.
                Button(AEDGuideWording.here, action: guide.iAmHere)
                    .buttonStyle(DeckCapsuleButtonStyle(prominent: true))
                    .accessibilityHint("Sets where the way is drawn from. Face roughly along the arrow first.")
            }
        } else {
            Button(AEDGuideWording.here, action: guide.iAmHere)
                .buttonStyle(DeckCapsuleButtonStyle(prominent: true))
                .accessibilityHint("Sets where the way is drawn from. Stand in the doorway facing in first.")
        }
        doneButton(kind: .quiet)
    }

    private func doneButton(kind: CommandButtonStyle.Kind) -> some View {
        Button(AEDGuideWording.done) { dismiss() }
            .buttonStyle(DeckCapsuleButtonStyle(prominent: kind == .primary))
    }
}

/// Metres to go, the next turn, the stairs when the route changes floor, and near or far advice.
private struct GuideHUD: View {
    let guide: AEDGuide
    /// No near-or-far advice and no mark button; the turn-the-line buttons stay.
    var aedMode = false
    let done: () -> Void

    var body: some View {
        let target = guide.target
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let progress = guide.progress(now: context.date)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let step = guide.step(now: context.date) {
                    Text(step.text)
                        .dsFont(DS.Fonts.prompt)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(AEDGuideWording.remaining(progress))
                        .dsFont(DS.Fonts.confirm)
                        .monospacedDigit()
                    if let next = AEDGuideWording.next(progress, name: target.name) {
                        Text(next).dsFont(DS.Fonts.detail)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                if target.route.floorChange {
                    Label(AEDGuideWording.stairs(target.aed), systemImage: "figure.stairs")
                        .dsFont(DS.Fonts.prompt)
                }
                if !aedMode, let reach = target.aed.reach {
                    Text(BuildingWording.advice(reach))
                        .dsFont(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = guide.markMessage {
                    Label(message, systemImage: "mappin.and.ellipse")
                        .dsFont(DS.Fonts.label)
                        .foregroundStyle(DS.Colors.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The AED button's mode already knows its AED, so marking one is the dispatcher side's job.
                if guide.canMark, !aedMode {
                    Button(AEDGuideWording.markHere) { guide.markHere() }
                        .buttonStyle(DeckCapsuleButtonStyle())
                        .accessibilityHint(AEDGuideWording.markHint)
                }
                if !aedMode {
                    Text(AEDGuideWording.lineUp)
                        .dsFont(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DS.Space.betweenButtons) {
                    Button(AEDGuideWording.turnLeft, systemImage: "arrow.counterclockwise") {
                        guide.nudge(clockwiseDegrees: -AEDGuideWording.nudgeDegrees)
                    }
                    .buttonStyle(DeckCapsuleButtonStyle())
                    Button(AEDGuideWording.turnRight, systemImage: "arrow.clockwise") {
                        guide.nudge(clockwiseDegrees: AEDGuideWording.nudgeDegrees)
                    }
                    .buttonStyle(DeckCapsuleButtonStyle())
                }
                HStack(spacing: DS.Space.betweenButtons) {
                    Button(AEDGuideWording.recalibrate, action: guide.recalibrate)
                        .buttonStyle(DeckCapsuleButtonStyle())
                    Button(AEDGuideWording.done, action: done)
                        .buttonStyle(DeckCapsuleButtonStyle(prominent: true))
                }
                .padding(.top, DS.Space.xs)
            }
        }
    }
}

/// Its own session: world tracking, gravity-aligned, finding level planes for the floor.
private struct GuideARView: UIViewRepresentable {
    let guide: AEDGuide

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        guide.arView = view
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: ()) {
        view.session.pause()
    }
}

/// Points the way to face: up when the phone already faces along the first leg. Green once it's
/// close enough. With no reading it says so instead of pointing anywhere.
private struct CompassArrow: View {
    let rotation: Double?
    let facing: Bool

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if let rotation {
                Image(systemName: "arrow.up")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(facing ? DS.Colors.ok : DS.Colors.textPrimary)
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 140, height: 140)
                    .accessibilityHidden(true)
                Text(facing ? AEDGuideWording.facing : AEDGuideWording.turnUntilUp)
                    .dsFont(DS.Fonts.prompt)
                    .foregroundStyle(facing ? DS.Colors.ok : DS.Colors.textPrimary)
                    .accessibilityLabel(facing ? AEDGuideWording.facing : Self.spoken(rotation))
            } else {
                Text(AEDGuideWording.noCompass)
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// VoiceOver can't see the arrow, so it hears which way to turn.
    static func spoken(_ rotation: Double) -> String {
        let degrees = Int(abs(rotation).rounded())
        return rotation > 0 ? "Turn right about \(degrees) degrees" : "Turn left about \(degrees) degrees"
    }
}
