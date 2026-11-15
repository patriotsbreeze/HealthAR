import CoreGraphics
import Foundation
@testable import HealthAISim
import RescueCore
import RescueVision
import SwiftUI
import Testing

private let view = CGSize(width: 400, height: 800)
private let band = CGRect(x: 0, y: 100, width: 400, height: 300)

/// A fixed size per character, so the layout doesn't depend on the font on this machine.
private func measure(_ text: String) -> CGSize {
    CGSize(width: CGFloat(text.count) * 8 + 20, height: 30)
}

private func build(
    _ overlay: VisionOverlay = .empty,
    zones: [ARZoneInput] = [],
    items: [ARItemInput] = [],
    context: ARContext = ARContext(),
    band: CGRect = band,
    previousSides: [String: MarkPlacement.Side] = [:]
) -> ARScene {
    ARSceneBuilder.build(
        overlay: overlay, zones: zones, items: items, context: context, band: band, view: view,
        previousSides: previousSides, measure: measure
    )
}

private func item(_ material: RescueCore.Material, at position: CGPoint, onScreen: Bool = true, chip: String) -> ARItemInput {
    ARItemInput(material: material, position: position, box: nil, isOnScreen: onScreen, angle: 0, distance: 2, chip: chip)
}

/// Every chip, disc and bracket the painter would draw, so a test can check nothing leaves the band.
private func drawnRects(_ scene: ARScene) -> [CGRect] {
    var rects: [CGRect] = []
    if let chip = scene.zone?.chip { rects.append(chip.frame) }
    for case let chip? in scene.items.map(\.chip) { rects.append(chip.frame) }
    if let pointer = scene.pointer {
        if let chip = pointer.chip { rects.append(chip.frame) }
        rects.append(CGRect(center: pointer.center, size: ARSceneBuilder.pointerSize))
    }
    if let hint = scene.hint { rects.append(hint.frame) }
    return rects
}

/// Grows `rect` by the clamp's 4 pt margin, which lets a chip sit that close to the band's side.
private func inside(_ rect: CGRect, _ band: CGRect) -> Bool {
    band.insetBy(dx: -0.5, dy: -0.5).contains(rect)
}

@MainActor
@Suite struct ARSceneBuilderTests {
    // MARK: - Today's overlay

