import Foundation
import simd
import Testing
import PlumbContracts
@testable import PlumbGeometry

@Suite struct ProjectionTests {
    let intrinsics = Intrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
    let origin = SIMD3<Double>(0, 0, 0)

    private func randomPose(_ generator: inout SplitMix64) -> CameraPose {
        func spread(_ scale: Double) -> SIMD3<Double> {
            SIMD3(generator.nextUnit() - 0.5, generator.nextUnit() - 0.5, generator.nextUnit() - 0.5) * scale
        }
        return .looking(from: spread(4), along: spread(2) + SIMD3(0, 0, 0.01), up: spread(2) + SIMD3(0, 0.01, 0))
    }

    // MARK: - Conventions

    @Test func cameraSpaceIsRightUpAndLooksAlongMinusZ() {
        let pose = CameraPose(matrix_identity_float4x4)
        let centre = Projection.unproject(u: 960, v: 720, depthM: 2, intrinsics: intrinsics, pose: pose)
        #expect(simd_distance(centre, SIMD3(0, 0, -2)) < 1e-12)

        let rightOfCentre = Projection.unproject(u: 960 + 145, v: 720, depthM: 2, intrinsics: intrinsics, pose: pose)
        #expect(abs(rightOfCentre.x - 0.2) < 1e-12)

        let belowCentre = Projection.unproject(u: 960, v: 720 + 145, depthM: 2, intrinsics: intrinsics, pose: pose)
        #expect(abs(belowCentre.y + 0.2) < 1e-12)
        #expect(abs(belowCentre.z + 2) < 1e-12)
    }

    @Test func aPixelAboveTheCentreIsHigherInTheWorldForALevelCamera() {
        let pose = CameraPose.looking(from: origin, along: SIMD3(0, 0, -1))
        let centre = Projection.unproject(u: 960, v: 720, depthM: 1, intrinsics: intrinsics, pose: pose)
        let above = Projection.unproject(u: 960, v: 620, depthM: 1, intrinsics: intrinsics, pose: pose)
        #expect(above.y > centre.y)
        #expect(abs(above.y - centre.y - 100.0 / 1450) < 1e-9)
        #expect(abs(above.z - centre.z) < 1e-9)
    }

    @Test func aimedWithNoAnglesIsTheLevelCamera() {
        let position = SIMD3<Double>(0.5, 1.25, -2)
        #expect(CameraPose.aimed(from: position, tiltDownRadians: 0) == .looking(from: position, along: SIMD3(0, 0, -1)))
        #expect(CameraPose.aimed(from: position, tiltDownRadians: 0).position == position)
    }

    @Test func aTiltedCameraLooksDownAndKeepsItsTopUp() {
        let pose = CameraPose.aimed(from: origin, tiltDownRadians: .pi / 6)
        let ahead = Projection.unproject(u: 960, v: 720, depthM: 1, intrinsics: intrinsics, pose: pose)
        #expect(abs(ahead.y + 0.5) < 1e-6)
        #expect(abs(ahead.x) < 1e-6)
        let above = Projection.unproject(u: 960, v: 600, depthM: 1, intrinsics: intrinsics, pose: pose)
        #expect(above.y > ahead.y)
    }

    @Test func lookingStraightDownStillGivesARigidPose() {
        let pose = CameraPose.looking(from: origin, along: SIMD3(0, -1, 0))
        let rotation = pose.rotation
        #expect(abs(simd_determinant(rotation) - 1) < 1e-6)
        let below = Projection.unproject(u: 960, v: 720, depthM: 1, intrinsics: intrinsics, pose: pose)
        #expect(simd_distance(below, SIMD3(0, -1, 0)) < 1e-6)
    }

    // MARK: - Round trips

    @Test func unprojectThenProjectReturnsTheSamePixelAndDepth() throws {
        var generator = SplitMix64(seed: 3)
        for _ in 0..<500 {
            let pose = randomPose(&generator)
            let u = generator.nextUnit() * 1920
            let v = generator.nextUnit() * 1440
            let depthM = 0.3 + generator.nextUnit() * 3.7
            let world = Projection.unproject(u: u, v: v, depthM: depthM, intrinsics: intrinsics, pose: pose)
            let back = try #require(Projection.project(world, intrinsics: intrinsics, pose: pose))
            #expect(abs(back.u - u) < 0.01)
            #expect(abs(back.v - v) < 0.01)
            #expect(abs(back.depthM - depthM) < 1e-5)
        }
    }

