#if DEBUG
import Foundation
import RescueCore
import RescueVision
import Synchronization
import UIKit

/// Launch arguments for looking at the screens in the Simulator, which has no ARKit. None of this
/// ships: TestFlight archives are Release, with DEBUG off.
///
/// - `-StagedCamera`: a flat grey stands in for the camera, and each state gets scripted marks.
/// - `-StartState <id>`: walks there with real taps where it can, so the log and the counters are
///   what they'd be. Skips onboarding.
/// - `-StagedOffscreen`: puts the AED and the pin out of the band, to see the pointers.
/// - `-StagedLoss`: drops the marks 2 s into a step, to see the grace and "Hold the phone steady".
/// - `-FallbackCard`: shows the card the app falls back to with no protocol.
/// - `-StagedSheet dispatcher|sentinel|operatorPanel`, `-StagedStop`, `-StagedHUD`: opens that on top.
enum StagedLaunch {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var stagesCamera: Bool { arguments.contains("-StagedCamera") }
    static var showsFallback: Bool { arguments.contains("-FallbackCard") }
    static var offscreen: Bool { arguments.contains("-StagedOffscreen") }
    static var dropsTracking: Bool { arguments.contains("-StagedLoss") }
    static var skipsOnboarding: Bool { startState != nil || stagesCamera }
    static var showsStop: Bool { arguments.contains("-StagedStop") }
    static var showsHUD: Bool { arguments.contains("-StagedHUD") }

    static var startState: String? { value(after: "-StartState") }
    static var sheet: AppSheet? { value(after: "-StagedSheet").flatMap(AppSheet.init(rawValue:)) }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Human steps are tapped for real. The first timer on the way is skipped by the operator's walk,
    /// which marks the strip, as it does on stage.
    @MainActor static func applyStartState(to coordinator: AppCoordinator) {
        guard let target = startState, target != coordinator.state.stateID,
              let steps = OperatorForce.path(engine: coordinator.engine, from: coordinator.state.stateID, to: target)
        else { return }
        for step in steps {
            guard case let .human(action) = step else { break }
            coordinator.perform(action)
        }
        if coordinator.state.stateID != target { coordinator.force(stateID: target) }
    }
}

/// A camera that sees a scripted scene: every AR mark there is, in the Simulator. It fills the same
/// overlay fields VisionSession does, so the marks go through the real mapping to the screen.
final class StagedVision: VisionPort, @unchecked Sendable {
    private struct State {
        var target: OverlayTarget?
        var stateID = ""
        var enteredAt = Date()
        var pin: CGPoint?
        var wanted: Set<RescueCore.Material> = []
        var handsGuideUntil: Date?
    }

    private let state = Mutex(State())
    let uplinkFrames: AsyncStream<UplinkFrame>
    private let frames: AsyncStream<UplinkFrame>.Continuation

    init() {
        (uplinkFrames, frames) = AsyncStream.makeStream()
    }

    var isARSupported: Bool { true }
    var status: VisionStatus { .running }
    var aedStatus: AEDStatus { .located }
    var keypointAge: TimeInterval? { 0.05 }
    var lastNoTargetReason: NoTargetReason? { nil }
    func start() {}
    func stop() {}
    func beginFrameBurst() {}
    func requestLocate(_ materials: Set<RescueCore.Material>) {}
    func locateStatus(_ material: RescueCore.Material) -> AEDStatus { .located }
    func sightings(of material: RescueCore.Material) -> Int { 2 }

    func beginHandsGuide(seconds: TimeInterval) {
        state.withLock { state in
            guard state.target == nil else { return }
            state.handsGuideUntil = Date().addingTimeInterval(seconds)
        }
    }

    var showsHandsGuide: Bool { state.withLock { $0.handsGuideUntil.map { Date() < $0 } ?? false } }

    func apply(_ effect: RescueEffect) {
        state.withLock { state in
            switch effect {
            case let .overlay(target):
                // As VisionSession does: a new step says again what it wants, and ends the guide.
                state.target = target
                state.wanted = []
                state.handsGuideUntil = nil
            case let .cues(cues):
                state.wanted = Set(cues.compactMap(\.material))
            case let .sendStateBrief(brief) where brief.stateID != state.stateID:
                state.stateID = brief.stateID
                state.enteredAt = Date()
                state.pin = nil
            default:
                break
            }
        }
    }

