import RescueCore
import RescueVision
import SwiftUI

extension AppCoordinator {
    /// What the step says about the marks, as opposed to what the camera sees.
    var arContext: ARContext {
        ARContext(
            target: overlayTarget,
            pinLabel: pinLabel,
            invitesInjuryTap: invitesInjuryTap,
            pinMessage: pinMessage?.text,
            carriedAED: mayShowCarriedAED,
            pulse: showsBeatPulse ? .docked : .hidden,
            guideInCorner: definition?.guide != nil,
            handsGuide: showsHandsGuide,
            cameraLive: cameraLive
        )
    }

    /// The beat only ever sits in the band's top-trailing corner, so the body and the AR on it stay clear.
    var pulseDocked: Bool { showsBeatPulse }

    /// The pads are drawn on the body where they can be seen, so the diagram can go. Only when the
    /// overlay last drew both inside the band: pads imaged under the deck are cut away and only pointed
    /// at, and "where the pictures show" needs a picture. A pose dropout shorter than `padsGuideHold`
    /// doesn't bring the diagram back.
    var arDrawsPads: Bool {
        guard showsCamera, overlayTarget == .padZones, let at = padsInBandAt else { return false }
        return clock() - at < Self.padsGuideHold
    }

    /// Each frame the overlay draws, so the diagram follows what is on screen, in the overlay's own
    /// points, and not a second guess at where vision's zones land.
    func noteDrawn(_ scene: ARScene) {
        guard case let .pads(pads)? = scene.zone?.shape, !pads.isEmpty,
              pads.allSatisfy({ scene.band.contains($0.center) })
        else { return }
        padsInBandAt = clock()
    }

    /// Nothing to draw on a step with no target, unless the carried AED, the hands guide, or the ghost on the beat is up.
    var overlayIdle: Bool { overlayTarget == nil && !mayShowCarriedAED && !showsHandsGuide && !metronomeOn }
}

