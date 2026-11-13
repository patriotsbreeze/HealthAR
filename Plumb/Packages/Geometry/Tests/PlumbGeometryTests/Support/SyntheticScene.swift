import Foundation
import simd
import PlumbContracts
@testable import PlumbGeometry

/// A made-up room with known answers, rendered into the frames a real capture would record.
///
/// A textured "hands" rectangle 12 cm wide and 10 cm tall faces the camera and moves straight up
/// and down in the world. A textured wall stands 40 cm behind it and a still panel beside it.
/// The camera sits `rangeM` from a point near the hands, so the hands are a little off-centre.
struct SyntheticScene {
    var intrinsics = Intrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
    var tiltDownDegrees = 0.0
    var rollDegrees = 0.0
    var rangeM = 1.0
    /// Standard deviation of the noise on every depth sample.
    var depthNoiseM = 0.003
    /// Standard deviation of the hand tracker's error in each of u and v.
    var trackerJitterPx = 0.3
    /// How fast the reported camera height creeps away from the truth.
    var poseDriftMMPerS = 0.0
    /// Standard deviation of frame-to-frame error in the reported camera height.
    var poseJitterMM = 0.0
    /// Whether frames carry the patch on the still panel.
    var showsReference = true
    /// Marks the left half of the hands patch as low confidence.
    var halfLowConfidence = false
    var trackingNormal = true
    /// Metres the hands move sideways for every metre they move up; 0 is a straight vertical stroke.
    var sidewaysSlope = 0.0
    /// How the capture side places the luma grid from frame to frame.
    var lumaGrid = LumaPlacement.fixed
    /// Whether frames say where the luma grid's centre is.
    var reportsLumaCentre = true
    /// Picks the patterns painted on the hands and the wall.
    var textureSeed: UInt64 = 11
    var seed: UInt64 = 7

    static let handsRest = SIMD3<Double>(0.10, 0.30, -0.20)
    static let aimOffset = SIMD3<Double>(-0.06, 0.04, 0)
    static let handsSizeM = SIMD2<Double>(0.12, 0.10)
    static let wallBehindM = 0.40
    static let panelAsideM = 0.30
    static let panelSizeM = 0.20
    /// What the hands depth patch covers at the hands' range: across, and along the stroke.
    static let depthWindowM = SIMD2<Double>(0.14, 0.22)
    static let depthWindowSamples = 24
    static let panelWindowM = 0.10
    static let panelWindowSamples = 16
    /// Narrower than the hands so every column is on them; taller so the stroke stays inside.
    static let lumaSizeM = SIMD2<Double>(0.10, 0.22)
    static let lumaColumns = 32
    static let lumaRows = 96

    enum LumaPlacement {
        /// Laid once where the hands rest and never moved.
        case fixed
        /// Laid where the hands rest, then moved `px` pixels up the image's world-up direction
        /// from time `afterS` on, as a capture side re-centring its grid would.
        case hops(px: Double, afterS: TimeInterval)
        /// Re-centred on the tracked hands in every frame.
        case followsHands
    }

    /// Where the camera really is. The pose written into frames may drift or jitter away from it.
    var truePose: CameraPose {
        let tilt = tiltDownDegrees * .pi / 180
        let forward = SIMD3(0, -sin(tilt), -cos(tilt))
        let aim = Self.handsRest + Self.aimOffset
        return .aimed(from: aim - forward * rangeM, tiltDownRadians: tilt, rollRadians: rollDegrees * .pi / 180)
    }

    /// The true straight-line distance from the camera to the hands when they are `heightM` above rest.
    func trueRangeM(handsHeightM heightM: Double = 0) -> Double {
        simd_distance(truePose.position, handsCentre(atHeightM: heightM))
    }

    func handsCentre(atHeightM heightM: Double) -> SIMD3<Double> {
        Self.handsRest + SIMD3(sidewaysSlope * heightM, heightM, 0)
    }

    /// One frame for each true height sample (millimetres above the hands' rest position).
    func frames(following heights: [HeightSample]) -> [TraceFrame] {
        let stage = Stage(scene: self)
        var noise = Noise(seed: seed)
        return heights.map { stage.frame(at: $0.t, handsHeightM: $0.heightMM / 1000, noise: &noise) }
    }
}

/// One line of sight boiled down to what flat, camera-facing surfaces need: how far across and up
/// their plane it lands for every metre of planar depth, measured from the camera.
private struct Sight {
    var across: Double
    var up: Double
}

/// Where the centre of a surface lies, in the same terms: its place in the plane and its planar depth.
private struct Spot {
    var across: Double
    var up: Double
    var depthM: Double
}

/// The scene's fixed layout, worked out once and then rendered frame after frame.
/// Lines of sight never change, so they are computed here and the per-frame work is plain arithmetic.
private struct Stage {
    let scene: SyntheticScene
    let camera: SceneCamera
    /// Directions lying in the hands' plane: level, and as upright as a plane facing the camera allows.
    let planeRight: SIMD3<Double>
    let planeUp: SIMD3<Double>
    let panel: Spot
    let wallDepthM: Double
    let handsWindow: ImageWindow
    let panelWindow: ImageWindow
    /// The luma grid where the hands rest, and the lines of sight through its samples.
    let restGrid: LumaGrid
    let restSights: [Sight]
    let handsSights: [Sight]
    let panelSights: [Sight]
    let handsTexture: Texture
    let wallTexture: Texture

