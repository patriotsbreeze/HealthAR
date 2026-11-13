import Testing
@testable import RescueVision

private let selector = PatientSelector()

@Test func aSeatedOrStandingPersonCountsNearAPin() {
    let seated = fullPerson(center: [0.5, 0.5], axisDegrees: 90)
    #expect(selector.selectNearest(people: [seated], anchor: [0.55, 0.8], imageAspect: 1) == .patient(seated))
}

/// A helper pressing on the wound has a hand at the pin. Their torso is still farther off.
@Test func theNearestTorsoWinsOverAHelpersHandAtThePin() {
    let patient = fullPerson(center: [0.3, 0.5], axisDegrees: 90, width: 0.2)
    var helper = fullPerson(center: [0.8, 0.5], axisDegrees: 90, width: 0.2)
    helper.extras[.leftWrist]?.position = [0.5, 0.6]
    let pin = SIMD2<Double>(0.5, 0.6)
    #expect(selector.selectNearest(people: [helper, patient], anchor: pin, imageAspect: 1) == .patient(patient))
}

@Test func aPinInsideATorsoIsNearestToIt() {
    let a = fullPerson(center: [0.3, 0.5], axisDegrees: 90, width: 0.2)
    let b = fullPerson(center: [0.62, 0.5], axisDegrees: 90, width: 0.2)
    #expect(selector.selectNearest(people: [a, b], anchor: [0.6, 0.5], imageAspect: 1) == .patient(b))
}

@Test func anArmReachingInFromTheEdgeIsDropped() {
    var arm = person(center: [0.98, 0.5], axisDegrees: 90, width: 0.1)
    arm.extras = [
        .rightElbow: DetectedPerson.Joint(position: [0.85, 0.55], confidence: 0.9),
        .rightWrist: DetectedPerson.Joint(position: [0.7, 0.6], confidence: 0.9),
    ]
    #expect(selector.selectNearest(people: [arm], anchor: [0.7, 0.6], imageAspect: 1) == .none(.notNearPin))

    let patient = fullPerson(center: [0.3, 0.5], axisDegrees: 90, width: 0.2)
    #expect(selector.selectNearest(people: [arm, patient], anchor: [0.7, 0.6], imageAspect: 1) == .patient(patient))

    // Both arms showing is a whole person who happens to stand at the edge.
    let edge = fullPerson(center: [0.97, 0.5], axisDegrees: 90, width: 0.1)
    #expect(selector.selectNearest(people: [edge], anchor: [0.9, 0.6], imageAspect: 1) == .patient(edge))
}

@Test func aThinDetectionIsNotTrustedNearAPin() {
    let faint = person(axisDegrees: 90, confidence: 0.2)
    #expect(selector.selectNearest(people: [faint], anchor: [0.5, 0.5], imageAspect: 1) == .none(.notNearPin))
    #expect(selector.selectNearest(people: [], anchor: [0.5, 0.5], imageAspect: 1) == .none(.noPeople))
}

@Test func distanceToTheTorsoIsMeasuredWithoutAspectDistortion() {
    let aspect = 16.0 / 9
    // In image heights the pin is 0.1 from one torso's side and 0.08 above the other's. Raw
    // normalized x shrinks the first gap to 0.056, which would pick the wrong one.
    let beside = person(center: [0.8 / aspect, 0.5], axisDegrees: 90, length: 0.4, width: 0.2, aspect: aspect)
    let below = person(center: [1 / aspect, 0.63], axisDegrees: 0, length: 0.2, width: 0.1, aspect: aspect)
    let anchor = SIMD2(1 / aspect, 0.5)
    #expect(selector.selectNearest(people: [beside, below], anchor: anchor, imageAspect: aspect) == .patient(below))
}