    @Test func theRingBecomesGhostHandsOnTheChest() throws {
        let scene = build(VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.07)), context: ARContext(target: .chestCenter))
        let zone = try #require(scene.zone)
        guard case let .chest(center, _, _, _, palm, fingers) = zone.shape else {
            Issue.record("not a chest zone: \(zone.shape)")
            return
        }
        #expect(center == CGPoint(x: 200, y: 240))
        #expect(abs(palm - 28) < 1e-9)
        #expect(abs(fingers + .pi / 2) < 1e-9, "fingers point away from whoever holds the phone, up the screen")
        #expect(zone.lock == .locked)
        #expect(zone.chip == nil, "the deck says where, in the same color")
        #expect(scene.pointer == nil)
    }

    @Test func aChestBehindTheDeckIsCutAndPointedAt() throws {
        let scene = build(VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.75), radius: 0.07)), context: ARContext(target: .chestCenter))
        #expect(scene.zone != nil, "drawn, and clipped at the band's edge")
        let pointer = try #require(scene.pointer)
        #expect(pointer.chip?.text == "Chest")
        #expect(pointer.tone == .target)
        #expect(band.contains(pointer.center))
        #expect(abs(pointer.angle - .pi / 2) < 0.01, "pointing down, toward it")
    }

    /// The pads lie on the chest, so pads under the deck are pointed at as the chest, never an injury.
    @Test func padsBehindTheDeckArePointedAtAsTheChest() throws {
        func quad(_ c: CGPoint) -> [CGPoint] {
            [CGPoint(x: c.x - 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y + 0.03), CGPoint(x: c.x - 0.09, y: c.y + 0.03)]
        }
        let zones = [
            ARZoneInput(kind: .pad(1), shape: .quad(quad(CGPoint(x: 0.42, y: 0.66))), axis: 0, isLocked: true),
            ARZoneInput(kind: .pad(2), shape: .quad(quad(CGPoint(x: 0.62, y: 0.78))), axis: 0, isLocked: true),
        ]
        let scene = build(zones: zones, context: ARContext(target: .padZones))
        #expect(scene.zone?.id == "zone.pads")
        let pointer = try #require(scene.pointer)
        #expect(pointer.chip?.text == "Chest")
        #expect(pointer.tone == .target)
        #expect(band.contains(pointer.center))
    }

    @Test func anAEDOnScreenIsBracketedAndNamed() throws {
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.3, y: 0.25), isOnScreen: true, angle: 0, distance: 3)
        let scene = build(VisionOverlay(aedArrow: arrow), context: ARContext(target: .aedDevice))
        let aed = try #require(scene.items.first)
        let chip = try #require(aed.chip)
        #expect(chip.text == "AED")
        #expect(aed.frame.midX == 120 && aed.frame.midY == 200)
        #expect(!chip.frame.intersects(aed.frame), "the chip doesn't cover what it names")
        #expect(scene.pointer == nil)
    }

    @Test func anAEDOffScreenGetsAPointerWithItsDistance() throws {
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.92, y: 0.3), isOnScreen: false, angle: 0.2, distance: 3.4)
        let scene = build(VisionOverlay(aedArrow: arrow), context: ARContext(target: .aedDevice))
        #expect(scene.items.isEmpty)
        let pointer = try #require(scene.pointer)
        #expect(pointer.chip?.text == "AED · 3 m")
        #expect(pointer.tone == .item)
        #expect(pointer.angle == 0.2, "vision's direction, since the AED is off the view")
    }

    /// `aed_found` asks for it to be brought over, so where it was seen may be empty now.
    @Test func aCarriedAEDSaysItWasSeenEarlier() throws {
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.92, y: 0.3), isOnScreen: false, angle: 0, distance: 3)
        let away = build(VisionOverlay(aedArrow: arrow), context: ARContext(carriedAED: true, pulse: .docked))
        #expect(away.pointer?.chip?.text == "AED seen earlier")
        let near = VisionOverlay.AEDArrow(position: CGPoint(x: 0.1, y: 0.2), isOnScreen: true, angle: 0, distance: 3)
        #expect(build(VisionOverlay(aedArrow: near), context: ARContext(carriedAED: true)).items.first?.chip?.text == "AED seen earlier")
    }

    /// The beat's dot sits top-trailing, and an AED up and to the right puts the pointer right by it.
    @Test func aPointersWordsKeepOffTheBeat() throws {
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.95, y: 0.08), isOnScreen: false, angle: -.pi / 4, distance: 3)
        let scene = build(VisionOverlay(aedArrow: arrow), context: ARContext(carriedAED: true, pulse: .docked))
        let pointer = try #require(scene.pointer)
        let beat = try #require(scene.obstacles.first)
        #expect(!(try #require(pointer.chip)).frame.intersects(beat), "the AED's words always show")
    }

    @Test func thePinIsAPressRingWithItsPinnedWords() throws {
        let pin = VisionOverlay.InjuryPin(position: CGPoint(x: 0.4, y: 0.3), isOnScreen: true, angle: 0)
        for label in ["Possible break. Keep as found", "Possible break"] {
            let scene = build(VisionOverlay(injuryPin: pin), context: ARContext(target: .injurySite, pinLabel: label, invitesInjuryTap: true))
            let zone = try #require(scene.zone)
            #expect(zone.shape == .press(center: CGPoint(x: 160, y: 240), radius: DS.AR.pressRingMinRadius))
            #expect(zone.chip?.text == label)
        }
    }

    @Test func aPinBelowTheBandIsPointedAtAsInjury() throws {
        let pin = VisionOverlay.InjuryPin(position: CGPoint(x: 0.4, y: 0.8), isOnScreen: true, angle: .pi / 2)
        let scene = build(VisionOverlay(injuryPin: pin), context: ARContext(target: .injurySite, pinLabel: "Possible break"))
        #expect(scene.pointer?.chip?.text == "Injury")
        #expect(scene.zone?.chip == nil)
    }

    @Test func theHintsKeepTheirWords() {
        let hint = VisionOverlay(showsInjuryHint: true)
        #expect(build(hint, context: ARContext(target: .injurySite, invitesInjuryTap: true)).hint?.text == "Tap the injury on screen")
        #expect(build(hint, context: ARContext(target: .injurySite, invitesInjuryTap: false)).hint == nil, "nothing asks for a tap where hands are on the wound")
        let failed = build(hint, context: ARContext(target: .injurySite, invitesInjuryTap: true, pinMessage: "Couldn't place the pin. Tap again."))
        #expect(failed.hint?.text == "Couldn't place the pin. Tap again.")
        #expect(failed.hint?.tone == .caution)
    }

    @Test func lostTrackingHidesTheMarksAndSaysNothing() {
        let pin = VisionOverlay.InjuryPin(position: CGPoint(x: 0.4, y: 0.3), isOnScreen: true, angle: 0)
        let scene = build(VisionOverlay(injuryPin: pin), context: ARContext(target: .injurySite, trackingLost: true))
        #expect(!scene.hasMarks)
        #expect(scene.hint == nil)
        let grace = build(VisionOverlay(injuryPin: pin), context: ARContext(target: .injurySite, estimating: true))
        #expect(grace.zone?.lock == .estimating, "dashed while it's only what was last seen")
    }

    /// A band this short has nowhere to put a mark but on the buttons.
    @Test func noRoomInTheBandMeansNothingDraws() {
        let thin = CGRect(x: 0, y: 300, width: 400, height: 35)
        let scene = build(VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.4), radius: 0.07), showsInjuryHint: true), band: thin)
        #expect(!scene.hasMarks)
        #expect(scene.hint == nil)
    }

    // MARK: - The budget

    @Test func neverMoreThanOneZoneTwoItemsAndOnePointer() {
        let materials: [RescueCore.Material] = [.towel, .pillow, .gloves, .towel, .pillow]
        let many = materials.enumerated().map { index, material in
            item(material, at: CGPoint(x: 0.1 + 0.15 * Double(index), y: 0.2 + 0.03 * Double(index)), chip: "Pad under · \(material.rawValue)")
        }
        let off = [item(.gloves, at: CGPoint(x: 0.95, y: 0.6), onScreen: false, chip: "Put on · Gloves"), item(.towel, at: CGPoint(x: 0.05, y: 0.6), onScreen: false, chip: "Press · Cloth")]
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.92, y: 0.3), isOnScreen: false, angle: 0, distance: 3)
        let zones = [ARZoneInput(kind: .limb, shape: .capsule(from: CGPoint(x: 0.2, y: 0.3), to: CGPoint(x: 0.5, y: 0.3), radius: 0.04), axis: 0, isLocked: true)]
        let scene = build(VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.07), aedArrow: arrow), zones: zones, items: many + off)
        #expect(scene.zone != nil)
        #expect(scene.items.count == DS.AR.maxItems)
        #expect(scene.pointer?.chip?.text == "AED · 3 m", "the AED comes first")
        for rect in drawnRects(scene) { #expect(inside(rect, band), "\(rect)") }
    }

    /// The pointer sits at the band's edge with the least choice, so it's placed first, and its chip
    /// never lands on an item someone is meant to see.
    @Test func thePointersChipKeepsOffTheItems() throws {
        let towel = ARItemInput(
            material: .towel, position: CGPoint(x: 0.74, y: 0.22), box: CGRect(x: 0.64, y: 0.18, width: 0.2, height: 0.07),
            isOnScreen: true, angle: 0, distance: 1.5, chip: "Pad under · Towel"
        )
        let pillow = item(.pillow, at: CGPoint(x: 0.97, y: 0.6), onScreen: false, chip: "Pad under · Pillow")
        let limb = ARZoneInput(kind: .limb, shape: .capsule(from: CGPoint(x: 0.2, y: 0.31), to: CGPoint(x: 0.5, y: 0.27), radius: 0.045), axis: 0, isLocked: true)
        let scene = build(zones: [limb], items: [towel, pillow], context: ARContext(target: .injurySite, guideInCorner: true))
        let pointer = try #require(scene.pointer)
        let item = try #require(scene.items.first)
        let pointerChip = try #require(pointer.chip)
        let itemChip = try #require(item.chip)
        #expect(!pointerChip.frame.intersects(item.frame))
        #expect(!pointerChip.frame.intersects(itemChip.frame))
        #expect(!itemChip.frame.intersects(CGRect(center: pointer.center, size: ARSceneBuilder.pointerSize)))
    }

    /// On a short band, a small phone's or at a large text size, one item, and no chip laid over
    /// another mark, the beat or the guide: its brackets go up alone.
    @Test func aShortBandKeepsOneItemAndNoChipOnAnotherMark() throws {
        let short = CGRect(x: 0, y: 100, width: 375, height: 120)
        let towel = ARItemInput(
            material: .towel, position: CGPoint(x: 0.6, y: 0.2), box: CGRect(x: 0.5, y: 0.14, width: 0.2, height: 0.1),
            isOnScreen: true, angle: 0, distance: 1.5, chip: "Pad under · Towel"
        )
        let pillow = item(.pillow, at: CGPoint(x: 0.2, y: 0.2), chip: "Pad under · Pillow")
        let scene = build(items: [towel, pillow], context: ARContext(target: .injurySite, guideInCorner: true), band: short)
        #expect(scene.items.map(\.id) == ["item.towel"], "the first cue's item, and only that one")

        // A chip with nowhere clear to go is left out, and its brackets stay.
        let crowded = CGRect(x: 0, y: 100, width: 200, height: 60)
        let wide = ARItemInput(
            material: .towel, position: CGPoint(x: 0.25, y: 0.16), box: CGRect(x: 0.05, y: 0.13, width: 0.4, height: 0.065),
            isOnScreen: true, angle: 0, distance: 1.5, chip: "Pad under · Towel"
        )
        let squeezed = build(items: [wide], context: ARContext(pulse: .docked), band: crowded)
        let only = try #require(squeezed.items.first)
        #expect(only.chip == nil)
        for rect in drawnRects(squeezed) {
            #expect(squeezed.obstacles.allSatisfy { !$0.intersects(rect) }, "\(rect)")
        }
    }

    /// The band's edge can fall on an item in view. A cued item's pointer never sits on its brackets.
    @Test func aPointerNeverSitsOnAnItemInView() throws {
        let short = CGRect(x: 0, y: 100, width: 400, height: 140)
        let towel = ARItemInput(
            material: .towel, position: CGPoint(x: 0.84, y: 0.24), box: CGRect(x: 0.72, y: 0.19, width: 0.24, height: 0.1),
            isOnScreen: true, angle: 0, distance: 1.5, chip: "Pad under · Towel"
        )
        let pillow = item(.pillow, at: CGPoint(x: 0.97, y: 0.6), onScreen: false, chip: "Pad under · Pillow")
        let scene = build(items: [towel, pillow], context: ARContext(target: .injurySite), band: short)
        #expect(scene.items.map(\.id) == ["item.towel"])
        #expect(scene.pointer == nil, "the pillow's arrow would land on the towel's brackets")

        // With room beside the towel, the pillow keeps its pointer.
        let tall = build(items: [towel, pillow], context: ARContext(target: .injurySite))
        let pointer = try #require(tall.pointer)
        let bracket = try #require(tall.items.first).frame
        #expect(!CGRect(center: pointer.center, size: ARSceneBuilder.pointerSize).intersects(bracket))
    }

    /// The pads' caption is a safety caveat, so it always shows, and never on the docked beat.
    @Test func thePadsCaptionKeepsOffTheDockedBeat() throws {
        func quad(_ c: CGPoint) -> [CGPoint] {
            [CGPoint(x: c.x - 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y + 0.03), CGPoint(x: c.x - 0.09, y: c.y + 0.03)]
        }
        let short = CGRect(x: 0, y: 100, width: 375, height: 130)
        let zones = [
            ARZoneInput(kind: .pad(1), shape: .quad(quad(CGPoint(x: 0.45, y: 0.17))), axis: 0, isLocked: true),
            ARZoneInput(kind: .pad(2), shape: .quad(quad(CGPoint(x: 0.62, y: 0.24))), axis: 0, isLocked: false),
        ]
        let scene = build(zones: zones, context: ARContext(target: .padZones, pulse: .docked), band: short)
        let caption = try #require(scene.zone?.chip)
        #expect(caption.text == ARSceneBuilder.padsCaption)
        let beat = try #require(scene.obstacles.first)
        #expect(!caption.frame.intersects(beat))
    }

    /// A chip right beside its brackets needs no line, which would only turn a corner into a tick.
    /// One the band's edge pushed away gets a line from the middle of the side facing it.
    @Test func aLeaderOnlyForAChipPushedAway() throws {
        let item = CGRect(x: 100, y: 200, width: 80, height: 60)
        #expect(ARSceneBuilder.leader(from: item, to: CGRect(x: 192, y: 215, width: 120, height: 30)) == nil)
        #expect(ARSceneBuilder.leader(from: item, to: CGRect(x: 120, y: 272, width: 120, height: 30)) == nil)

        let far = CGRect(x: 240, y: 300, width: 120, height: 30)
        let leader = try #require(ARSceneBuilder.leader(from: item, to: far))
        #expect(leader.from == CGPoint(x: 180, y: 230), "the middle of the right side, between the bracket arms")
        #expect(abs(hypot(leader.to.x - 255, leader.to.y - 315) - 15) < 1e-9, "on the chip's rounded end, not its frame's corner")
        let below = try #require(ARSceneBuilder.leader(from: item, to: CGRect(x: 90, y: 320, width: 120, height: 30)))
        #expect(below.from == CGPoint(x: 140, y: 260))
    }

    /// A chest whose middle is under the deck but whose hands still show isn't pointed at: the pointer
    /// would sit on the very mark it points to.
    @Test func aZoneThatStillShowsIsNotPointedAt() {
        let shown = build(VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.51), radius: 0.07)), context: ARContext(target: .chestCenter))
        #expect(shown.zone != nil)
        #expect(shown.pointer == nil)
    }

    /// The pointer keeps in from the screen's edge and off the deck's seam.
    @Test func aPointerSitsInFromTheBandsEdges() throws {
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.99, y: 0.9), isOnScreen: false, angle: 0.8, distance: 3)
        let pointer = try #require(build(VisionOverlay(aedArrow: arrow), context: ARContext(target: .aedDevice)).pointer)
        let disc = CGRect(center: pointer.center, size: ARSceneBuilder.pointerSize)
        #expect(band.maxX - disc.maxX >= DS.AR.pointerInset.width - 0.5)
        #expect(band.maxY - disc.maxY >= DS.AR.pointerInset.height - 0.5)
    }

    @Test func visionsAEDNeverDrawsTwice() {
        let arrow = VisionOverlay.AEDArrow(position: CGPoint(x: 0.3, y: 0.25), isOnScreen: true, angle: 0, distance: 3)
        let scene = build(VisionOverlay(aedArrow: arrow), items: [item(.aed, at: CGPoint(x: 0.31, y: 0.25), chip: "AED")])
        #expect(scene.items.count == 1)
    }

    // MARK: - Phase 2's inputs

    @Test func padsDrawTogetherAndNumbered() throws {
        func quad(_ c: CGPoint) -> [CGPoint] {
            [CGPoint(x: c.x - 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y - 0.03), CGPoint(x: c.x + 0.09, y: c.y + 0.03), CGPoint(x: c.x - 0.09, y: c.y + 0.03)]
        }
        let zones = [
            ARZoneInput(kind: .pad(2), shape: .quad(quad(CGPoint(x: 0.6, y: 0.35))), axis: 0, isLocked: true),
            ARZoneInput(kind: .pad(1), shape: .quad(quad(CGPoint(x: 0.4, y: 0.25))), axis: 0, isLocked: false),
        ]
        let zone = try #require(build(zones: zones, context: ARContext(target: .padZones)).zone)
        guard case let .pads(pads) = zone.shape else {
            Issue.record("not pads")
            return
        }
        #expect(pads.map(\.number) == [1, 2])
        #expect(zone.chip?.text == "Pad zones, coarse. Manikin only.", "on a body or not, manikin only")
        #expect(zone.lock == .estimating, "one pad is only an estimate, so both draw dashed")
    }

    @Test func aCueChipIsDrawnWordForWord() throws {
        let scene = build(items: [item(.towel, at: CGPoint(x: 0.6, y: 0.25), chip: "Pad under · Towel")])
        #expect(scene.items.first?.chip?.text == "Pad under · Towel")
        let away = build(items: [item(.pillow, at: CGPoint(x: 0.97, y: 0.6), onScreen: false, chip: "Pad under · Pillow")])
        #expect(away.pointer?.chip?.text == "Pad under · Pillow")
        #expect(away.pointer?.tone == .item)
    }

    @Test func aChipKeepsItsSideWhileItCan() throws {
        let towel = [item(.towel, at: CGPoint(x: 0.5, y: 0.25), chip: "Towel")]
        let first = build(items: towel)
        let side = try #require(first.sides["item.towel"])
        let other: MarkPlacement.Side = side == .left ? .below : .left
        let next = build(items: towel, previousSides: ["item.towel": other])
        #expect(next.sides["item.towel"] == other, "a clear side it had last frame stays")
    }

    // MARK: - Memory

    @Test func aMarkThatGoesAwayIsHeldThenLost() {
        let memory = ARMemory()
        let pin = VisionOverlay(injuryPin: .init(position: CGPoint(x: 0.4, y: 0.3), isOnScreen: true, angle: 0))
        let context = ARContext(target: .injurySite)
        #expect(!memory.frame(overlay: pin, zones: [], items: [], stateID: "limb_flags", context: context, now: 10).context.estimating)
        let grace = memory.frame(overlay: .empty, zones: [], items: [], stateID: "limb_flags", context: context, now: 10.3)
        #expect(grace.context.estimating)
        #expect(grace.overlay == pin)
        let lost = memory.frame(overlay: .empty, zones: [], items: [], stateID: "limb_flags", context: context, now: 10.6)
        #expect(lost.context.trackingLost)
        #expect(!memory.frame(overlay: .empty, zones: [], items: [], stateID: "limb_splint", context: context, now: 10.7).context.trackingLost, "a new step starts clean")
    }

    @Test func aTimedOutPinIsNoLoss() {
        let memory = ARMemory()
        let context = ARContext(target: .injurySite)
        _ = memory.frame(overlay: VisionOverlay(injuryPin: .init(position: CGPoint(x: 0.4, y: 0.3), isOnScreen: true, angle: 0)), zones: [], items: [], stateID: "limb_flags", context: context, now: 10)
        let after = memory.frame(overlay: VisionOverlay(showsInjuryHint: true), zones: [], items: [], stateID: "limb_flags", context: context, now: 11)
        #expect(!after.context.trackingLost)
        #expect(!after.context.estimating)
    }

    /// The ring holds for the whole step now, so a chest that goes is the camera losing it.
    @Test func aLostChestIsHeldThenSaysHoldSteady() {
        let memory = ARMemory()
        let ring = VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.07))
        let context = ARContext(target: .chestCenter)
        _ = memory.frame(overlay: ring, zones: [], items: [], stateID: "place_hands", context: context, now: 10)
        #expect(memory.frame(overlay: .empty, zones: [], items: [], stateID: "place_hands", context: context, now: 10.3).context.estimating)
        let lost = memory.frame(overlay: .empty, zones: [], items: [], stateID: "place_hands", context: context, now: 11)
        #expect(lost.context.trackingLost)
        #expect(build(lost.overlay, context: lost.context).hint == nil)
    }

    /// AR shed for heat, or failed, takes the marks away with the camera. Holding the phone steady
    /// wouldn't bring them back, so the band doesn't say to.
    @Test func aCameraThatStoppedIsNoTrackingLoss() {
        let memory = ARMemory()
        let ring = VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.07))
        _ = memory.frame(overlay: ring, zones: [], items: [], stateID: "pads", context: ARContext(target: .padZones), now: 10)
        let shed = ARContext(target: .padZones, cameraLive: false)
        let after = memory.frame(overlay: .empty, zones: [], items: [], stateID: "pads", context: shed, now: 12)
        #expect(!after.context.trackingLost)
        #expect(!after.context.estimating)
        #expect(build(after.overlay, context: after.context).hint == nil)
    }

    /// The window at the start of compressions ends by design. The coordinator clears it inside the grace.
    @Test func theHandsGuideRunningOutIsNoLoss() {
        let memory = ARMemory()
        let ring = VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.07))
        _ = memory.frame(overlay: ring, zones: [], items: [], stateID: "compressions", context: ARContext(handsGuide: true), now: 10)
        let after = memory.frame(overlay: .empty, zones: [], items: [], stateID: "compressions", context: ARContext(), now: 11)
        #expect(!after.context.trackingLost)
        #expect(!after.context.estimating)
    }

    @Test func aFirstLockEasesInOnce() {
        let memory = ARMemory()
        let scene = build(VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.07)))
        #expect(memory.noteBuilt(scene, now: 5)["zone.chest"] == 0)
        #expect(memory.noteBuilt(scene, now: 5.14)["zone.chest"].map { abs($0 - 0.5) < 1e-9 } == true)
        #expect(memory.noteBuilt(scene, now: 9)["zone.chest"] == 1)
    }
}