    func placeInjuryPin(atViewPoint point: CGPoint) async -> InjuryPinResult {
        let size = await MainActor.run { Self.screenSize }
        guard size.width > 0, size.height > 0 else { return .notPlaced }
        state.withLock { $0.pin = CGPoint(x: point.x / size.width, y: point.y / size.height) }
        return .placed
    }

    @MainActor private static var screenSize: CGSize {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first ?? .zero
    }

    private var snapshot: State { state.withLock { $0 } }

    private var dropped: Bool {
        StagedLaunch.dropsTracking && Date().timeIntervalSince(snapshot.enteredAt) > 2
    }

    func overlay() -> VisionOverlay {
        let now = snapshot
        guard !dropped else { return .empty }
        let away = StagedLaunch.offscreen
        var overlay: VisionOverlay
        switch now.target {
        case .chestCenter:
            overlay = Self.hands
        case nil where now.handsGuideUntil.map { Date() < $0 } ?? false:
            overlay = Self.hands
        case .aedDevice:
            let awake = now.stateID.hasPrefix("chest_")
            overlay = VisionOverlay(aedArrow: away
                ? .init(position: CGPoint(x: 0.92, y: 0.3), isOnScreen: false, angle: 0.2, distance: 4)
                : .init(position: CGPoint(x: awake ? 0.66 : 0.3, y: awake ? 0.3 : 0.27), isOnScreen: true, angle: 0, distance: 3))
        case .injurySite:
            if now.stateID == "limb_start", now.pin == nil {
                overlay = VisionOverlay(showsInjuryHint: true)
            } else {
                let pin = now.pin ?? CGPoint(x: 0.42, y: away ? 0.8 : 0.3)
                overlay = VisionOverlay(injuryPin: .init(position: pin, isOnScreen: true, angle: .pi / 2))
                overlay.zones = [Self.limb(through: pin), Self.pressRing(at: pin)]
            }
        case .upperBack, .upperAbdomen:
            // Standing, facing the camera, head at the top.
            let isBack = now.target == .upperBack
            let center = CGPoint(x: 0.5, y: isBack ? 0.36 : 0.52)
            overlay = VisionOverlay(zones: [
                BodyZone(kind: isBack ? .upperBack : .upperAbdomen, shape: .polygon(Self.rect(center: center, half: CGSize(width: isBack ? 0.09 : 0.06, height: 0.04))), axis: .pi / 2, isLocked: true),
            ])
        case .padZones:
            // Lying across the screen, head to the left: the patient's right is toward the top.
            overlay = VisionOverlay(zones: [
                BodyZone(kind: .pad(1), shape: .polygon(Self.rect(center: CGPoint(x: 0.42, y: 0.24), half: CGSize(width: 0.09, height: 0.03))), axis: 0, isLocked: true),
                BodyZone(kind: .pad(2), shape: .polygon(Self.rect(center: CGPoint(x: 0.62, y: 0.35), half: CGSize(width: 0.09, height: 0.03))), axis: 0, isLocked: false),
            ])
            overlay.outline = Self.patient
        case nil:
            overlay = .empty
        }
        overlay.items = Self.items(for: now.stateID).filter { now.wanted.contains($0.material) }
        return overlay
    }

    /// The ring with the torso's zone, lying across the screen with the head to the left.
    private static var hands: VisionOverlay {
        let center = CGPoint(x: 0.5, y: 0.3)
        return VisionOverlay(
            ring: .init(center: center, radius: 0.09),
            zones: [BodyZone(kind: .chest, shape: .polygon(rect(center: center, half: CGSize(width: 0.13, height: 0.05))), axis: 0, isLocked: true)],
            outline: patient
        )
    }

