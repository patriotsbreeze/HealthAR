import CoreGraphics
import RescueCore
import RescueVision

/// Vision's zones and items, chosen and worded by the step's cues. Pure, so the same overlay and cues
/// always give the same marks. The builder then keeps them to its budget and to the band.
extension ARSceneBuilder {
    /// One kind of body zone per step. The pads come as a pair. A limb cue wants the capsule along the
    /// limb nearest the pin, and an injury-site cue the ring where the hands press. A step with no body
    /// cue keeps today's mark, the ring at the pin. A limb pose couldn't find falls back to that ring.
    /// The capsule has no chip: the why row already says what it may be, and on a small phone the band
    /// needs its room for the materials' callouts.
    static func zoneInputs(from overlay: VisionOverlay, cues: [Cue], pinLabel: String) -> [ARZoneInput] {
        let pads = overlay.zones.compactMap { zone -> ARZoneInput? in
            guard case let .pad(number) = zone.kind, case let .polygon(corners) = zone.shape else { return nil }
            return ARZoneInput(kind: .pad(number), shape: .quad(corners), axis: zone.axis, isLocked: zone.isLocked)
        }
        if !pads.isEmpty { return pads }

        if let chest = overlay.zones.first(where: { $0.kind == .chest }), case let .polygon(corners) = chest.shape {
            return [ARZoneInput(kind: .chest, shape: .quad(corners), axis: chest.axis, isLocked: chest.isLocked)]
        }

        let bodies = Set(cues.compactMap(\.body))
        if bodies.contains(.injuredLimb),
           let limb = overlay.zones.first(where: { if case .limb = $0.kind { true } else { false } }),
           case let .capsule(a, b, width) = limb.shape {
            return [ARZoneInput(kind: .limb, shape: .capsule(from: a, to: b, radius: width / 2), axis: limb.axis, isLocked: limb.isLocked)]
        }
        if let ring = overlay.zones.first(where: { $0.kind == .pressRing }), case let .capsule(center, _, width) = ring.shape {
            return [ARZoneInput(kind: .press, shape: .circle(center: center, radius: width / 2), axis: 0, isLocked: ring.isLocked, chip: pinLabel)]
        }
        // Today's pin, which the builder draws as the ring when nothing above is here.
        return []
    }

    /// The step's materials vision has seen, in the cues' order, each with its cue's callout word for
    /// word. A material no cue gives a callout for has nothing to say, so it isn't drawn.
    static func itemInputs(from overlay: VisionOverlay, cues: [Cue]) -> [ARItemInput] {
        var seen = Set<RescueCore.Material>()
        var inputs: [ARItemInput] = []
        for cue in cues {
            guard let material = cue.material, let callout = cue.callout, seen.insert(material).inserted,
                  let item = overlay.items.first(where: { $0.material == material })
            else { continue }
            inputs.append(ARItemInput(
                material: material, position: item.position, box: item.box, isOnScreen: item.isOnScreen,
                angle: item.angle, distance: item.distance, chip: callout
            ))
        }
        return inputs
    }
}
