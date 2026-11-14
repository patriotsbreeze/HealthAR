import CoreGraphics
import RescueCore
import RescueVision
import SwiftUI
import UIKit

// MARK: - What the painter draws

/// Solid while the engine has the target, dashed while it's an estimate.
enum ARLock: Equatable {
    case locked, estimating
}

/// Text on a solid capsule. Laid out here, so the painter only draws, and the words are always given
/// verbatim: a step's own phrase, a pinned label, or a cue's reviewed callout.
/// The sternum ring, the heel of the rescuer's hand, and which way to slide it, in view points.
struct ARHandGuide: Equatable {
    var target: CGRect
    var hand: CGPoint?
    var text: String
    var onTarget: Bool
}

struct ARChip: Equatable {
    enum Tone: Equatable { case neutral, caution }

    var text: String
    var frame: CGRect
    var tone = Tone.neutral
    /// From the mark to the chip, when they sit far enough apart to need one.
    var leader: ARLeader?
}

struct ARLeader: Equatable {
    var from: CGPoint
    var to: CGPoint
}

struct ARPad: Equatable {
    var number: Int
    var center: CGPoint
    var size: CGSize
    var angle: Double
}

/// Where to act on the body. One at a time.
struct ARZone: Equatable {
    enum Shape: Equatable {
        /// Stacked ghost hands with the heel on the zone's center.
        case chest(center: CGPoint, axis: Double, halfLength: CGFloat, halfWidth: CGFloat, palmRadius: CGFloat, fingerAngle: Double)
        /// Both pads at once and numbered, since nothing says when the first one is on.
        case pads([ARPad])
        case limb(from: CGPoint, to: CGPoint, width: CGFloat)
        case press(center: CGPoint, radius: CGFloat)
    }

    var id: String
    var shape: Shape
    var lock: ARLock
    var chip: ARChip?

    var path: Path {
        switch shape {
        case let .chest(center, axis, halfLength, halfWidth, _, _):
            ARGeometry.ellipse(center: center, axis: axis, halfLength: halfLength, halfWidth: halfWidth)
        case let .pads(pads):
            pads.reduce(into: Path()) { $0.addPath(ARGeometry.pad(center: $1.center, size: $1.size, angle: $1.angle)) }
        case let .limb(from, to, width):
            ARGeometry.limb(from: from, to: to, width: width)
        case let .press(center, radius):
            ARGeometry.pressRing(center: center, radius: radius)
        }
    }

    var center: CGPoint {
        let box = path.boundingRect
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// What a chip mustn't cover, ghost hands included.
    var bounds: CGRect {
        guard case let .chest(center, _, _, _, palm, fingers) = shape else { return path.boundingRect }
        let hands = ARGeometry.ghostHands(heel: center, fingerAngle: fingers, palmRadius: palm)
        return path.boundingRect.union(hands.over.boundingRect).union(hands.under.boundingRect)
    }
}

/// Something in the room to grab: corner brackets and a chip. On a band too short to place the chip
/// without covering another mark, the brackets go up alone and the deck's bold word names it.
struct ARItem: Equatable {
    var id: String
    var frame: CGRect
    var lock: ARLock
    var chip: ARChip?
}

/// Whatever is wanted but out of the band, from the band's edge.
struct ARPointer: Equatable {
    enum Tone: Equatable {
        /// A body zone, in the target color.
        case target
        /// Something to grab, in white.
        case item
    }

    var center: CGPoint
    var angle: Double
    var tone: Tone
    /// Nil for a cued item's pointer whose words would land on another mark. The AED's always shows.
    var chip: ARChip?
}

/// A see-through body, in the overlay's own points.
struct ARFigure: Equatable {
    var segments: [VisionOverlay.Figure.Segment]
    var head: CGPoint
    var headRadius: CGFloat
    var hands: CGPoint?
}

/// The patient pose found, in the overlay's own points: each part with its own lock, drawn as one
/// see-through silhouette.
struct AROutline: Equatable {
    struct Part: Equatable {
        enum Kind: Equatable { case torso, head, limb }
        var kind: Kind
        var path: Path
        var lock: ARLock
    }

    var parts: [Part]