/// Vision's zones and items, as the step's cues choose and word them.
@MainActor
@Suite struct ARInputsTests {
    private let pin = CGPoint(x: 0.42, y: 0.3)
    private let support = [
        Cue(phrase: "limb_support", material: .towel, body: .injuredLimb, placement: .under, callout: "Pad under · Towel"),
        Cue(phrase: "limb_support", material: .pillow, body: .injuredLimb, placement: .under, callout: "Pad under · Pillow"),
    ]
    private let danger = [
        Cue(phrase: "limb_danger_care", material: .towel, body: .injurySite, placement: .on, callout: "Press · Cloth"),
        Cue(phrase: "limb_gloves", material: .gloves, callout: "Put on · Gloves"),
    ]

    private var limbOverlay: VisionOverlay {
        var overlay = VisionOverlay(injuryPin: .init(position: pin, isOnScreen: true, angle: 0))
        overlay.zones = [
            BodyZone(kind: .limb(.forearm), shape: .capsule(a: CGPoint(x: 0.2, y: 0.31), b: CGPoint(x: 0.5, y: 0.27), width: 0.09), axis: -0.13, isLocked: true),
            BodyZone(kind: .pressRing, shape: .capsule(a: pin, b: pin, width: 0.14), axis: 0, isLocked: true),
        ]
        overlay.items = [
            ItemCallout(material: .pillow, position: CGPoint(x: 0.97, y: 0.6), box: nil, isOnScreen: false, angle: 0.5, distance: 2),
            ItemCallout(material: .towel, position: CGPoint(x: 0.74, y: 0.22), box: CGRect(x: 0.64, y: 0.18, width: 0.2, height: 0.07),
                        isOnScreen: true, angle: 0, distance: 1.5),
        ]
        return overlay
    }

