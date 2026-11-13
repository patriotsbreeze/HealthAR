import Foundation
import PlumbGeometry
import simd

/// Where the target line stands: a level bar, square to the camera's line of sight, that the
/// picture shows exactly where the top of the hands will be once it has sunk the target depth.
///
/// The top of the hands is read along the line of sight through the hands box centre, so at rest
/// it sits where that line of sight reaches the rest height. Sunk straight down by the target
/// depth from there is the target. The bar is drawn a little nearer the camera than the target,
/// along the target's own line of sight: the picture shows it in exactly the same place, but it
/// lies in front of the hands rather than inside them, where it would flicker in and out of the
/// occlusion of the hands. Its world height is therefore a little above the target, by the pull
/// times how steeply the camera looks down; only where the picture shows it is ever compared.
struct LinePlacement: Sendable, Equatable {
    /// Middle of the bar in the world, in metres.
    var centre: SIMD3<Double>
    /// Unit level direction the bar runs along, to the camera's right.
    var along: SIMD3<Double>

    /// Places the bar for a hands box at `handsCentre` whose top comes back up to `restTopM` (world
    /// height, metres), with the target `sinkM` below that, seen from `pose`. `towardCameraM` is
    /// the pull toward the camera. When the rest height is not on the line of sight within
    /// `maxSlideM` of the hands box centre (a camera looking level, or a reading that makes no
    /// sense), the rest point stands straight above or below the centre instead. Nil when the
    /// camera looks straight up or down, or is no farther than the pull from the target.
    static func place(handsCentre: SIMD3<Double>, restTopM: Double, sinkM: Double, pose: CameraPose,
                      towardCameraM: Double, maxSlideM: Double) -> LinePlacement? {
        guard let side = WorldBox.sideways(of: pose) else { return nil }
        let camera = pose.position
        let rest = restPoint(handsCentre: handsCentre, heightM: restTopM, camera: camera, maxSlideM: maxSlideM)
        let target = rest - SIMD3(0, sinkM, 0)
        let toCamera = camera - target
        let range = simd_length(toCamera)
        guard range > towardCameraM else { return nil }
        return LinePlacement(centre: target + toCamera / range * towardCameraM, along: side)
    }

    /// Where the line of sight from `camera` through `handsCentre` reaches `heightM`, or the point
    /// straight above or below the centre at that height when it does not do so near the centre.
    static func restPoint(handsCentre: SIMD3<Double>, heightM: Double, camera: SIMD3<Double>,
                          maxSlideM: Double) -> SIMD3<Double> {
        let plumb = SIMD3(handsCentre.x, heightM, handsCentre.z)
        let sight = handsCentre - camera
        guard abs(sight.y) > 1e-9 else { return plumb }
        let share = (heightM - camera.y) / sight.y
        guard share > 0, abs(share - 1) * simd_length(sight) <= maxSlideM else { return plumb }
        return camera + sight * share
    }

    /// The turn about world up that takes the bar's own length, +x, onto `along`.
    var rotation: simd_quatf {
        simd_quatf(angle: Float(atan2(-along.z, along.x)), axis: SIMD3<Float>(0, 1, 0))
    }
}