    @Test func aPointBehindTheCameraDoesNotProject() {
        let pose = CameraPose.looking(from: origin, along: SIMD3(0, 0, -1))
        #expect(Projection.project(SIMD3(0.1, 0.2, 1), intrinsics: intrinsics, pose: pose) == nil)
        #expect(Projection.project(SIMD3(0, 0, 0), intrinsics: intrinsics, pose: pose) == nil)
        #expect(Projection.project(SIMD3(0.1, 0.2, -1), intrinsics: intrinsics, pose: pose) != nil)
        #expect(Projection.pixelsPerMetreAlongUp(at: SIMD3(0, 0, 1), intrinsics: intrinsics, pose: pose) == nil)
    }

    @Test func aPoseSurvivesItsMatrixAndJSON() throws {
        var generator = SplitMix64(seed: 5)
        let pose = randomPose(&generator)
        #expect(CameraPose(pose.matrix) == pose)
        #expect(pose.matrix.columns.3.w == 1)
        let data = try JSONEncoder().encode(pose)
        #expect(try JSONDecoder().decode(CameraPose.self, from: data) == pose)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CameraPose.self, from: Data("[1,0,0,0]".utf8))
        }
    }

    // MARK: - Scale along up

    @Test func aLevelCameraSeesAMetreOfHeightAsFocalLengthOverDepth() throws {
        let pose = CameraPose.looking(from: SIMD3(0.3, 1.1, 0.4), along: SIMD3(0, 0, -1))
        for depthM in [0.5, 1.0, 1.7] {
            // Off the lens axis on purpose: for a level camera only the depth matters.
            let world = pose.position + SIMD3(0.2, -0.15, -depthM)
            let scale = try #require(Projection.pixelsPerMetreAlongUp(at: world, intrinsics: intrinsics, pose: pose))
            #expect(abs(scale.pixels - intrinsics.fy / depthM) < 1e-3)
            #expect(simd_distance(scale.direction, SIMD2(0, -1)) < 1e-6)
        }
    }

    @Test(arguments: [0.0, 15, 30, 45, 60])
    func theScaleFallsWithTheCosineOfTheTilt(tiltDegrees: Double) throws {
        let tilt = tiltDegrees * .pi / 180
        let pose = CameraPose.aimed(from: SIMD3(0, 1, 0), tiltDownRadians: tilt)
        let depthM = 1.2
        let onAxis = Projection.unproject(u: intrinsics.cx, v: intrinsics.cy, depthM: depthM,
                                          intrinsics: intrinsics, pose: pose)
        let scale = try #require(Projection.pixelsPerMetreAlongUp(at: onAxis, intrinsics: intrinsics, pose: pose))
        #expect(abs(scale.pixels - intrinsics.fy * cos(tilt) / depthM) < 1e-3)
    }

    @Test func theUpDirectionTurnsWithTheCamerasRoll() throws {
        for rollDegrees in [10.0, 90, 180, -35] {
            let roll = rollDegrees * .pi / 180
            let pose = CameraPose.aimed(from: origin, tiltDownRadians: 0, rollRadians: roll)
            let scale = try #require(Projection.pixelsPerMetreAlongUp(at: SIMD3(0, 0, -1), intrinsics: intrinsics, pose: pose))
            // Turning the camera clockwise turns the picture, and so world-up in it, the other way.
            #expect(simd_distance(scale.direction, SIMD2(-sin(roll), -cos(roll))) < 1e-6)
        }
    }

    @Test func theScaleAgreesWithMovingAPointAndProjectingIt() throws {
        var generator = SplitMix64(seed: 9)
        let step = 1e-4
        for _ in 0..<200 {
            let pose = randomPose(&generator)
            let world = Projection.unproject(u: generator.nextUnit() * 1920, v: generator.nextUnit() * 1440,
                                             depthM: 0.5 + generator.nextUnit() * 2, intrinsics: intrinsics, pose: pose)
            let low = try #require(Projection.project(world - SIMD3(0, step / 2, 0), intrinsics: intrinsics, pose: pose))
            let high = try #require(Projection.project(world + SIMD3(0, step / 2, 0), intrinsics: intrinsics, pose: pose))
            let moved = SIMD2(high.u - low.u, high.v - low.v) / step
            guard let scale = Projection.pixelsPerMetreAlongUp(at: world, intrinsics: intrinsics, pose: pose) else {
                #expect(simd_length(moved) < 1e-3)
                continue
            }
            #expect(simd_distance(scale.direction * scale.pixels, moved) < 1e-3 * max(1, scale.pixels))
        }
    }

    @Test func aSlideInPixelsTurnsBackIntoTheTrueRise() throws {
        // Tilted and near enough that the scale changes several percent along the path.
        let pose = CameraPose.aimed(from: SIMD3(0, 1, 0), tiltDownRadians: .pi / 4, rollRadians: 0.3)
        let start = Projection.unproject(u: 900, v: 800, depthM: 0.7, intrinsics: intrinsics, pose: pose)
        for riseM in [-0.06, -0.02, 0.03, 0.08] {
            let end = start + SIMD3(0, riseM, 0)
            let from = try #require(Projection.project(start, intrinsics: intrinsics, pose: pose))
            let to = try #require(Projection.project(end, intrinsics: intrinsics, pose: pose))
            let up = try #require(Projection.pixelsPerMetreAlongUp(at: start, intrinsics: intrinsics, pose: pose))
            let upPx = simd_dot(SIMD2(to.u - from.u, to.v - from.v), up.direction)
            let measured = try #require(Projection.riseM(endingAt: end, upPx: upPx, intrinsics: intrinsics, pose: pose))
            #expect(abs(measured - riseM) < 1e-6)
        }
    }

    // MARK: - Placing a point from the floor plan

    @Test func aLineOfSightIsCutWhereItPassesAFloorPlanSpot() throws {
        var generator = SplitMix64(seed: 13)
        for _ in 0..<200 {
            let pose = CameraPose.aimed(from: SIMD3(generator.nextUnit(), 1 + generator.nextUnit(), generator.nextUnit()),
                                        tiltDownRadians: generator.nextUnit() * 1.2,
                                        rollRadians: (generator.nextUnit() - 0.5) * 3,
                                        headingRadians: generator.nextUnit() * 6)
            let u = generator.nextUnit() * 1920
            let v = generator.nextUnit() * 1440
            let truth = Projection.unproject(u: u, v: v, depthM: 0.4 + generator.nextUnit() * 2,
                                             intrinsics: intrinsics, pose: pose)
            let found = try #require(Projection.point(onSightThroughU: u, v: v, above: SIMD2(truth.x, truth.z),
                                                      intrinsics: intrinsics, pose: pose))
            #expect(simd_distance(found, truth) < 1e-6)
        }
    }

    @Test func aVerticalLineOfSightOrASpotBehindTheCameraCannotBePlaced() {
        let down = CameraPose.looking(from: SIMD3(0, 2, 0), along: SIMD3(0, -1, 0))
        #expect(Projection.point(onSightThroughU: intrinsics.cx, v: intrinsics.cy, above: SIMD2(0, 0),
                                 intrinsics: intrinsics, pose: down) == nil)
        let level = CameraPose.looking(from: origin, along: SIMD3(0, 0, -1))
        #expect(Projection.point(onSightThroughU: intrinsics.cx, v: intrinsics.cy, above: SIMD2(0, 3),
                                 intrinsics: intrinsics, pose: level) == nil)
    }

    // MARK: - Luma grid layout

    @Test func aLumaGridRunsDownTheWorldAndAcrossTheImage() throws {
        let pose = CameraPose.looking(from: origin, along: SIMD3(0, 0, -1))
        let grid = try #require(LumaGrid.spanning(heightM: 0.22, widthM: 0.10, columns: 32, rows: 96,
                                                  u: 1000, v: 700, depthM: 1, intrinsics: intrinsics, pose: pose))
        #expect(abs(grid.pitchPx - 0.22 * 1450 / 96) < 1e-6)
        #expect(abs(grid.columnPitchPx - 0.10 * 1450 / 32) < 1e-6)
        let topLeft = grid.imagePoint(column: 0, row: 0)
        let bottomRight = grid.imagePoint(column: 31, row: 95)
        #expect(topLeft.y < bottomRight.y)
        #expect(topLeft.x < bottomRight.x)
        #expect(simd_distance((topLeft + bottomRight) / 2, SIMD2(1000, 700)) < 1e-9)
    }

    @Test func aLumaGridFollowsWorldUpWhenTheCameraIsRolled() throws {
        let pose = CameraPose.aimed(from: origin, tiltDownRadians: 0.4, rollRadians: .pi / 2)
        let grid = try #require(LumaGrid.spanning(heightM: 0.2, widthM: 0.1, columns: 8, rows: 40,
                                                  u: 960, v: 720, depthM: 1, intrinsics: intrinsics, pose: pose))
        let highest = grid.imagePoint(column: 4, row: 0)
        let lowest = grid.imagePoint(column: 4, row: 39)
        let high = Projection.unproject(u: highest.x, v: highest.y, depthM: 1, intrinsics: intrinsics, pose: pose)
        let low = Projection.unproject(u: lowest.x, v: lowest.y, depthM: 1, intrinsics: intrinsics, pose: pose)
        #expect(high.y > low.y)
        let patch = grid.sample { u, _ in UInt8(min(max(u / 8, 0), 255)) }
        #expect(patch.width == 8)
        #expect(patch.height == 40)
        #expect(patch.pixels.count == 320)
        #expect(patch.pitchPx == grid.pitchPx)
    }
}
