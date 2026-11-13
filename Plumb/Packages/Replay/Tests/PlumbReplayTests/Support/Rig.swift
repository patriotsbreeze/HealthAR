import Foundation
import PlumbContracts
import PlumbGeometry
import simd

/// A made-up rig with a known answer, rendered into the frames the phone would record.
///
/// A propped camera looks down at a flat, textured plate, the top of a cushion torso. The plate moves
/// straight up and down by exactly the travel asked for. A still ledge beside it serves as the
/// reference, and the floor lies far below. The hands box sits on the plate at rest, and every frame
/// carries what the phone writes: the pixel of the box's fixed centre, a depth patch around it, the
/// brightness grid laid over it once and kept, and the patch on the ledge.
///
/// The renderer is its own pinhole camera, written from the conventions in `Projection` without
/// calling it, so the replay is checked against an independent picture of the world.
struct Rig {
    /// Straight-line distance from the camera to the middle of the plate, in metres.
    var rangeM = 0.9
    var tiltDownDegrees = 40.0
    /// Moves the box centre across the plate, as placing the box somewhere else would. Keep it level.
    var boxShiftM = SIMD3<Double>(0, 0, 0)
    /// Standard deviation of the noise on every depth sample, in metres.
    var depthNoiseM = 0.002
    var seed: UInt64 = 7
    var intrinsics = Intrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)

    /// Where the plate's middle sits at rest. The camera aims here.
    static let plateCentre = SIMD3<Double>(0.05, 0.40, -0.10)
    /// Half the plate's extent across (x) and away from the camera (z), in metres.
    static let plateHalf = SIMD2<Double>(0.15, 0.30)
    /// The ledge: level with the plate at rest, from this far to the side of its middle to twice as far.
    static let ledgeFromM = 0.20
    static let floorBelowM = 0.45
    /// The reference point, this far to the side of the box centre: on the ledge for any small shift.
    static let referenceAsideM = 0.30
    /// Half the side of each depth patch, in image pixels, and samples along each side.
    static let handsHalfPx = 40.0
    static let handsSamples = 16
    static let referenceHalfPx = 20.0
    static let referenceSamples = 8
    /// The brightness grid, as the phone lays it with its default capture settings.
    static let gridHeightM = 0.24
    static let gridWidthM = 0.14
    static let gridColumns = 32
    static let gridRows = 96

    var boxCentre: SIMD3<Double> { Self.plateCentre + boxShiftM }

    /// The camera, aimed at the middle of the plate from `rangeM` away.
    var pose: CameraPose {
        let tilt = tiltDownDegrees * .pi / 180
        let forward = SIMD3(0, -sin(tilt), -cos(tilt))
        return .aimed(from: Self.plateCentre - forward * rangeM, tiltDownRadians: tilt)
    }

    /// One frame for each sample of the plate's height, in millimetres from rest (negative is pressed).
    func frames(following heights: [HeightSample]) -> [TraceFrame] {
        let stage = Stage(rig: self)
        var noise = SplitMix64(seed: seed)
        return heights.map { stage.frame(at: $0.t, plateDropM: $0.heightMM / 1000, noise: &noise) }
    }

    /// Steady pushes of `depthMM` at `ratePerMin`, after and before a little stillness, sampled as ARKit does.
    static func pushes(seconds: Double = 8, ratePerMin: Double = 110, depthMM: Double = 50,
                       startT: TimeInterval = 0) -> [HeightSample] {
        SyntheticSession.samples([.pause(1.5), SyntheticSegment(duration: seconds, ratePerMin: ratePerMin,
                                                                depthMM: depthMM), .pause(1)],
                                 sampleHz: 60, noiseMM: 0, startT: startT)
    }
}

/// The rig's fixed layout, worked out once and then rendered frame after frame.
private struct Stage {
    let rig: Rig
    let camera: Camera
    let handsPixel: SIMD2<Double>
    let referencePixel: SIMD2<Double>
    let grid: LumaGrid
    let plateTexture: Pattern
    let floorTexture: Pattern

    init(rig: Rig) {
        self.rig = rig
        camera = Camera(intrinsics: rig.intrinsics, pose: rig.pose)
        handsPixel = camera.pixel(of: rig.boxCentre)
        referencePixel = camera.pixel(of: rig.boxCentre + SIMD3(Rig.referenceAsideM, 0, 0))
        // Laid as the phone lays it: once, square to world-up at the box centre, from its range.
        grid = LumaGrid.spanning(heightM: Rig.gridHeightM, widthM: Rig.gridWidthM, columns: Rig.gridColumns,
                                 rows: Rig.gridRows, u: handsPixel.x, v: handsPixel.y,
                                 depthM: camera.planarDepth(of: rig.boxCentre),
                                 intrinsics: rig.intrinsics, pose: rig.pose)!
        plateTexture = Pattern(seed: rig.seed &+ 1, cell: 0.01, halfSize: Rig.plateHalf + 0.02)
        floorTexture = Pattern(seed: rig.seed &+ 2, cell: 0.03, halfSize: SIMD2(2, 2))
    }