    /// The staged patient as pose would outline them: across the screen, head to the left, the chest at
    /// the ring. The far ankle is only faintly seen, so that shin draws dashed.
    private static var patient: VisionOverlay.Outline {
        typealias Limb = VisionOverlay.Outline.Limb
        let shoulders = (top: CGPoint(x: 0.31, y: 0.235), bottom: CGPoint(x: 0.31, y: 0.365))
        let hips = (top: CGPoint(x: 0.64, y: 0.255), bottom: CGPoint(x: 0.64, y: 0.345))
        let elbows = (top: CGPoint(x: 0.47, y: 0.215), bottom: CGPoint(x: 0.47, y: 0.385))
        let wrists = (top: CGPoint(x: 0.62, y: 0.205), bottom: CGPoint(x: 0.62, y: 0.395))
        let knees = (top: CGPoint(x: 0.82, y: 0.265), bottom: CGPoint(x: 0.82, y: 0.335))
        let ankles = (top: CGPoint(x: 0.99, y: 0.27), bottom: CGPoint(x: 0.99, y: 0.33))
        return VisionOverlay.Outline(
            torso: [shoulders.top, shoulders.bottom, hips.bottom, hips.top],
            torsoLocked: true,
            head: .init(center: CGPoint(x: 0.2, y: 0.3), radius: 0.075, isLocked: true),
            limbs: [
                Limb(from: shoulders.top, to: elbows.top, width: 0.065, isLocked: true),
                Limb(from: shoulders.bottom, to: elbows.bottom, width: 0.065, isLocked: true),
                Limb(from: elbows.top, to: wrists.top, width: 0.055, isLocked: true),
                Limb(from: elbows.bottom, to: wrists.bottom, width: 0.055, isLocked: true),
                Limb(from: hips.top, to: knees.top, width: 0.09, isLocked: true),
                Limb(from: hips.bottom, to: knees.bottom, width: 0.09, isLocked: true),
                Limb(from: knees.top, to: ankles.top, width: 0.07, isLocked: false),
                Limb(from: knees.bottom, to: ankles.bottom, width: 0.07, isLocked: true),
            ]
        )
    }

    /// A forearm through the pin, as near-pin pose would give it.
    private static func limb(through pin: CGPoint) -> BodyZone {
        let a = CGPoint(x: pin.x - 0.22, y: pin.y + 0.01), b = CGPoint(x: pin.x + 0.08, y: pin.y - 0.03)
        return BodyZone(kind: .limb(.forearm), shape: .capsule(a: a, b: b, width: 0.09), axis: -0.13, isLocked: true)
    }

    private static func pressRing(at pin: CGPoint) -> BodyZone {
        BodyZone(kind: .pressRing, shape: .capsule(a: pin, b: pin, width: 0.14), axis: 0, isLocked: true)
    }

    /// Where each material sits in the staged room. Which ones show is the step's cues' choice.
    private static func items(for stateID: String) -> [ItemCallout] {
        switch stateID {
        case "limb_danger":
            return [
                ItemCallout(material: .towel, position: CGPoint(x: 0.22, y: 0.24), box: CGRect(x: 0.12, y: 0.21, width: 0.2, height: 0.06),
                            isOnScreen: true, angle: 0, distance: 1.2),
                ItemCallout(material: .gloves, position: CGPoint(x: 0.76, y: 0.26), box: CGRect(x: 0.69, y: 0.23, width: 0.14, height: 0.06),
                            isOnScreen: true, angle: 0, distance: 1),
            ]
        default:
            return [
                ItemCallout(material: .towel, position: CGPoint(x: 0.74, y: 0.22), box: CGRect(x: 0.64, y: 0.18, width: 0.2, height: 0.07),
                            isOnScreen: true, angle: 0, distance: 1.5),
                ItemCallout(material: .pillow, position: CGPoint(x: 0.97, y: 0.6), box: nil, isOnScreen: false, angle: 0.5, distance: 2),
                ItemCallout(material: .gloves, position: CGPoint(x: 0.76, y: 0.26), box: CGRect(x: 0.69, y: 0.23, width: 0.14, height: 0.06),
                            isOnScreen: true, angle: 0, distance: 1),
            ]
        }
    }

    private static func rect(center: CGPoint, half: CGSize) -> [CGPoint] {
        [
            CGPoint(x: center.x - half.width, y: center.y - half.height),
            CGPoint(x: center.x + half.width, y: center.y - half.height),
            CGPoint(x: center.x + half.width, y: center.y + half.height),
            CGPoint(x: center.x - half.width, y: center.y + half.height),
        ]
    }
}
#endif