    @Test func aLimbCueDrawsTheCapsuleAndLeavesTheBandToTheCallouts() throws {
        let zones = ARSceneBuilder.zoneInputs(from: limbOverlay, cues: support, pinLabel: "Possible break. Keep as found")
        let zone = try #require(zones.first)
        #expect(zones.count == 1)
        #expect(zone.kind == .limb)
        #expect(zone.shape == .capsule(from: CGPoint(x: 0.2, y: 0.31), to: CGPoint(x: 0.5, y: 0.27), radius: 0.045))
        #expect(zone.chip == nil, "the why row says what it may be")
        let scene = build(limbOverlay, zones: zones)
        #expect(scene.zone?.id == "zone.limb")
        #expect(scene.zone?.chip == nil)
    }

    @Test func anInjurySiteCueDrawsTheRingWhereTheHandsPress() throws {
        let zones = ARSceneBuilder.zoneInputs(from: limbOverlay, cues: danger, pinLabel: "Possible break")
        let zone = try #require(zones.first)
        #expect(zone.kind == .press)
        #expect(zone.shape == .circle(center: pin, radius: 0.07))
        #expect(build(limbOverlay, zones: zones).zone?.chip?.text == "Possible break")
    }

    @Test func noBodyCueKeepsTheRingAtThePin() {
        #expect(ARSceneBuilder.zoneInputs(from: limbOverlay, cues: [], pinLabel: "Possible break").map(\.kind) == [.press])
        var noRing = limbOverlay
        noRing.zones = []
        #expect(ARSceneBuilder.zoneInputs(from: noRing, cues: support, pinLabel: "Possible break").isEmpty)
        #expect(build(noRing).zone?.id == "zone.press", "the builder still draws today's pin")
    }