/// The zone, the items, a pointer and a hint, redrawn from vision each display frame in one Canvas.
/// It sits above the panels, takes no touches, and is hidden from VoiceOver, since the step's own
/// words already say all of it.
struct OverlayLayer: View {
    let coordinator: AppCoordinator
    /// The band, in global points. Every mark stays inside it.
    let band: CGRect
    @State private var memory = ARMemory()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // AR shed for heat, or failed, has nothing to draw, and a phone shedding load shouldn't
            // redraw at display rate.
            TimelineView(.animation(paused: coordinator.overlayIdle || !coordinator.cameraLive)) { timeline in
                let built = scene(at: timeline.date.timeIntervalSinceReferenceDate, in: geometry)
                let style = ARPainter.Style(typeSize: typeSize, reduceMotion: reduceMotion)
                Canvas { context, _ in
                    ARPainter.paint(built.scene, appear: built.appear, style: style, in: &context)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func scene(at now: TimeInterval, in geometry: GeometryProxy) -> (scene: ARScene, appear: [String: Double]) {
        let origin = geometry.frame(in: .global).origin
        let seen = coordinator.vision.overlay()
        let cues = coordinator.cues
        let frame = memory.frame(
            overlay: seen,
            zones: ARSceneBuilder.zoneInputs(from: seen, cues: cues, pinLabel: coordinator.pinLabel),
            items: ARSceneBuilder.itemInputs(from: seen, cues: cues),
            stateID: coordinator.state.stateID,
            context: coordinator.arContext,
            now: now
        )
        var context = frame.context
        context.coachingCue = memory.heldCue(coordinator.vision.compressionFeedback()?.cue, now: now)
        let scene = ARSceneBuilder.build(
            overlay: frame.overlay,
            zones: frame.zones,
            items: frame.items,
            context: context,
            band: band.offsetBy(dx: -origin.x, dy: -origin.y),
            view: geometry.size,
            previousSides: memory.sides,
            measure: { [typeSize] in ARText.chipSize($0, typeSize: typeSize) }
        )
        coordinator.noteDrawn(scene)
        return (scene, memory.noteBuilt(scene, now: now))
    }
}

/// What the overlay keeps between frames: when each mark first showed, the side each chip took, and
/// the last marks seen, for a short grace when tracking drops. It doesn't smooth anything; vision
/// does that once, on the joints.
@MainActor
final class ARMemory {
    struct Frame {
        var overlay: VisionOverlay
        var zones: [ARZoneInput]
        var items: [ARItemInput]
        var context: ARContext
    }

    private var stateID: String?
    private var firstSeen: [String: TimeInterval] = [:]
    private(set) var sides: [String: MarkPlacement.Side] = [:]
    private var last: (overlay: VisionOverlay, zones: [ARZoneInput], items: [ARItemInput], at: TimeInterval)?
    private var cueCandidate: (cue: CompressionFeedback.Cue?, since: TimeInterval)?
    private var shownCue: CompressionFeedback.Cue?

    /// A correction shows once it has held this long, and goes once its absence has, so a jittery
    /// frame neither flashes one up nor blinks one away.
    static let cueHold: TimeInterval = 0.8

    func heldCue(_ cue: CompressionFeedback.Cue?, now: TimeInterval) -> CompressionFeedback.Cue? {
        if cueCandidate?.cue != cue { cueCandidate = (cue, now) }
        if let candidate = cueCandidate, now - candidate.since >= Self.cueHold { shownCue = candidate.cue }
        return shownCue
    }

    /// Marks that were up a moment ago and are gone: within the grace the last ones draw dashed, and
    /// after it they hide and the band says to hold steady. Only where a mark going away means the
    /// tracking did: vision keeps the AED's point and the pin up while tracking holds.
    func frame(
        overlay: VisionOverlay,
        zones: [ARZoneInput],
        items: [ARItemInput],
        stateID: String,
        context: ARContext,
        now: TimeInterval
    ) -> Frame {
        if stateID != self.stateID { reset(stateID) }
        var context = context
        let hasMarks = overlay.ring != nil || overlay.aedArrow != nil || overlay.injuryPin != nil || overlay.outline != nil
            || !zones.isEmpty || !items.isEmpty
        // A pin that timed out brings the tap hint back. That's not a loss, so there's nothing to hold.
        if overlay.showsInjuryHint { last = nil }
        if hasMarks {
            last = (overlay, zones, items, now)
            return Frame(overlay: overlay, zones: zones, items: items, context: context)
        }
        // Every target holds its marks for the whole step now, the chest and pads included, so marks that
        // go mean the camera lost what it was on. The hands guide running out isn't one: the coordinator
        // clears it within a tick, inside the grace. Nor is AR stopping for heat or a failure: the camera
        // is off, and holding the phone steady wouldn't bring anything back.
        let lossMeansTracking = context.cameraLive && (context.target != nil || context.carriedAED || context.handsGuide)
        guard lossMeansTracking, let last else { return Frame(overlay: overlay, zones: zones, items: items, context: context) }
        if now - last.at < DS.Motion.lostGrace {
            context.estimating = true
            return Frame(overlay: last.overlay, zones: last.zones, items: last.items, context: context)
        }
        context.trackingLost = true
        return Frame(overlay: overlay, zones: zones, items: items, context: context)
    }

    /// How far into its first-lock entrance each mark is, from 0 to 1.
    func noteBuilt(_ scene: ARScene, now: TimeInterval) -> [String: Double] {
        sides.merge(scene.sides) { _, new in new }
        var appear: [String: Double] = [:]
        for id in scene.markIDs {
            let first = firstSeen[id] ?? now
            firstSeen[id] = first
            appear[id] = min(1, (now - first) / DS.Motion.lockIn)
        }
        return appear
    }

    private func reset(_ stateID: String) {
        self.stateID = stateID
        firstSeen = [:]
        sides = [:]
        last = nil
        cueCandidate = nil
        shownCue = nil
    }
}
