import CoreGraphics
import Testing
import simd
@testable import RescueVision

private func axis(_ degrees: Double) -> SIMD2<Double> {
    SIMD2(cos(degrees * .pi / 180), sin(degrees * .pi / 180))
}

/// Every label swapped, as Vision does on someone lying face up.
private func swapped(_ body: DetectedPerson) -> DetectedPerson {
    var crossed = body
    swap(&crossed.leftShoulder, &crossed.rightShoulder)
    swap(&crossed.leftHip, &crossed.rightHip)
    return crossed
}

// MARK: - Chest

@Test(arguments: [0.0, 30, 90, 145, 180, 270, 333])
func theChestZoneSitsOnTheRingAlongTheTorso(degrees: Double) throws {
    let body = person(axisDegrees: degrees)
    let ring = try #require(TorsoMap.target(for: body.torso, imageAspect: 1))
    let chest = try #require(BodyRegionMap.chest(torso: body.torso, imageAspect: 1))
    #expect(isClose(chest.center, ring.center))
    #expect(isClose(chest.axis, axis(degrees)), "head to feet")
    #expect(isClose(chest.halfLength, ring.radius * BodyRegionMap.chestHalfLength))
    #expect(isClose(chest.halfWidth, ring.radius * BodyRegionMap.chestHalfWidth))
}

@Test func theChestZoneAxisIgnoresImageAspect() throws {
    let aspect = 4.0 / 3
    let body = person(axisDegrees: 37, aspect: aspect)
    let chest = try #require(BodyRegionMap.chest(torso: body.torso, imageAspect: aspect))
    #expect(isClose(chest.axis, axis(37)))
    let corners = chest.corners(imageAspect: aspect).map { SIMD2($0.x * aspect, $0.y) }
    #expect(isClose(simd_distance(corners[0], corners[3]), 2 * chest.halfLength), "a true rectangle in image heights")
    #expect(isClose(simd_distance(corners[0], corners[1]), 2 * chest.halfWidth))
}

@Test func noChestZoneWhereTheRingWouldBeADot() {
    #expect(BodyRegionMap.chest(torso: person(axisDegrees: 0, length: 0.05, width: 0.05).torso, imageAspect: 1) == nil)
    #expect(BodyRegionMap.pads(torso: person(axisDegrees: 0, length: 0.05, width: 0.05).torso, imageAspect: 1) == nil)
}

// MARK: - Pads

@Test(arguments: [0.0, 37, 90, 180, 250])
func padSidesSurviveALeftRightLabelSwap(degrees: Double) throws {
    let body = person(axisDegrees: degrees, aspect: 4.0 / 3)
    let straight = try #require(BodyRegionMap.pads(torso: body.torso, imageAspect: 4.0 / 3))
    let crossed = try #require(BodyRegionMap.pads(torso: swapped(body).torso, imageAspect: 4.0 / 3))
    for (a, b) in [(straight.one, crossed.one), (straight.two, crossed.two)] {
        #expect(isClose(a.center, b.center, 1e-9))
        #expect(isClose(a.axis, b.axis, 1e-9))
        #expect(isClose(a.halfLength, b.halfLength, 1e-9) && isClose(a.halfWidth, b.halfWidth, 1e-9))
    }
    #expect(straight.labelsAgree)
    #expect(!crossed.labelsAgree, "only the stroke changes")
}

/// In the torso's own frame, pad 1 is always to the patient's right and high, pad 2 to the left and low.
@Test(arguments: [0.0, 45, 90, 135, 180, 217, 270, 333])
func padsTurnWithTheTorso(degrees: Double) throws {
    let length = 0.4
    let width = 0.3
    let body = person(axisDegrees: degrees, length: length, width: width)
    let pads = try #require(BodyRegionMap.pads(torso: body.torso, imageAspect: 1))
    let a = axis(degrees)
    let right = SIMD2(-a.y, a.x)
    let shoulderMid = SIMD2<Double>(0.5, 0.5) - a * length / 2
    let one = pads.one.center - shoulderMid
    let two = pads.two.center - shoulderMid
    #expect(isClose(simd_dot(one, right), 0.28 * width))
    #expect(isClose(simd_dot(one, a), 0.18 * length))
    #expect(isClose(simd_dot(two, right), -0.5 * width))
    #expect(isClose(simd_dot(two, a), 0.62 * length))
    #expect(isClose(pads.one.axis, a) && isClose(pads.two.axis, a))
}

