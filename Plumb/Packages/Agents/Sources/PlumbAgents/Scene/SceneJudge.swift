import Foundation

/// Tests a model's claim that an object is at a point, using only what the depth sensor measured
/// there. Pure and synchronous: the same probe always gives the same verdict.
public enum SceneJudge {
    /// Accepts the point only if something of a plausible size stands out from the surface behind
    /// it, at a distance the sensor can be trusted at.
    ///
    /// The surface behind is taken from the outer band of the grid. A sign, a poster or a picture on
    /// a wall-mounted screen lies in that surface and is rejected as flat, at any viewing angle.
    /// The object has to end inside the grid: something that runs off its edge is never accepted.
    public static func judge(_ probe: SceneProbe, config: AgentsConfig = AgentsConfig()) -> SceneVerdict {
        guard let grid = DepthGrid(probe), grid.validFraction >= config.sceneMinValidFraction,
              let spotDepth = grid.centreDepth else {
            return SceneVerdict(finding: .unmeasured, reason: "No depth reading there.")
        }
        // Half the required relief separates "standing out" from sensor noise of a centimetre or so.
        let margin = config.sceneMinReliefM / 2
        let surface = InversePlane.dominant(in: grid.border(fraction: config.sceneBorderFraction), tolerance: margin)
        let object = surface.flatMap { grid.proudObject(inFrontOf: $0, threshold: margin) }
        let distance = object?.distanceM ?? spotDepth

        if distance < config.sceneMinDistanceM {
            return SceneVerdict(finding: .outOfRange, distanceM: distance, reason: "Too close to measure.")
        }
        if distance > config.sceneMaxDistanceM {
            return SceneVerdict(finding: .outOfRange, distanceM: distance, reason: "Too far away to measure.")
        }
        guard let surface else {
            return SceneVerdict(finding: .unmeasured, distanceM: distance,
                                reason: "Nothing flat behind it to compare against.")
        }
        guard let object, object.reliefM >= config.sceneMinReliefM else {
            return SceneVerdict(finding: .flat, distanceM: distance, reliefM: object?.reliefM,
                                reason: "Flat. A sign or picture, not the device.")
        }
        // On a noisy reading a few neighbouring cells can sit centimetres proud of a bare wall by
        // chance. Relief only counts once it is clear of the noise measured across the whole grid:
        // the border alone is too few readings to measure noise on a coarse grid.
        guard object.reliefM >= config.sceneReliefNoiseMultiple * surface.noise(in: grid.readings) else {
            return SceneVerdict(finding: .unmeasured, distanceM: distance, reliefM: object.reliefM,
                                reason: "The depth reading is too noisy to tell.")
        }

        // One image pixel covers distance / focal length metres at the object.
        let metresPerPixel = object.distanceM / probe.focalLengthPx
        let width = Double(object.columns) * probe.patchWidthPx / Double(probe.gridWidth) * metresPerPixel
        let height = Double(object.rows) * probe.patchHeightPx / Double(probe.gridHeight) * metresPerPixel
        var verdict = SceneVerdict(finding: .wrongSize, distanceM: distance, reliefM: object.reliefM,
                                   widthM: width, heightM: height, reason: "")
        if max(width, height) > config.sceneMaxSideM {
            verdict.reason = "Too big to be the device."
        } else if object.touchesEdge {
            // What shows is a lower bound on its size. A shelf, a pillar or a table edge entering
            // the grid looks exactly like this, so it is never accepted on the part that shows.
            verdict.finding = .cutOff
            verdict.reason = "Only part of it is in view."
        } else if min(width, height) < config.sceneMinSideM {
            verdict.reason = "Too small to be the device."
        } else {
            verdict.finding = .plausible
            verdict.reason = "Stands out from the surface behind it and is the size of the device."
        }
        return verdict
    }
}