    @Test func aLimbPoseDidntFindFallsBackToTheRing() {
        var overlay = limbOverlay
        overlay.zones.removeFirst()
        #expect(ARSceneBuilder.zoneInputs(from: overlay, cues: support, pinLabel: "Possible break").map(\.kind) == [.press])
    }

    @Test func theChestAndPadsComeAsVisionGivesThem() {
        let quad = [CGPoint(x: 0.4, y: 0.25), CGPoint(x: 0.6, y: 0.25), CGPoint(x: 0.6, y: 0.35), CGPoint(x: 0.4, y: 0.35)]
        let chest = VisionOverlay(ring: .init(center: CGPoint(x: 0.5, y: 0.3), radius: 0.09), zones: [BodyZone(kind: .chest, shape: .polygon(quad), axis: 0.1, isLocked: false)])
        #expect(ARSceneBuilder.zoneInputs(from: chest, cues: [], pinLabel: "") == [ARZoneInput(kind: .chest, shape: .quad(quad), axis: 0.1, isLocked: false)])
        #expect(build(chest, zones: ARSceneBuilder.zoneInputs(from: chest, cues: [], pinLabel: "")).zone?.lock == .estimating)

        let pads = VisionOverlay(zones: [
            BodyZone(kind: .pad(1), shape: .polygon(quad), axis: 0, isLocked: true),
            BodyZone(kind: .pad(2), shape: .polygon(quad.map { CGPoint(x: $0.x + 0.1, y: $0.y + 0.1) }), axis: 0, isLocked: true),
        ])
        #expect(ARSceneBuilder.zoneInputs(from: pads, cues: [], pinLabel: "").map(\.kind) == [.pad(1), .pad(2)])
    }