/// Head at the top of a portrait screen, face up: the patient's right is the screen's left.
@Test func onAPortraitScreenPadOneIsUpperLeftAndPadTwoLowerRight() throws {
    // Image x runs down this screen, so a body along image +x lies head up.
    let aspect = 4.0 / 3
    let body = person(center: [0.5, 0.5], axisDegrees: 0, aspect: aspect)
    let pads = try #require(BodyRegionMap.pads(torso: body.torso, imageAspect: aspect))
    let midline = portraitMapping.viewPoint(fromImage: [0.5, 0.5]).x
    let one = portraitMapping.viewPoint(fromImage: pads.one.center)
    let two = portraitMapping.viewPoint(fromImage: pads.two.center)
    #expect(one.x < midline)
    #expect(two.x > midline)
    #expect(one.y < two.y)
}

@Test func labelsThatDisagreeOrAnEstimatedTorsoDrawDashed() throws {
    let body = person(axisDegrees: 0)
    let measured = try #require(BodyRegionMap.lying(body, imageAspect: 1))
    #expect(measured.chestLocked && measured.padsLocked)

    let crossed = try #require(BodyRegionMap.lying(swapped(body), imageAspect: 1))
    #expect(crossed.chestLocked, "the chest has no sides")
    #expect(!crossed.padsLocked)

    var estimated = body
    estimated.torsoEstimated = true
    let guessed = try #require(BodyRegionMap.lying(estimated, imageAspect: 1))
    #expect(!guessed.chestLocked && !guessed.padsLocked)
}

// MARK: - Limbs

/// Lying along +x with arms down the sides: the left arm is at smaller y.
private let body = fullPerson(center: [0.5, 0.5], axisDegrees: 0, length: 0.4, width: 0.3)

private func point(_ name: BodyJoint, _ other: BodyJoint, at t: Double) -> SIMD2<Double> {
    let a = body.joint(name)!.position
    let b = body.joint(other)!.position
    return a + (b - a) * t
}

@Test func theNearestSegmentToThePinWins() throws {
    let forearm = try #require(BodyRegionMap.limb(person: body, anchor: point(.leftElbow, .leftWrist, at: 0.5), imageAspect: 1, previous: nil))
    #expect(forearm.bone == LimbBone(segment: .forearm, isLeft: true))
    #expect(forearm.capsule.isLocked)

    let shin = try #require(BodyRegionMap.limb(person: body, anchor: point(.rightKnee, .rightAnkle, at: 0.6), imageAspect: 1, previous: nil))
    #expect(shin.bone == LimbBone(segment: .lowerLeg, isLeft: false))
}

@Test func aPinNearTheElbowKeepsTheSegmentItHad() throws {
    let elbow = point(.leftElbow, .leftWrist, at: 0.05)
    let upper = LimbBone(segment: .upperArm, isLeft: true)
    let fore = LimbBone(segment: .forearm, isLeft: true)
    #expect(try #require(BodyRegionMap.limb(person: body, anchor: elbow, imageAspect: 1, previous: upper)).bone == upper)
    #expect(try #require(BodyRegionMap.limb(person: body, anchor: elbow, imageAspect: 1, previous: fore)).bone == fore)

    let wellDown = point(.leftElbow, .leftWrist, at: 0.6)
    #expect(try #require(BodyRegionMap.limb(person: body, anchor: wellDown, imageAspect: 1, previous: upper)).bone == fore)
}

@Test func nothingNearThePinGivesNoCapsule() {
    #expect(BodyRegionMap.limb(person: body, anchor: [0.05, 0.95], imageAspect: 1, previous: nil) == nil)
}

@Test func faintJointsDrawDashedAndFainterOnesNotAtAll() throws {
    let anchor = point(.leftElbow, .leftWrist, at: 0.5)
    let dim = fullPerson(center: [0.5, 0.5], axisDegrees: 0, limbConfidence: 0.4)
    #expect(try #require(BodyRegionMap.limb(person: dim, anchor: anchor, imageAspect: 1, previous: nil)).capsule.isLocked == false)
    let faint = fullPerson(center: [0.5, 0.5], axisDegrees: 0, limbConfidence: 0.2)
    #expect(BodyRegionMap.limb(person: faint, anchor: anchor, imageAspect: 1, previous: nil) == nil)
}

