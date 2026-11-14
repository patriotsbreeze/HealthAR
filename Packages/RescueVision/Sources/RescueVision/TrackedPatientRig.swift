import Foundation
import simd

/// Bind positions match tools/rig_tracked_patient.py and the original smooth Blender mesh.
/// These transforms deform that mesh; they never generate primitive body geometry.
enum TrackedPatientRig {
    struct Joint: Sendable {
        var name: String
        var position: SIMD3<Float>
        var parent: Int?
    }

    static let joints: [Joint] = {
        var result = [Joint(name: "root", position: .zero, parent: nil)]
        for (side, sign) in [("positive", Float(1)), ("negative", Float(-1))] {
            let index = result.count
            let name = "root/\(side)Shoulder"
            result += [
                Joint(name: name, position: [0.16, -0.1, 0.2 * sign], parent: 0),
                Joint(name: name + "/elbow", position: [-0.1, -0.12, 0.25 * sign], parent: index),
                Joint(name: name + "/elbow/wrist", position: [-0.35, -0.13, 0.27 * sign], parent: index + 1),
            ]
        }
        for (side, sign) in [("positive", Float(1)), ("negative", Float(-1))] {
            let index = result.count
            let name = "root/\(side)Hip"
            result += [
                Joint(name: name, position: [-0.42, -0.1, 0.1 * sign], parent: 0),
                Joint(name: name + "/knee", position: [-0.84, -0.12, 0.12 * sign], parent: index),
                Joint(name: name + "/knee/ankle", position: [-1.25, -0.15, 0.13 * sign], parent: index + 1),
            ]
        }
        return result
    }()

    static func canonicalName(_ name: String) -> String? {
        let matches = joints.filter { $0.name == name || name.hasSuffix("/" + $0.name) || $0.name.hasSuffix("/" + name) }
        return matches.count == 1 ? matches[0].name : nil
    }

    static func localPose(worldPoints: [BodyJoint: SIMD3<Float>], modelToWorld: simd_float4x4) -> [String: simd_float4x4] {
        let inverse = modelToWorld.inverse
        let points = worldPoints.mapValues { (inverse * SIMD4($0, 1)).xyz }
        var targets: [Int: SIMD3<Float>] = [:]
        // Model-side names avoid assuming Vision's left/right agrees with the fitted frame's sign.
        func assign(_ a: [BodyJoint], _ b: [BodyJoint], start: Int) {
            let positiveA = (points[a[0]]?.z ?? 0) >= (points[b[0]]?.z ?? 0)
            for (offset, name) in (positiveA ? a : b).enumerated() { targets[start + offset] = points[name] }
            for (offset, name) in (positiveA ? b : a).enumerated() { targets[start + 3 + offset] = points[name] }
        }
        assign([.leftShoulder, .leftElbow, .leftWrist], [.rightShoulder, .rightElbow, .rightWrist], start: 1)
        assign([.leftHip, .leftKnee, .leftAnkle], [.rightHip, .rightKnee, .rightAnkle], start: 7)
        var globals = Array(repeating: matrix_identity_float4x4, count: joints.count)
        var result: [String: simd_float4x4] = ["root": matrix_identity_float4x4]
        for i in 1..<joints.count {
            let joint = joints[i], parent = joint.parent ?? 0
            var rest = matrix_identity_float4x4
            rest.columns.3 = SIMD4(joint.position - joints[parent].position, 1)
            var global = globals[parent] * rest
            if let start = targets[i] {
                global.columns.3 = SIMD4(start, 1)
                if let child = joints.indices.first(where: { joints[$0].parent == i }), let end = targets[child] {
                    let bind = joints[child].position - joint.position, delta = end - start
                    let length = simd_length(delta)
                    if length > 0.03 {
                        let rotation = simd_float4x4(simd_quatf(from: simd_normalize(bind), to: delta / length))
                        let scale = min(2.5, max(0.4, length / simd_length(bind)))
                        global = rotation
                        global.columns.0 *= scale
                        global.columns.1 *= scale
                        global.columns.2 *= scale
                        global.columns.3 = SIMD4(start, 1)
                    }
                }
            }
            globals[i] = global
            result[joint.name] = globals[parent].inverse * global
        }
        return result
    }
}