    @Test func itemsTakeTheirCuesCalloutWordForWordInTheCuesOrder() {
        let items = ARSceneBuilder.itemInputs(from: limbOverlay, cues: support)
        #expect(items.map(\.material) == [.towel, .pillow])
        #expect(items.map(\.chip) == ["Pad under · Towel", "Pad under · Pillow"])
        #expect(items[0].box == CGRect(x: 0.64, y: 0.18, width: 0.2, height: 0.07))

        let scene = build(limbOverlay, items: items)
        #expect(scene.items.map(\.chip?.text) == ["Pad under · Towel"])
        #expect(scene.pointer?.chip?.text == "Pad under · Pillow", "off screen, it's pointed at")
    }

    @Test func aMaterialNoCueWordsIsNotDrawn() {
        #expect(ARSceneBuilder.itemInputs(from: limbOverlay, cues: []).isEmpty)
        let unworded = [Cue(phrase: "limb_support", material: .towel)]
        #expect(ARSceneBuilder.itemInputs(from: limbOverlay, cues: unworded).isEmpty)
        #expect(ARSceneBuilder.itemInputs(from: limbOverlay, cues: danger).map(\.chip) == ["Press · Cloth"], "gloves weren't seen")
    }
}

@Suite struct CalloutLayoutTests {
    private let free = CGRect(x: 0, y: 100, width: 400, height: 300)
    private let chip = CGSize(width: 120, height: 30)