@Test func anImplausibleSegmentIsSkipped() {
    var folded = body
    folded.extras[.leftWrist] = folded.extras[.leftElbow]
    #expect(BodyRegionMap.capsule(for: LimbBone(segment: .forearm, isLeft: true), person: folded, imageAspect: 1) == nil)

    var stretched = body
    stretched.extras[.rightAnkle]?.position = [3, 0.5]
    #expect(BodyRegionMap.capsule(for: LimbBone(segment: .lowerLeg, isLeft: false), person: stretched, imageAspect: 1) == nil)
}

@Test func noThighHangsFromAnEstimatedHip() {
    var estimated = body
    estimated.torsoEstimated = true
    #expect(BodyRegionMap.capsule(for: LimbBone(segment: .thigh, isLeft: true), person: estimated, imageAspect: 1) == nil)
    #expect(BodyRegionMap.capsule(for: LimbBone(segment: .lowerLeg, isLeft: true), person: estimated, imageAspect: 1) != nil)
}

@Test func theForearmRunsOnOverTheHand() throws {
    let capsule = try #require(BodyRegionMap.capsule(for: LimbBone(segment: .forearm, isLeft: true), person: body, imageAspect: 1))
    let elbow = body.joint(.leftElbow)!.position
    let wrist = body.joint(.leftWrist)!.position
    #expect(isClose(capsule.from, elbow))
    #expect(isClose(capsule.to, wrist + (wrist - elbow) * 0.2))
}

@Test func aCapsuleIsNeverALine() throws {
    let tiny = fullPerson(center: [0.5, 0.5], axisDegrees: 0, length: 0.08, width: 0.05)
    let capsule = try #require(BodyRegionMap.capsule(for: LimbBone(segment: .forearm, isLeft: true), person: tiny, imageAspect: 1))
    #expect(capsule.radius * 2 >= BodyRegionMap.minimumLimbWidth)
}

@Test func aHeldSegmentMustStayWhereItWas() throws {
    let bone = LimbBone(segment: .forearm, isLeft: true)
    let anchor = point(.leftElbow, .leftWrist, at: 0.5)
    #expect(BodyRegionMap.held(bone, person: body, near: anchor, imageAspect: 1)?.bone == bone)
    #expect(BodyRegionMap.held(bone, person: body, near: [0.05, 0.95], imageAspect: 1) == nil, "that's someone else's arm")
}

/// Every arm label swapped, as Vision does on someone lying face up.
private func armsSwapped(_ body: DetectedPerson) -> DetectedPerson {
    var crossed = body
    for (left, right) in [(BodyJoint.leftElbow, BodyJoint.rightElbow), (.leftWrist, .rightWrist)] {
        let joint = crossed.extras[left]
        crossed.extras[left] = crossed.extras[right]
        crossed.extras[right] = joint
    }
    return crossed
}

/// The tap chose the limb, not its label. When Vision swaps left and right, the held forearm stays on
/// the arm that was tapped and takes the label that arm has now.
@Test func aHeldSegmentFollowsTheLimbThroughALabelSwap() throws {
    let bone = LimbBone(segment: .forearm, isLeft: true)
    let anchor = point(.leftElbow, .leftWrist, at: 0.5)
    let before = try #require(BodyRegionMap.held(bone, person: body, near: anchor, imageAspect: 1))
    let after = try #require(BodyRegionMap.held(bone, person: armsSwapped(body), near: anchor, imageAspect: 1))
    #expect(after.bone == LimbBone(segment: .forearm, isLeft: false))
    #expect(isClose(after.capsule.midpoint, before.capsule.midpoint))
    #expect(BodyRegionMap.isSameLimb(after.capsule, as: .forearm, near: anchor, imageAspect: 1))
    #expect(!BodyRegionMap.isSameLimb(after.capsule, as: .upperArm, near: anchor, imageAspect: 1))
}

// MARK: - On screen