    var bounds: CGRect { parts.reduce(CGRect.null) { $0.union($1.path.boundingRect) } }
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

/// The ghost rescuer to follow in compressions, over the practice patient when one was placed.
struct ARGhost: Equatable {
    var rescuer: ARFigure
    var patient: ARFigure?
    /// 0 up to 1 pressed.
    var push: Double
    var limbWidth: CGFloat
}

/// One frame of marks, in the overlay's own points. At most one zone, two items, one pointer and one hint.
struct ARScene: Equatable {
    var band: CGRect
    var joints: [CGPoint] = []
    var bodies: [VisionOverlay.DetectedBody] = []
    var chestEstimateLabel: String?
    var sternumEstimate: CGRect?
    var handGuide: ARHandGuide?
    var patientIn3D = false
    var zone: ARZone?
    var items: [ARItem] = []
    var pointer: ARPointer?
    var hint: ARChip?
    /// Drawn under every other mark, and nothing is kept clear of it, since it is see-through.
    var ghost: ARGhost?
    /// The patient, under the zone. See-through like the ghost, so nothing is kept clear of it either.
    var outline: AROutline?
    /// The AR view draws realistic hands on the chest, so the zone draws without its flat ones.
    var handsIn3D = false
    /// Where nothing may be laid over: the beat and the guide card.
    var obstacles: [CGRect] = []
    /// The side each chip took, kept so a chip doesn't hop sides from frame to frame.
    var sides: [String: MarkPlacement.Side] = [:]

    var hasMarks: Bool { sternumEstimate != nil || handGuide != nil || !joints.isEmpty || zone != nil || !items.isEmpty || pointer != nil || ghost != nil || outline != nil }
    var markIDs: [String] { (outline == nil ? [] : [ARSceneBuilder.outlineID]) + (zone.map { [$0.id] } ?? []) + items.map(\.id) }
}

// MARK: - What the builder reads

/// A body zone from vision, in normalized view coordinates, mapped from `VisionOverlay.zones` by
/// `zoneInputs(from:cues:pinLabel:)`.
struct ARZoneInput: Equatable {
    enum Kind: Equatable {
        case chest
        case pad(Int)
        case limb
        case press
    }

    enum Shape: Equatable {
        /// Four corners in order, as vision gives the chest and the pads.
        case quad([CGPoint])
        /// The radius is a fraction of the view's width, as the ring's is.
        case capsule(from: CGPoint, to: CGPoint, radius: Double)
        case circle(center: CGPoint, radius: Double)
    }

    var kind: Kind
    var shape: Shape
    /// View radians, head to feet, or along the limb.
    var axis: Double
    var isLocked: Bool
    /// Verbatim, or nil for no billboard.
    var chip: String?
}

/// A material in the room, in normalized view coordinates, mapped from `VisionOverlay.items` by
/// `itemInputs(from:cues:)`, with the chip taken verbatim from the cue's reviewed callout.
struct ARItemInput: Equatable {
    var material: RescueCore.Material
    /// The item itself on screen, or a point inside the view's edge in its direction.
    var position: CGPoint
    /// Normalized view rect, on screen only.
    var box: CGRect?
    var isOnScreen: Bool
    /// Radians from the view's center toward the item, as `AEDArrow.angle`.
    var angle: Double
    /// Metres from the camera. Coarse.
    var distance: Double
    var chip: String
    var isLocked = true
}

/// The coordinator's side of a frame: what the step is, not what the camera sees.
struct ARContext: Equatable {
    enum Pulse: Equatable {
        case hidden
        /// A small dot top-trailing, when the ghost can't be the beat.
        case docked
    }

    var target: OverlayTarget?
    var pinLabel = ""
    var invitesInjuryTap = false
    var pinMessage: String?
    var carriedAED = false
    var pulse = Pulse.hidden
    /// A guide card sits in the band's bottom-leading corner.
    var guideInCorner = false
    /// The chest zone at the start of compressions, which has no target of its own.
    var handsGuide = false
    /// What to fix to match the ghost, held steady by `ARMemory`.
    var coachingCue: CompressionFeedback.Cue?
    /// Marks were up a moment ago and went away for longer than the grace.
    var trackingLost = false
    /// Inside the grace: what was last seen, drawn as an estimate.
    var estimating = false
    /// AR is running. Shed for heat or failed, marks going away isn't lost tracking.
    var cameraLive = true
}

// MARK: - Building a frame

enum ARSceneBuilder {
    static let holdSteady = "Hold the phone steady"
    static let tapHint = "Tap the injury on screen"
    static let chestPointer = "Chest"
    static let injuryPointer = "Injury"
    static let aedChip = "AED"
    static let padsCaption = "Pad zones, coarse. Manikin only."
    /// `aed_found` asks for it to be brought over, so where it was seen may be empty now.
    static let carriedAED = "AED seen earlier"
    static let outlineID = "outline.patient"