    @Test func aChipGoesBesideItsItemAndStaysInTheBand() {
        let item = CGRect(x: 100, y: 200, width: 60, height: 60)
        let placed = MarkPlacement.chipCenter(item: item, chip: chip, free: free, avoiding: [], previous: nil)
        let rect = CGRect(center: placed.center, size: chip)
        #expect(placed.side == .right)
        #expect(!rect.intersects(item))
        #expect(free.contains(rect))
    }

    @Test func nearTheEdgeItTakesTheOtherSide() {
        let item = CGRect(x: 320, y: 200, width: 60, height: 60)
        let placed = MarkPlacement.chipCenter(item: item, chip: chip, free: free, avoiding: [], previous: nil)
        #expect(placed.side == .left)
        #expect(!CGRect(center: placed.center, size: chip).intersects(item))
    }

    @Test func itKeepsOffAnotherChipAndTheBeat() {
        let item = CGRect(x: 100, y: 200, width: 60, height: 60)
        let taken = [CGRect(x: 160, y: 190, width: 200, height: 80), CGRect(x: 0, y: 190, width: 100, height: 80)]
        let placed = MarkPlacement.chipCenter(item: item, chip: chip, free: free, avoiding: taken, previous: nil)
        let rect = CGRect(center: placed.center, size: chip)
        #expect(taken.allSatisfy { !$0.intersects(rect) })
        #expect([MarkPlacement.Side.below, .above].contains(placed.side))
    }

    @Test func aClearSideFromLastFrameStays() {
        let item = CGRect(x: 100, y: 200, width: 60, height: 60)
        #expect(MarkPlacement.chipCenter(item: item, chip: chip, free: free, avoiding: [], previous: .below).side == .below)
        let blocked = [CGRect(x: 60, y: 260, width: 160, height: 60)]
        #expect(MarkPlacement.chipCenter(item: item, chip: chip, free: free, avoiding: blocked, previous: .below).side == .right, "it moves when something arrives")
    }

    @Test func withNoBandItFallsWhereItFalls() {
        let item = CGRect(x: 380, y: 20, width: 60, height: 60)
        let placed = MarkPlacement.chipCenter(item: item, chip: chip, free: nil, avoiding: [], previous: nil)
        #expect(placed.center == CGPoint(x: 440 + 12 + 60, y: 50))
    }

    /// Two chips' leaders don't cross: the second treats the first's as something to keep off.
    @Test func leadersDontCross() throws {
        let items = [
            ARItemInput(material: .towel, position: CGPoint(x: 0.45, y: 0.3), box: nil, isOnScreen: true, angle: 0, distance: 1, chip: "Pad under · Towel"),
            ARItemInput(material: .pillow, position: CGPoint(x: 0.55, y: 0.34), box: nil, isOnScreen: true, angle: 0, distance: 1, chip: "Pad under · Pillow"),
        ]
        let scene = ARSceneBuilder.build(
            overlay: .empty, items: items, context: ARContext(), band: free, view: CGSize(width: 400, height: 800),
            measure: { CGSize(width: CGFloat($0.count) * 8 + 20, height: 30) }
        )
        #expect(scene.items.count == 2)
        let first = try #require(scene.items[0].chip), second = try #require(scene.items[1].chip)
        #expect(!first.frame.intersects(second.frame))
        if let a = first.leader, let b = second.leader {
            #expect(!segmentsCross(a.from, a.to, b.from, b.to))
        }
    }

    private func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        return side(p1, p2, p3) * side(p1, p2, p4) < 0 && side(p3, p4, p1) * side(p3, p4, p2) < 0
    }
}

@Suite struct ARGeometryTests {
    @Test func bracketArmsStayInRange() {
        #expect(ARGeometry.bracketArm(for: CGRect(x: 0, y: 0, width: 20, height: 20)) == 14)
        #expect(ARGeometry.bracketArm(for: CGRect(x: 0, y: 0, width: 100, height: 100)) == 20)
        #expect(ARGeometry.bracketArm(for: CGRect(x: 0, y: 0, width: 400, height: 400)) == 28)
    }

    @Test func aPressRingIsNeverSmallerThanAFingertip() {
        #expect(ARGeometry.pressRing(center: .zero, radius: 5).boundingRect.width == DS.AR.pressRingMinRadius * 2)
        #expect(ARGeometry.pressRing(center: .zero, radius: 40).boundingRect.width == 80)
    }