@Test func zonesMapToTheViewWithTheirAxis() throws {
    let aspect = 4.0 / 3
    let lying = person(center: [0.5, 0.5], axisDegrees: 0, aspect: aspect)
    let chest = try #require(BodyRegionMap.chest(torso: lying.torso, imageAspect: aspect))
    let zone = portraitMapping.zone(chest, kind: .chest, isLocked: true)
    guard case let .polygon(points) = zone.shape else {
        Issue.record("a chest zone is a polygon")
        return
    }
    #expect(points.count == 4)
    #expect(abs(zone.axis - .pi / 2) < 1e-6, "image +x runs down this screen")
    let ring = portraitMapping.ring(for: try #require(TorsoMap.target(for: lying.torso, imageAspect: aspect)))
    #expect(abs(zone.center.x - ring.center.x) < 1e-9 && abs(zone.center.y - ring.center.y) < 1e-9)
}

@Test func aLimbCapsuleMapsWithItsWidth() throws {
    let capsule = LimbCapsule(from: [0.4, 0.5], to: [0.6, 0.5], radius: 0.05, segment: .forearm, isLocked: true)
    let zone = portraitMapping.zone(capsule)
    guard case let .capsule(a, b, width) = zone.shape else {
        Issue.record("a limb is a capsule")
        return
    }
    #expect(a == portraitMapping.viewPoint(fromImage: [0.4, 0.5]))
    #expect(b == portraitMapping.viewPoint(fromImage: [0.6, 0.5]))
    let ring = portraitMapping.ring(for: TorsoTarget(center: [0.5, 0.5], radius: 0.05))
    #expect(abs(width - 2 * ring.radius) < 1e-9, "the same scale as the ring")
    #expect(zone.kind == .limb(.forearm))
}

// MARK: - Outline

@Test func theOutlineHasTheWholeBodyWhenPoseSeesIt() throws {
    let body = fullPerson(axisDegrees: 20)
    let outline = try #require(BodyRegionMap.outline(body, imageAspect: 1))
    #expect(outline.torso == [body.leftShoulder.position, body.rightShoulder.position, body.rightHip.position, body.leftHip.position])
    #expect(outline.torsoLocked)
    let head = try #require(outline.head)
    let nose = try #require(body.extras[.nose])
    #expect(isClose(head.center, nose.position))
    #expect(isClose(head.radius, BodyRegionMap.headRadiusFraction * 0.3), "sized from the shoulders")
    #expect(Set(outline.limbs.map(\.segment)) == Set(LimbSegment.allCases))
    #expect(outline.limbs.count == 8)
    #expect(outline.limbs.allSatisfy { $0.isLocked })
}

@Test func theOutlineLimbsAreTheSameCapsulesAsTheLimbZone() throws {
    let body = fullPerson(axisDegrees: 75, aspect: 4.0 / 3)
    let outline = try #require(BodyRegionMap.outline(body, imageAspect: 4.0 / 3))
    let capsules = LimbBone.all.compactMap { BodyRegionMap.capsule(for: $0, person: body, imageAspect: 4.0 / 3) }
    #expect(outline.limbs == capsules)
}

@Test func faintLimbsDashAndUnseenOnesAreLeftOut() throws {
    let faint = try #require(BodyRegionMap.outline(fullPerson(axisDegrees: 0, limbConfidence: 0.4), imageAspect: 1))
    #expect(faint.limbs.count == 8)
    #expect(faint.limbs.allSatisfy { !$0.isLocked })
    #expect(faint.torsoLocked, "the torso is judged on its own joints")

    let unseen = try #require(BodyRegionMap.outline(fullPerson(axisDegrees: 0, limbConfidence: 0.2), imageAspect: 1))
    #expect(unseen.limbs.isEmpty)
}

@Test func anEstimatedTorsoDrawsDashedWithNoThighs() throws {
    let body = fullPerson(axisDegrees: 0)
    var joints = body.extras
    joints[.leftShoulder] = body.leftShoulder
    joints[.rightShoulder] = body.rightShoulder
    let estimated = try #require(DetectedPerson(joints: joints, imageAspect: 1))
    #expect(estimated.torsoEstimated)
    let outline = try #require(BodyRegionMap.outline(estimated, imageAspect: 1))
    #expect(!outline.torsoLocked)
    #expect(!outline.limbs.contains { $0.segment == .thigh }, "no thigh from hips nobody saw")
    #expect(outline.limbs.contains { $0.segment == .forearm })
}

@Test func noHeadSeenMeansNoHeadDrawn() throws {
    var body = fullPerson(axisDegrees: 0)
    body.extras[.nose] = nil
    let outline = try #require(BodyRegionMap.outline(body, imageAspect: 1))
    #expect(outline.head == nil)
}

@Test func theLyingRegionsCarryTheOutline() throws {
    let body = fullPerson(axisDegrees: 0)
    let regions = try #require(BodyRegionMap.lying(body, imageAspect: 1))
    #expect(regions.outline == BodyRegionMap.outline(body, imageAspect: 1))
}