    /// Short enough to read mid-push. Never praise: a match only turns the ghost green.
    static func coachingText(_ cue: CompressionFeedback.Cue) -> String {
        switch cue {
        case .handsToCenter: "Hands on the center of the chest"
        case .lockElbows: "Lock your elbows"
        case .pushFaster: "Push faster"
        case .pushSlower: "Push slower"
        case .followBeat: "Push with the ghost"
        }
    }

    static func aedPointer(distance: Double) -> String { "AED · \(Int(distance.rounded())) m" }

    static let pointerSize = CGSize(width: DS.AR.pointerDisc, height: DS.AR.pointerDisc)
    static let guideCorner = CGSize(width: 96, height: 80)
    /// A band shorter than this, as on a small phone or at a large text size, has room for one item.
    static let shortBand: CGFloat = 160
    /// A zone clipped at the band's edge is pointed at only when less than this much of it shows.
    static let zoneShownToRead: CGFloat = 0.35

    /// From normalized view coordinates to points, with limbs sized by distance.
    static func ghost(_ ghost: VisionOverlay.Ghost, view: CGSize) -> ARGhost {
        let metre = CGFloat(ghost.pointsPerMetre)
        let width = min(DS.AR.Ghost.limbWidth.upperBound, max(DS.AR.Ghost.limbWidth.lowerBound, metre * DS.AR.Ghost.limbMetres))
        let head = max(width, metre * DS.AR.Ghost.headMetres)
        let point = { (p: CGPoint) in CGPoint(x: p.x * view.width, y: p.y * view.height) }
        let figure = { (figure: VisionOverlay.Figure) in
            ARFigure(
                segments: figure.segments.map { .init(from: point($0.from), to: point($0.to)) },
                head: point(figure.head),
                headRadius: head,
                hands: figure.hands.map(point)
            )
        }
        return ARGhost(rescuer: figure(ghost.rescuer), patient: ghost.patient.map(figure), push: ghost.push, limbWidth: width)
    }

    /// From normalized view coordinates to points. A limb or head too small to read is held to a minimum.
    /// Inside the lost-tracking grace every part draws as an estimate.
    static func outline(_ outline: VisionOverlay.Outline, view: CGSize, estimating: Bool) -> AROutline? {
        let lock = { (locked: Bool) in estimating || !locked ? ARLock.estimating : .locked }
        let point = { (p: CGPoint) in CGPoint(x: p.x * view.width, y: p.y * view.height) }
        var parts: [AROutline.Part] = []
        if outline.torso.count >= 3 {
            var torso = Path()
            torso.addLines(outline.torso.map(point))
            torso.closeSubpath()
            parts.append(.init(kind: .torso, path: torso, lock: lock(outline.torsoLocked)))
        }
        for limb in outline.limbs {
            let width = max(limb.width * view.width, DS.AR.Outline.minLimbWidth)
            parts.append(.init(kind: .limb, path: ARGeometry.segmentCapsule(from: point(limb.from), to: point(limb.to), width: width), lock: lock(limb.isLocked)))
        }
        if let head = outline.head {
            let r = max(head.radius * view.width, DS.AR.Outline.minHeadRadius)
            let c = point(head.center)
            parts.append(.init(kind: .head, path: Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), lock: lock(head.isLocked)))
        }
        return parts.isEmpty ? nil : AROutline(parts: parts)
    }