    init(scene: SyntheticScene) {
        self.scene = scene
        let pose = scene.truePose
        let camera = SceneCamera(intrinsics: scene.intrinsics, pose: pose)
        let planeRight = simd_normalize(simd_cross(camera.forward, SIMD3(0, 1, 0)))
        let planeUp = simd_cross(planeRight, camera.forward)
        self.camera = camera
        self.planeRight = planeRight
        self.planeUp = planeUp

        func spot(of world: SIMD3<Double>) -> Spot {
            let offset = world - camera.position
            return Spot(across: simd_dot(offset, planeRight), up: simd_dot(offset, planeUp),
                        depthM: camera.planarDepth(of: world))
        }
        func sight(through pixel: SIMD2<Double>) -> Sight {
            Self.sight(through: pixel, camera: camera, planeRight: planeRight, planeUp: planeUp)
        }
        func window(around centre: SIMD3<Double>, sizeM: SIMD2<Double>, samples: Int) -> ImageWindow {
            // The upright image rectangle that just covers a patch of the hands' plane.
            let middle = camera.pixel(of: centre)
            let across = camera.pixel(of: centre + planeRight * sizeM.x / 2) - middle
            let along = camera.pixel(of: centre + planeUp * sizeM.y / 2) - middle
            return ImageWindow(centre: middle, halfSize: simd_abs(across) + simd_abs(along),
                               columns: samples, rows: samples)
        }
        func sights(of window: ImageWindow) -> [Sight] {
            (0..<window.rows).flatMap { row in
                (0..<window.columns).map { sight(through: window.pixel(column: $0, row: row)) }
            }
        }

        let rest = SyntheticScene.handsRest
        let panelCentre = rest + planeRight * SyntheticScene.panelAsideM
        panel = spot(of: panelCentre)
        wallDepthM = camera.planarDepth(of: rest) + SyntheticScene.wallBehindM
        handsWindow = window(around: rest, sizeM: SyntheticScene.depthWindowM,
                             samples: SyntheticScene.depthWindowSamples)
        panelWindow = window(around: panelCentre,
                             sizeM: SIMD2(SyntheticScene.panelWindowM, SyntheticScene.panelWindowM),
                             samples: SyntheticScene.panelWindowSamples)
        handsSights = sights(of: handsWindow)
        panelSights = sights(of: panelWindow)

        let restPixel = camera.pixel(of: rest)
        let grid = LumaGrid.spanning(heightM: SyntheticScene.lumaSizeM.y, widthM: SyntheticScene.lumaSizeM.x,
                                     columns: SyntheticScene.lumaColumns, rows: SyntheticScene.lumaRows,
                                     u: restPixel.x, v: restPixel.y, depthM: camera.planarDepth(of: rest),
                                     intrinsics: scene.intrinsics, pose: pose)!
        restGrid = grid
        restSights = Self.sights(of: grid, camera: camera, planeRight: planeRight, planeUp: planeUp)

        let hands = SyntheticScene.handsSizeM
        handsTexture = Texture(seed: scene.textureSeed, cell: 0.008,
                               x: -hands.x...hands.x, y: -hands.y...hands.y)
        wallTexture = Texture(seed: scene.textureSeed &+ 12, cell: 0.015, x: -1...1, y: -1...1)
    }

    func frame(at t: TimeInterval, handsHeightM: Double, noise: inout Noise) -> TraceFrame {
        let handsCentre = scene.handsCentre(atHeightM: handsHeightM)
        let offset = handsCentre - camera.position
        let hands = Spot(across: simd_dot(offset, planeRight), up: simd_dot(offset, planeUp),
                         depthM: camera.planarDepth(of: handsCentre))
        let tracked = camera.pixel(of: handsCentre)
            + SIMD2(noise.gaussian(), noise.gaussian()) * scene.trackerJitterPx
        let handsPatch = depthPatch(handsWindow, sights: handsSights, hands: hands,
                                    leftHalfLow: scene.halfLowConfidence, noise: &noise)
        let (grid, sights) = lumaLayout(at: t, tracked: tracked)
        let luma = LumaPatch(width: grid.columns, height: grid.rows, pitchPx: grid.pitchPx,
                             pixels: sights.map { brightness(along: $0, hands: hands, noise: &noise) })
        let panelPatch = scene.showsReference
            ? depthPatch(panelWindow, sights: panelSights, hands: hands, leftHalfLow: false, noise: &noise)
            : nil
        return TraceFrame(t: t, intrinsics: scene.intrinsics, pose: reportedPose(at: t, noise: &noise),
                          trackingNormal: scene.trackingNormal, handsU: tracked.x, handsV: tracked.y,
                          hands: handsPatch, handsLuma: luma,
                          handsLumaU: scene.reportsLumaCentre ? grid.centreU : nil,
                          handsLumaV: scene.reportsLumaCentre ? grid.centreV : nil,
                          referenceU: panelPatch == nil ? nil : panelWindow.centre.x,
                          referenceV: panelPatch == nil ? nil : panelWindow.centre.y,
                          reference: panelPatch)
    }

