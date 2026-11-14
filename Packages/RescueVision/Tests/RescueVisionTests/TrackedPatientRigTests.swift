import Testing
import simd
@testable import RescueVision

private func globals(_ pose: [String: simd_float4x4]) -> [simd_float4x4] {
    var values = Array(repeating: matrix_identity_float4x4, count: TrackedPatientRig.joints.count)
    for (index, joint) in TrackedPatientRig.joints.enumerated() {
        values[index] = (joint.parent.map { values[$0] } ?? matrix_identity_float4x4) * pose[joint.name]!
    }
    return values
}

@Test func missingPoseLeavesTheOriginalSmoothMeshAtItsBindPose() {
    let pose = TrackedPatientRig.localPose(worldPoints: [:], modelToWorld: matrix_identity_float4x4)
    let world = globals(pose)
    for (i, joint) in TrackedPatientRig.joints.enumerated() {
        #expect(simd_distance(world[i].columns.3.xyz, joint.position) < 0.00001)
    }
}

@Test func smoothRigFollowsRaisedArmsAndSpreadLegsInModelSpace() {
    let points: [BodyJoint: SIMD3<Float>] = [
        .leftShoulder: [0.16,-0.1,0.2], .leftElbow: [0.4,-0.1,0.3], .leftWrist: [0.65,-0.1,0.35],
        .rightShoulder: [0.16,-0.1,-0.2], .rightElbow: [0.4,-0.1,-0.3], .rightWrist: [0.65,-0.1,-0.35],
        .leftHip: [-0.42,-0.1,0.1], .leftKnee: [-0.8,-0.1,0.35], .leftAnkle: [-1.1,-0.1,0.6],
        .rightHip: [-0.42,-0.1,-0.1], .rightKnee: [-0.8,-0.1,-0.35], .rightAnkle: [-1.1,-0.1,-0.6],
    ]
    let pose = TrackedPatientRig.localPose(worldPoints: points, modelToWorld: matrix_identity_float4x4)
    let world = globals(pose)
    #expect(simd_distance(world[3].columns.3.xyz, points[.leftWrist]!) < 0.00001)
    #expect(simd_distance(world[6].columns.3.xyz, points[.rightWrist]!) < 0.00001)
    #expect(simd_distance(world[9].columns.3.xyz, points[.leftAnkle]!) < 0.00001)
    #expect(simd_distance(world[12].columns.3.xyz, points[.rightAnkle]!) < 0.00001)
    #expect(world[0] == matrix_identity_float4x4)
}

@Test func rigJointNamesMustBeUnambiguous() {
    #expect(TrackedPatientRig.canonicalName("root/positiveShoulder/elbow") == "root/positiveShoulder/elbow")
    #expect(TrackedPatientRig.canonicalName("elbow") == nil)
}