    /// Pure: the same overlay, context and band always give the same frame.
    static func build(
        overlay: VisionOverlay,
        zones: [ARZoneInput] = [],
        items: [ARItemInput] = [],
        context: ARContext,
        band: CGRect,
        view: CGSize,
        previousSides: [String: MarkPlacement.Side] = [:],
        measure: (String) -> CGSize = { ARText.chipSize($0, typeSize: .large) }
    ) -> ARScene {
        var scene = ARScene(band: band)
        // With no room in the band, nothing draws at all, rather than sit over the buttons.
        guard band.height >= DS.AR.leastBand, view.width > 0, view.height > 0 else { return scene }
        scene.obstacles = obstacles(context: context, band: band)
        var taken = scene.obstacles
        var pointers: [PointerSpec] = []
        // Where words that must show go, so they never land on the docked beat.
        let clearOfBeat = context.pulse == .docked
            ? band.divided(atDistance: DS.Pulse.docked + 2 * DS.Pulse.dockedInset, from: .maxXEdge).remainder
            : band

        if let hint = hintText(overlay: overlay, context: context) {
            let size = measure(hint.text)
            let center = MarkPlacement.clamp(CGPoint(x: clearOfBeat.midX, y: band.minY + 18), size: size, into: clearOfBeat)
            let chip = ARChip(text: hint.text, frame: CGRect(center: center, size: size), tone: hint.tone)
            scene.hint = chip
            taken.append(chip.frame)
        }
        guard !context.trackingLost else { return scene }
        scene.ghost = overlay.ghost.map { ghost($0, view: view) }
        scene.outline = overlay.outline.flatMap { outline($0, view: view, estimating: context.estimating) }
        scene.handsIn3D = overlay.handsIn3D
        let lock: (Bool) -> ARLock = { context.estimating || !$0 ? .estimating : .locked }

        // The zone: one, from vision's zones when it has them, else today's ring or pin.
        var zone = Self.zone(overlay: overlay, zones: zones, context: context, view: view, lock: lock)
        if let shown = zone {
            taken.append(shown.bounds)
            let visible = shown.bounds.intersection(band)
            let readable = !visible.isNull && visible.height >= zoneShownToRead * shown.bounds.height
            if !band.contains(shown.center), !readable {
                // Clipped at the band's edge, and a pointer says where the rest of it is. Not while
                // enough of it shows, or the pointer would sit on the very mark it points at.
                // The pads lie on the chest too, and a pulseless patient has no injury to point at.
                let label = shown.id == "zone.chest" || shown.id == "zone.pads" ? chestPointer : injuryPointer
                pointers.append(PointerSpec(
                    priority: 2, position: CGPoint(x: shown.center.x / view.width, y: shown.center.y / view.height), isOnScreen: true,
                    angle: 0, label: label, tone: .target
                ))
            }
        } else if let pin = overlay.injuryPin, !pin.isOnScreen {
            pointers.append(PointerSpec(priority: 2, position: pin.position, isOnScreen: false, angle: pin.angle, label: injuryPointer, tone: .target))
        }

        // Items: the AED from today's arrow first, then the cues' materials in their order.
        var wanted: [ARItemInput] = []
        if let arrow = overlay.aedArrow {
            wanted.append(ARItemInput(
                material: .aed, position: arrow.position, box: nil, isOnScreen: arrow.isOnScreen, angle: arrow.angle,
                distance: arrow.distance, chip: context.carriedAED ? carriedAED : aedChip
            ))
        }
        // Vision's AED would only draw the same one twice.
        wanted += items.filter { $0.material != .aed || overlay.aedArrow == nil }
        var shownItems: [(input: ARItemInput, frame: CGRect)] = []
        let itemBudget = band.height < shortBand ? 1 : DS.AR.maxItems
        for input in wanted {
            let point = CGPoint(x: input.position.x * view.width, y: input.position.y * view.height)
            if input.isOnScreen, band.contains(point) {
                guard shownItems.count < itemBudget else { continue }
                let frame = input.box.map {
                    CGRect(x: $0.minX * view.width, y: $0.minY * view.height, width: $0.width * view.width, height: $0.height * view.height)
                } ?? CGRect(center: point, size: DS.AR.itemNominal)
                shownItems.append((input, frame))
                taken.append(frame)
            } else {
                let label = input.material == .aed
                    ? (context.carriedAED ? carriedAED : aedPointer(distance: input.distance))
                    : input.chip
                pointers.append(PointerSpec(
                    priority: input.material == .aed ? 0 : 1, position: input.position, isOnScreen: input.isOnScreen,
                    angle: input.angle, label: label, tone: .item
                ))
            }
        }

        // One pointer: the AED, then the first cued item, then the zone. It's pinned to the band's
        // edge and has the least choice, so it goes before the chips that can move. On a short band
        // the edge can fall on an item in view, and only the AED's may sit on its brackets: another
        // gives way to the next one, or to none.
        let ranked = pointers.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
        for spec in ranked {
            let placed = pointer(spec, band: band, view: view, taken: taken, measure: measure)
            let disc = CGRect(center: placed.center, size: pointerSize)
            if spec.priority > 0, shownItems.contains(where: { $0.frame.intersects(disc) }) { continue }
            scene.pointer = placed
            taken += [disc] + (placed.chip.map { [$0.frame] } ?? [])
            break
        }

        if let shown = zone, band.contains(shown.center), let text = shown.chip?.text {
            // The pads' caption is a safety caveat, so it always shows, clear of the beat. Any other
            // zone's words give way rather than cover another mark.
            let caveat = shown.id == "zone.pads"
            let size = measure(text)
            let placed = MarkPlacement.chipCenter(
                item: shown.bounds.intersection(band), chip: size, free: caveat ? clearOfBeat : band, avoiding: taken,
                previous: previousSides[shown.id], order: [.below, .above, .right, .left]
            )
            if caveat || placed.covered == 0 {
                let chip = ARChip(text: text, frame: CGRect(center: placed.center, size: size))
                zone?.chip = chip
                scene.sides[shown.id] = placed.side
                taken.append(chip.frame)
            } else {
                zone?.chip = nil
            }
        } else {
            zone?.chip = nil
        }
        scene.zone = zone

        for (input, frame) in shownItems {
            let id = "item.\(input.material.rawValue)"
            let size = measure(input.chip)
            let placed = MarkPlacement.chipCenter(item: frame, chip: size, free: band, avoiding: taken, previous: previousSides[id])
            // Where every side covers the beat, the guide, or another mark, the brackets go up alone.
            guard placed.covered == 0 else {
                scene.items.append(ARItem(id: id, frame: frame, lock: lock(input.isLocked), chip: nil))
                continue
            }
            var chip = ARChip(text: input.chip, frame: CGRect(center: placed.center, size: size))
            chip.leader = leader(from: frame, to: chip.frame)
            scene.items.append(ARItem(id: id, frame: frame, lock: lock(input.isLocked), chip: chip))
            scene.sides[id] = placed.side
            taken += [chip.frame] + (chip.leader.map { [CGRect(from: $0.from, to: $0.to)] } ?? [])
        }
        return scene
    }

