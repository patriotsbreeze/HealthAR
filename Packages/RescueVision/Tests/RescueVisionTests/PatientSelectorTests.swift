import Testing
@testable import RescueVision

/// Camera level in landscape: gravity runs down the image.
private let levelGravity = SIMD2<Double>(0, 1)
private let selector = PatientSelector()

private let lying = person(center: [0.4, 0.7], axisDegrees: 5)
private let upright = person(center: [0.8, 0.4], axisDegrees: 88)

@Test func uprightRescuerPlusLyingPatientPicksThePatient() {
    let result = selector.select(people: [upright, lying], gravity: levelGravity, imageAspect: 1)
    #expect(result == .patient(lying))
}

@Test func twoLyingPeopleGiveNoTarget() {
    let other = person(center: [0.6, 0.3], axisDegrees: 175)
    let result = selector.select(people: [lying, other], gravity: levelGravity, imageAspect: 1)
    #expect(result == .none(.multipleCandidates))
}

@Test func onlyUprightGivesNoTarget() {
    let result = selector.select(people: [upright], gravity: levelGravity, imageAspect: 1)
    #expect(result == .none(.noHorizontalTorso))
}

@Test func lowConfidencePatientGivesNoTarget() {
    let shaky = person(axisDegrees: 0, confidence: 0.1)
    #expect(selector.select(people: [shaky], gravity: levelGravity, imageAspect: 1) == .none(.lowConfidence))
}

@Test func oneLowConfidenceJointIsEnough() {
    var shaky = lying
    shaky.leftHip.confidence = 0.05
    #expect(selector.select(people: [shaky], gravity: levelGravity, imageAspect: 1) == .none(.lowConfidence))
}

@Test func shakyUprightPersonDoesNotBlockThePatient() {
    let shakyUpright = person(center: [0.8, 0.4], axisDegrees: 88, confidence: 0.1)
    #expect(selector.select(people: [shakyUpright, lying], gravity: levelGravity, imageAspect: 1) == .patient(lying))
}

@Test func shakySecondLyingPersonBlocksThePatient() {
    let shakyLying = person(center: [0.6, 0.3], axisDegrees: 175, confidence: 0.1)
    let result = selector.select(people: [lying, shakyLying], gravity: levelGravity, imageAspect: 1)
    #expect(result == .none(.multipleCandidates))
}

@Test func noPeopleOrNoGravityGivesNoTarget() {
    #expect(selector.select(people: [], gravity: levelGravity, imageAspect: 1) == .none(.noPeople))
    #expect(selector.select(people: [lying], gravity: nil, imageAspect: 1) == .none(.gravityUnknown))
}

@Test func headDirectionDoesNotMatter() {
    for axis in [0.0, 180] {
        let patient = person(axisDegrees: axis)
        #expect(selector.select(people: [patient], gravity: levelGravity, imageAspect: 1) == .patient(patient))
    }
}

@Test func gravityDecidesRatherThanTheImageAxes() {
    // Portrait phone: capture +x points at the ground, so a body along capture y is lying down.
    let gravity = SIMD2<Double>(1, 0)
    let lyingAcrossPortrait = person(axisDegrees: 90)
    let standingInPortrait = person(center: [0.2, 0.2], axisDegrees: 0)
    let result = selector.select(people: [standingInPortrait, lyingAcrossPortrait], gravity: gravity, imageAspect: 1)
    #expect(result == .patient(lyingAcrossPortrait))
}

@Test func leaningTorsoIsNotACandidate() {
    let kneelingOver = person(axisDegrees: 90 - 35)
    #expect(selector.select(people: [kneelingOver], gravity: levelGravity, imageAspect: 1) == .none(.noHorizontalTorso))
}

@Test func angleIsMeasuredWithoutAspectDistortion() {
    // 40 degrees from gravity in real image geometry. In raw normalized values on a 16:9 image
    // the same keypoints read much nearer vertical or horizontal, so this catches a missing fix.
    let aspect = 16.0 / 9
    let tilted = person(axisDegrees: 50, aspect: aspect)
    #expect(selector.select(people: [tilted], gravity: levelGravity, imageAspect: aspect) == .none(.noHorizontalTorso))

    // 60 degrees from gravity passes, while in raw normalized values it reads under 50.
    let flatter = person(axisDegrees: 30, aspect: aspect)
    #expect(selector.select(people: [flatter], gravity: levelGravity, imageAspect: aspect) == .patient(flatter))
}

@Test func lookingStraightDownUsesTorsoShapeInsteadOfGravity() {
    let patient = person(axisDegrees: 90, length: 0.5, width: 0.4)
    let foreshortenedStander = person(center: [0.9, 0.9], axisDegrees: 45, length: 0.15, width: 0.4)
    let result = selector.select(people: [foreshortenedStander, patient], gravity: [0, 0], imageAspect: 1)
    #expect(result == .patient(patient))
    #expect(selector.select(people: [foreshortenedStander], gravity: [0, 0.1], imageAspect: 1) == .none(.noHorizontalTorso))
}