    @Test func aLimbIsNeverThinnerThanAFinger() {
        let limb = ARGeometry.limb(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), width: 4)
        #expect(abs(limb.boundingRect.height - DS.AR.limbMinWidth) < 0.5)
    }

    @Test func aPadIsPortrait() {
        let pad = ARGeometry.pad(center: .zero, size: CGSize(width: 50, height: 70), angle: 0).boundingRect
        #expect(abs(pad.height / pad.width - 1.4) < 0.01)
    }

    @Test func ghostHandsSitOnTheHeelAndPointTheFingersWay() {
        let heel = CGPoint(x: 200, y: 300)
        let up = ARGeometry.ghostHands(heel: heel, fingerAngle: -.pi / 2, palmRadius: 30)
        let pad = up.heelPad.boundingRect
        #expect(abs(pad.midX - heel.x) < 0.5 && abs(pad.midY - heel.y) < 0.5)
        #expect(up.over.boundingRect.minY < heel.y - 50, "fingers run up the screen")
        let right = ARGeometry.ghostHands(heel: heel, fingerAngle: 0, palmRadius: 30)
        #expect(right.over.boundingRect.maxX > heel.x + 50)
        let big = ARGeometry.ghostHands(heel: heel, fingerAngle: -.pi / 2, palmRadius: 60)
        #expect(abs(big.over.boundingRect.height - 2 * up.over.boundingRect.height) < 1, "scales with the palm")
    }

    /// Two hands, one on the other: the lower one's fingers fan out past the upper one's, so the pair
    /// never reads as one hand with a thumb on each side.
    @Test func theLowerHandFansOutPastTheUpperOne() {
        let hands = ARGeometry.ghostHands(heel: CGPoint(x: 200, y: 300), fingerAngle: -.pi / 2, palmRadius: 30)
        let over = hands.over.boundingRect, under = hands.under.boundingRect
        #expect(under.minX < over.minX - 20, "its fingers show beside the upper hand")
        #expect(!hands.under.subtracting(hands.over).isEmpty)
        #expect(hands.under.subtracting(hands.over).boundingRect.height > 30, "more than a thumb and a strip of heel")
    }

    /// The tip is the sharpest corner, so the arrow can only be read one way at any angle.
    @Test func thePointersTipIsItsSharpestCorner() {
        let wedge = ARGeometry.wedge(center: .zero, angle: 0).boundingRect
        #expect(wedge.maxX == 13, "the tip leads")
        #expect(wedge.width > 1.4 * wedge.height, "long, so its direction reads at a glance")
        let tip = 2 * atan(7.0 / 21.0), base = (Double.pi - tip) / 2
        #expect(tip < base / 1.5)
    }

    @Test func fingersPointUpTheScreenAndDontFlip() {
        #expect(abs(ARGeometry.fingerAngle(torsoAxis: 0) + .pi / 2) < 1e-9)
        #expect(abs(ARGeometry.fingerAngle(torsoAxis: .pi) + .pi / 2) < 1e-9, "head either way, fingers still up")
        #expect(abs(ARGeometry.fingerAngle(torsoAxis: .pi / 2)) < 1e-9, "a torso upright on screen: fingers right")
        let near = ARGeometry.fingerAngle(torsoAxis: 0.09)
        #expect(abs(near - (0.09 - .pi / 2)) < 1e-9)
    }
}

// MARK: - The patient's outline

private let patientOutline = VisionOverlay.Outline(
    torso: [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.3, y: 0.35), CGPoint(x: 0.6, y: 0.33), CGPoint(x: 0.6, y: 0.22)],
    torsoLocked: true,
    head: .init(center: CGPoint(x: 0.2, y: 0.27), radius: 0.06, isLocked: true),
    limbs: [
        .init(from: CGPoint(x: 0.6, y: 0.22), to: CGPoint(x: 0.8, y: 0.22), width: 0.08, isLocked: true),
        .init(from: CGPoint(x: 0.6, y: 0.33), to: CGPoint(x: 0.8, y: 0.33), width: 0.001, isLocked: false),
    ]
)

@MainActor
@Suite struct AROutlineTests {
    @Test func theOutlineHasEveryPartInPoints() throws {
        let scene = build(VisionOverlay(outline: patientOutline), context: ARContext(target: .chestCenter))
        let outline = try #require(scene.outline)
        #expect(outline.parts.map(\.kind) == [.torso, .limb, .limb, .head])
        #expect(scene.hasMarks)
        #expect(scene.markIDs.first == ARSceneBuilder.outlineID, "it fades in on first lock like the other marks")
        let torso = outline.parts[0].path.boundingRect
        #expect(abs(torso.minX - 120) < 0.5 && abs(torso.maxX - 240) < 0.5)
        #expect(abs(torso.minY - 160) < 0.5 && abs(torso.maxY - 280) < 0.5)
        let head = outline.parts[3].path.boundingRect
        #expect(abs(head.width - 48) < 0.5, "radius is a fraction of the view's width")
    }

    @Test func eachPartKeepsItsOwnLock() throws {
        let outline = try #require(build(VisionOverlay(outline: patientOutline), context: ARContext(target: .chestCenter)).outline)
        #expect(outline.parts.map(\.lock) == [.locked, .locked, .estimating, .locked])
    }

    @Test func aHairlineLimbIsHeldToAWidthThatReads() throws {
        let outline = try #require(build(VisionOverlay(outline: patientOutline), context: ARContext(target: .chestCenter)).outline)
        let thin = outline.parts[2].path.boundingRect
        #expect(thin.height >= DS.AR.Outline.minLimbWidth - 0.5)
    }

    @Test func insideTheGraceEverythingDrawsDashed() throws {
        var context = ARContext(target: .chestCenter)
        context.estimating = true
        let outline = try #require(build(VisionOverlay(outline: patientOutline), context: context).outline)
        #expect(outline.parts.allSatisfy { $0.lock == .estimating })
    }

    @Test func lostTrackingHidesTheOutline() {
        var context = ARContext(target: .chestCenter)
        context.trackingLost = true
        #expect(build(VisionOverlay(outline: patientOutline), context: context).outline == nil)
    }

    @Test func anOutlineAloneCountsAsMarksSoItIsNotLostTracking() {
        let memory = ARMemory()
        let context = ARContext(target: .chestCenter)
        _ = memory.frame(overlay: VisionOverlay(outline: patientOutline), zones: [], items: [], stateID: "s", context: context, now: 0)
        let later = memory.frame(overlay: VisionOverlay(outline: patientOutline), zones: [], items: [], stateID: "s", context: context, now: 5)
        #expect(!later.context.trackingLost)
        #expect(!later.context.estimating)
    }
}