    private struct PointerSpec {
        var priority: Int
        var position: CGPoint
        var isOnScreen: Bool
        var angle: Double
        var label: String
        var tone: ARPointer.Tone
    }

    static func obstacles(context: ARContext, band: CGRect) -> [CGRect] {
        var rects: [CGRect] = []
        switch context.pulse {
        case .hidden: break
        case .docked:
            let side = DS.Pulse.docked
            rects.append(CGRect(x: band.maxX - DS.Pulse.dockedInset - side, y: band.minY + DS.Pulse.dockedInset, width: side, height: side))
        }
        if context.guideInCorner {
            rects.append(CGRect(
                x: band.minX + DS.Space.m, y: band.maxY - DS.Space.m - guideCorner.height,
                width: guideCorner.width, height: guideCorner.height
            ))
        }
        return rects
    }

    private static func hintText(overlay: VisionOverlay, context: ARContext) -> (text: String, tone: ARChip.Tone)? {
        if let message = context.pinMessage { return (message, .caution) }
        if context.trackingLost { return (holdSteady, .caution) }
        if let cue = context.coachingCue { return (coachingText(cue), .caution) }
        if overlay.showsInjuryHint, context.invitesInjuryTap { return (tapHint, .neutral) }
        return nil
    }

    private static func zone(
        overlay: VisionOverlay,
        zones: [ARZoneInput],
        context: ARContext,
        view: CGSize,
        lock: (Bool) -> ARLock
    ) -> ARZone? {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * view.width, y: p.y * view.height) }
        let pads = zones.compactMap { input -> ARPad? in
            guard case let .pad(number) = input.kind, case let .quad(corners) = input.shape,
                  let fit = ARGeometry.fit(quad: corners.map(point), axis: input.axis) else { return nil }
            return ARPad(number: number, center: fit.center, size: CGSize(width: fit.halfWidth * 2, height: fit.halfLength * 2), angle: input.axis - .pi / 2)
        }
        if !pads.isEmpty {
            let locked = zones.filter { if case .pad = $0.kind { true } else { false } }.allSatisfy(\.isLocked)
            // Pads drawn on a body still only belong on a manikin, so they say so unless the cue says more.
            let chip = zones.lazy.compactMap(\.chip).first ?? padsCaption
            return ARZone(id: "zone.pads", shape: .pads(pads.sorted { $0.number < $1.number }), lock: lock(locked), chip: ARChip(text: chip, frame: .zero))
        }
        if let input = zones.first(where: { if case .pad = $0.kind { false } else { true } }) {
            let chip = input.chip.map { ARChip(text: $0, frame: .zero) }
            switch (input.kind, input.shape) {
            case let (.chest, .quad(corners)):
                guard let fit = ARGeometry.fit(quad: corners.map(point), axis: input.axis) else { return nil }
                return ARZone(
                    id: "zone.chest",
                    shape: .chest(center: fit.center, axis: input.axis, halfLength: fit.halfLength, halfWidth: fit.halfWidth,
                                  palmRadius: max(fit.halfLength, fit.halfWidth) * 0.8, fingerAngle: ARGeometry.fingerAngle(torsoAxis: input.axis)),
                    lock: lock(input.isLocked), chip: chip
                )
            case let (_, .capsule(from, to, radius)):
                return ARZone(id: "zone.limb", shape: .limb(from: point(from), to: point(to), width: radius * view.width * 2), lock: lock(input.isLocked), chip: chip)
            case let (_, .circle(center, radius)):
                return ARZone(id: "zone.press", shape: .press(center: point(center), radius: radius * view.width), lock: lock(input.isLocked), chip: chip)
            case (_, .quad):
                return nil
            }
        }
        if let ring = overlay.ring {
            // The ring says nothing of the torso's direction yet, so the body lies across the screen.
            let palm = ring.radius * view.width
            return ARZone(
                id: "zone.chest",
                shape: .chest(center: point(ring.center), axis: 0, halfLength: palm * 1.25, halfWidth: palm * 0.95,
                              palmRadius: palm, fingerAngle: ARGeometry.fingerAngle(torsoAxis: 0)),
                lock: lock(true)
            )
        }
        if let pin = overlay.injuryPin, pin.isOnScreen {
            return ARZone(
                id: "zone.press", shape: .press(center: point(pin.position), radius: DS.AR.pressRingMinRadius),
                lock: lock(true), chip: ARChip(text: context.pinLabel, frame: .zero)
            )
        }
        return nil
    }

    private static func pointer(
        _ spec: PointerSpec,
        band: CGRect,
        view: CGSize,
        taken: [CGRect],
        measure: (String) -> CGSize
    ) -> ARPointer {
        // Off the screen's edge and the deck's seam, where it reads as part of neither.
        let room = band.insetBy(dx: min(DS.AR.pointerInset.width, band.width / 4), dy: min(DS.AR.pointerInset.height, band.height / 4))
        let mark = MarkPlacement.place(
            position: spec.position, isOnScreen: spec.isOnScreen, angle: spec.angle, view: view, free: room, size: pointerSize
        )
        let disc = CGRect(center: mark.center, size: pointerSize)
        let size = measure(spec.label)
        let placed = MarkPlacement.chipCenter(item: disc, chip: size, free: band, avoiding: taken, previous: nil, gap: DS.Space.s)
        // The AED's words always show. A cued item's or the body's give way rather than cover a mark.
        let chip = placed.covered == 0 || spec.priority == 0 ? ARChip(text: spec.label, frame: CGRect(center: placed.center, size: size)) : nil
        return ARPointer(center: mark.center, angle: mark.angle, tone: spec.tone, chip: chip)
    }

    /// Only for a chip the clamp pushed away from its item. One right beside its brackets needs no
    /// line, and a short one would only turn a bracket's corner into a tick. It runs from the middle
    /// of the item's side facing the chip, between the bracket arms, to the chip's own edge.
    static func leader(from item: CGRect, to chip: CGRect) -> ARLeader? {
        let dx = max(0, chip.minX - item.maxX, item.minX - chip.maxX)
        let dy = max(0, chip.minY - item.maxY, item.minY - chip.maxY)
        guard hypot(dx, dy) > DS.AR.chipGap + 4 else { return nil }
        let from = dx >= dy
            ? CGPoint(x: chip.midX > item.midX ? item.maxX : item.minX, y: item.midY)
            : CGPoint(x: item.midX, y: chip.midY > item.midY ? item.maxY : item.minY)
        return ARLeader(from: from, to: ARGeometry.nearestCapsulePoint(of: chip, to: from))
    }
}

/// Chip sizes from the same font the painter draws with, so the layout and the drawing agree.
enum ARText {
    static func chipSize(_ text: String, typeSize: DynamicTypeSize) -> CGSize {
        let font = UIFont.systemFont(ofSize: DS.Fonts.label.points(for: min(typeSize, DS.AR.typeCap)), weight: .semibold)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: 2000, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil
        )
        return CGSize(width: ceil(bounds.width) + DS.AR.chipPadding.width * 2, height: ceil(bounds.height) + DS.AR.chipPadding.height * 2)
    }
}

extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The box a segment sweeps, so a later chip keeps off an earlier leader.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: max(abs(b.x - a.x), 1), height: max(abs(b.y - a.y), 1))
    }
}