    /// Where the luma grid sits for this frame, and the lines of sight through its samples.
    private func lumaLayout(at t: TimeInterval, tracked: SIMD2<Double>) -> (LumaGrid, [Sight]) {
        var grid = restGrid
        switch scene.lumaGrid {
        case .fixed:
            return (restGrid, restSights)
        case .hops(let px, let afterS):
            guard t >= afterS else { return (restGrid, restSights) }
            grid.centreU += px * grid.upDirection.x
            grid.centreV += px * grid.upDirection.y
        case .followsHands:
            grid.centreU = tracked.x
            grid.centreV = tracked.y
        }
        return (grid, Self.sights(of: grid, camera: camera, planeRight: planeRight, planeUp: planeUp))
    }

    private static func sight(through pixel: SIMD2<Double>, camera: SceneCamera,
                              planeRight: SIMD3<Double>, planeUp: SIMD3<Double>) -> Sight {
        let ray = camera.ray(pixel)
        return Sight(across: simd_dot(ray, planeRight), up: simd_dot(ray, planeUp))
    }

    private static func sights(of grid: LumaGrid, camera: SceneCamera,
                               planeRight: SIMD3<Double>, planeUp: SIMD3<Double>) -> [Sight] {
        (0..<grid.rows).flatMap { row in
            (0..<grid.columns).map {
                sight(through: grid.imagePoint(column: $0, row: row), camera: camera,
                      planeRight: planeRight, planeUp: planeUp)
            }
        }
    }

    /// The pose a frame claims, which is the true pose with a wrong height.
    private func reportedPose(at t: TimeInterval, noise: inout Noise) -> CameraPose {
        var pose = scene.truePose
        let errorMM = scene.poseDriftMMPerS * t + scene.poseJitterMM * noise.gaussian()
        pose.columns[13] += Float(errorMM / 1000)
        return pose
    }

    // MARK: - Rendering

    private enum Surface {
        case hands(across: Double, up: Double)
        case panel
        case wall(across: Double, up: Double)
    }

    /// What a line of sight meets first, and how far along the lens axis.
    /// Every surface faces the camera, so each lies at a single planar depth.
    private func cast(_ sight: Sight, hands: Spot) -> (surface: Surface, depthM: Double) {
        let handsAcross = sight.across * hands.depthM - hands.across
        let handsUp = sight.up * hands.depthM - hands.up
        if abs(handsAcross) <= SyntheticScene.handsSizeM.x / 2, abs(handsUp) <= SyntheticScene.handsSizeM.y / 2 {
            return (.hands(across: handsAcross, up: handsUp), hands.depthM)
        }
        let panelAcross = sight.across * panel.depthM - panel.across
        let panelUp = sight.up * panel.depthM - panel.up
        if abs(panelAcross) <= SyntheticScene.panelSizeM / 2, abs(panelUp) <= SyntheticScene.panelSizeM / 2 {
            return (.panel, panel.depthM)
        }
        return (.wall(across: sight.across * wallDepthM, up: sight.up * wallDepthM), wallDepthM)
    }

    private func depthPatch(_ window: ImageWindow, sights: [Sight], hands: Spot, leftHalfLow: Bool,
                            noise: inout Noise) -> DepthPatch {
        var depths: [Float] = []
        var confidence: [UInt8] = []
        depths.reserveCapacity(sights.count)
        confidence.reserveCapacity(sights.count)
        for (index, sight) in sights.enumerated() {
            var depth = cast(sight, hands: hands).depthM + scene.depthNoiseM * noise.gaussian()
            var level: UInt8 = 2
            let draw = noise.unit()
            if draw < 0.10 {
                // One sample in ten is junk that the sensor itself flags as untrustworthy.
                level = 0
                depth += (noise.unit() - 0.5) * 0.6
            } else if draw < 0.30 {
                level = 1
            }
            if leftHalfLow, index % window.columns < window.columns / 2 { level = 0 }
            depths.append(Float(depth))
            confidence.append(level)
        }
        return DepthPatch(width: window.columns, height: window.rows, depthsM: depths, confidence: confidence)
    }

    private func brightness(along sight: Sight, hands: Spot, noise: inout Noise) -> UInt8 {
        let shade: Double
        switch cast(sight, hands: hands).surface {
        case .hands(let across, let up): shade = handsTexture.value(across, up)
        case .panel: shade = 0.5
        case .wall(let across, let up): shade = wallTexture.value(across, up)
        }
        let level = 40 + 180 * shade + 1.5 * noise.gaussian()
        return UInt8(min(max(level.rounded(), 0), 255))
    }
}