    func frame(at t: TimeInterval, plateDropM: Double, noise: inout SplitMix64) -> TraceFrame {
        let plateY = Rig.plateCentre.y + plateDropM
        let hands = depthPatch(around: handsPixel, halfPx: Rig.handsHalfPx, samples: Rig.handsSamples,
                               plateY: plateY, noise: &noise)
        let reference = depthPatch(around: referencePixel, halfPx: Rig.referenceHalfPx,
                                   samples: Rig.referenceSamples, plateY: plateY, noise: &noise)
        let luma = grid.sample { u, v in
            let level = 40 + 180 * brightness(of: cast(camera.ray(SIMD2(u, v)), plateY: plateY))
                + 3 * (noise.nextUnit() - 0.5)
            return UInt8(min(max(level.rounded(), 0), 255))
        }
        return TraceFrame(t: t, intrinsics: rig.intrinsics, pose: rig.pose, trackingNormal: true,
                          handsU: handsPixel.x, handsV: handsPixel.y, hands: hands, handsLuma: luma,
                          handsLumaU: grid.centreU, handsLumaV: grid.centreV,
                          referenceU: referencePixel.x, referenceV: referencePixel.y, reference: reference)
    }

    // MARK: - Rendering

    private enum Surface {
        case plate(SIMD2<Double>)
        case ledge
        case floor(SIMD2<Double>)
    }

    /// What a line of sight meets first, and at what planar depth. Every surface is level.
    private func cast(_ ray: SIMD3<Double>, plateY: Double) -> (surface: Surface, depthM: Double) {
        let origin = camera.position
        let middle = Rig.plateCentre
        func level(_ y: Double) -> (depthM: Double, point: SIMD3<Double>)? {
            let depthM = (y - origin.y) / ray.y
            return depthM > 0 ? (depthM, origin + ray * depthM) : nil
        }
        var hits: [(surface: Surface, depthM: Double)] = []
        if let plate = level(plateY) {
            let offset = SIMD2(plate.point.x - middle.x, plate.point.z - middle.z)
            if abs(offset.x) <= Rig.plateHalf.x, abs(offset.y) <= Rig.plateHalf.y {
                hits.append((.plate(offset), plate.depthM))
            }
        }
        if let ledge = level(middle.y) {
            let aside = ledge.point.x - middle.x
            if aside >= Rig.ledgeFromM, aside <= 2 * Rig.ledgeFromM, abs(ledge.point.z - middle.z) <= Rig.plateHalf.y {
                hits.append((.ledge, ledge.depthM))
            }
        }
        if let floor = level(middle.y - Rig.floorBelowM) {
            hits.append((.floor(SIMD2(floor.point.x, floor.point.z)), floor.depthM))
        }
        return hits.min { $0.depthM < $1.depthM } ?? (.floor(.zero), 10)
    }

    private func brightness(of hit: (surface: Surface, depthM: Double)) -> Double {
        switch hit.surface {
        case .plate(let offset): plateTexture.value(at: offset)
        case .ledge: 0.5
        case .floor(let spot): floorTexture.value(at: spot)
        }
    }

    /// A square of depth samples centred on a pixel, with sensor noise and a few junk samples the
    /// sensor itself marks as low confidence.
    private func depthPatch(around centre: SIMD2<Double>, halfPx: Double, samples: Int, plateY: Double,
                            noise: inout SplitMix64) -> DepthPatch {
        var depths: [Float] = []
        var confidence: [UInt8] = []
        for row in 0..<samples {
            for column in 0..<samples {
                let step = SIMD2(Double(column), Double(row)) + 0.5
                let pixel = centre + (step / Double(samples) * 2 - 1) * halfPx
                var depthM = cast(camera.ray(pixel), plateY: plateY).depthM + rig.depthNoiseM * noise.nextGaussian()
                var level: UInt8 = 2
                if noise.nextUnit() < 0.05 {
                    level = 0
                    depthM += (noise.nextUnit() - 0.5) * 0.6
                }
                depths.append(Float(depthM))
                confidence.append(level)
            }
        }
        return DepthPatch(width: samples, height: samples, depthsM: depths, confidence: confidence)
    }
}

/// The rig's own pinhole camera, straight from the stated conventions: u right, v down, the lens
/// looking along the pose's -z, depth measured along the lens axis.
private struct Camera {
    let intrinsics: Intrinsics
    let position: SIMD3<Double>
    let right: SIMD3<Double>
    let top: SIMD3<Double>
    let forward: SIMD3<Double>

    init(intrinsics: Intrinsics, pose: CameraPose) {
        self.intrinsics = intrinsics
        let c = pose.columns.map(Double.init)
        right = SIMD3(c[0], c[1], c[2])
        top = SIMD3(c[4], c[5], c[6])
        forward = -SIMD3(c[8], c[9], c[10])
        position = SIMD3(c[12], c[13], c[14])
    }

    /// World direction through a pixel, one unit of which is one metre of planar depth.
    func ray(_ pixel: SIMD2<Double>) -> SIMD3<Double> {
        right * ((pixel.x - intrinsics.cx) / intrinsics.fx) + top * (-(pixel.y - intrinsics.cy) / intrinsics.fy) + forward
    }

    func planarDepth(of world: SIMD3<Double>) -> Double {
        simd_dot(world - position, forward)
    }

    func pixel(of world: SIMD3<Double>) -> SIMD2<Double> {
        let offset = world - position
        let depth = simd_dot(offset, forward)
        return SIMD2(intrinsics.cx + intrinsics.fx * simd_dot(offset, right) / depth,
                     intrinsics.cy - intrinsics.fy * simd_dot(offset, top) / depth)
    }
}
