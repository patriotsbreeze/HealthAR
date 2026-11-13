import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

@Suite struct SceneJudgeTests {
    @Test func acceptsABoxStandingOffAWall() throws {
        let verdict = SceneJudge.judge(Wall.probe(distance: 2, box: Box(width: 0.3, height: 0.25, proud: 0.08)))

        #expect(verdict.accepted)
        #expect(verdict.finding == .plausible)
        #expect(abs(try #require(verdict.distanceM) - 1.92) < 0.01)
        #expect(abs(try #require(verdict.reliefM) - 0.08) < 0.005)
        #expect(abs(try #require(verdict.widthM) - 0.3) < 0.04)
        #expect(abs(try #require(verdict.heightM) - 0.25) < 0.04)
        #expect(verdict.reason == "Stands out from the surface behind it and is the size of the device.")
    }

    @Test func acceptsTheSameBoxWithSensorNoise() {
        let probe = Wall.probe(distance: 2, box: Box(width: 0.3, height: 0.25, proud: 0.08), noise: 0.005)

        #expect(SceneJudge.judge(probe).accepted)
    }

    @Test func acceptsABoxOnAWallSeenAtAnAngle() throws {
        let probe = Wall.probe(distance: 2, slant: 0.6, box: Box(width: 0.3, height: 0.25, proud: 0.08), noise: 0.003)

        let verdict = SceneJudge.judge(probe)

        #expect(verdict.accepted)
        #expect(abs(try #require(verdict.reliefM) - 0.08) < 0.015)
    }

    @Test func rejectsAFlatPatchOnAWall() throws {
        let verdict = SceneJudge.judge(Wall.probe(distance: 2, noise: 0.005))

        #expect(!verdict.accepted)
        #expect(verdict.finding == .flat)
        #expect(verdict.reason == "Flat. A sign or picture, not the device.")
        #expect(abs(try #require(verdict.distanceM) - 2) < 0.01)
    }

    @Test func rejectsAFlatPatchOnAWallSeenAtAnAngle() {
        // Across this grid the wall's depth changes by more than half a metre. It is still flat.
        let verdict = SceneJudge.judge(Wall.probe(distance: 2, slant: 0.6, noise: 0.005))

        #expect(verdict.finding == .flat)
    }

    @Test func rejectsAnObjectStandingOutLessThanTheMinimum() {
        // A picture frame: the right size, but only 2 cm proud.
        let verdict = SceneJudge.judge(Wall.probe(distance: 2, box: Box(width: 0.3, height: 0.25, proud: 0.02)))

        #expect(verdict.finding == .flat)
    }

    @Test func rejectsAFiveCentimetreObject() {
        let verdict = SceneJudge.judge(Wall.probe(distance: 2, box: Box(width: 0.05, height: 0.05, proud: 0.08)))

        #expect(!verdict.accepted)
        #expect(verdict.finding == .wrongSize)
        #expect(verdict.reason == "Too small to be the device.")
    }

    @Test func rejectsAOneAndAHalfMetreObject() {
        let cupboard = Box(width: 1.5, height: 1.0, proud: 0.1)

        let wide = SceneJudge.judge(Wall.probe(distance: 3, box: cupboard, span: 2.5))
        #expect(wide.finding == .wrongSize)
        #expect(wide.reason == "Too big to be the device.")

        // At the recommended span the cupboard fills the grid, so there is nothing around it to
        // stand out from. It must still be refused.
        #expect(!SceneJudge.judge(Wall.probe(distance: 3, box: cupboard, span: 1.0)).accepted)
    }

    @Test func rejectsBeyondRange() {
        let box = Box(width: 0.3, height: 0.25, proud: 0.08)

        let far = SceneJudge.judge(Wall.probe(distance: 6, box: box))
        #expect(far.finding == .outOfRange)
        #expect(far.reason == "Too far away to measure.")

        let near = SceneJudge.judge(Wall.probe(distance: 0.25, box: Box(width: 0.1, height: 0.1, proud: 0.05), span: 0.3))
        #expect(near.finding == .outOfRange)
        #expect(near.reason == "Too close to measure.")
    }

    @Test func rejectsWhenTheSensorHasNoReading() {
        var probe = Wall.caseOnWall
        probe.depthsM = probe.depthsM.map { _ in .nan }

        let verdict = SceneJudge.judge(probe)

        #expect(verdict.finding == .unmeasured)
        #expect(verdict.distanceM == nil)
        #expect(verdict.reason == "No depth reading there.")
    }

    @Test func rejectsAGridThatDoesNotMatchItsSize() {
        var probe = Wall.caseOnWall
        probe.depthsM.removeLast()

        #expect(SceneJudge.judge(probe).finding == .unmeasured)
    }

    @Test func rejectsWhenThereIsNoFlatSurfaceBehindToCompareWith() {
        // The object is measured, but everything around it is clutter at every depth.
        var probe = Wall.caseOnWall
        var random = SplitMix64(seed: 3)
        let side = probe.gridWidth
        for index in probe.depthsM.indices {
            let column = index % side, row = index / side
            if column < 6 || column >= side - 6 || row < 6 || row >= side - 6 {
                probe.depthsM[index] = 1 + 3 * random.nextUnit()
            }
        }

        let verdict = SceneJudge.judge(probe)

        #expect(verdict.finding == .unmeasured)
        #expect(verdict.reason == "Nothing flat behind it to compare against.")
    }

    @Test func aFewWildReadingsDoNotChangeTheVerdict() {
        var box = Wall.probe(distance: 2, box: Box(width: 0.3, height: 0.25, proud: 0.08), noise: 0.003)
        var poster = Wall.probe(distance: 2, noise: 0.003)
        // Speckle in the corners and along one edge, as a shiny floor or a window would give.
        for index in [0, 1, 31, 33, 64, 218, 1000, 1023] {
            box.depthsM[index] = 0.7
            poster.depthsM[index] = 0.7
        }

        #expect(SceneJudge.judge(box).accepted)
        #expect(SceneJudge.judge(poster).finding == .flat)
    }

    @Test func thresholdsComeFromTheConfig() {
        var strict = AgentsConfig()
        strict.sceneMinReliefM = 0.12

        #expect(SceneJudge.judge(Wall.caseOnWall, config: strict).finding == .flat)
    }

    @Test func patchSideCoversTheConfiguredSpanAtTheObjectsDistance() {
        #expect(SceneProbe.patchSidePx(centreDepthM: 2, focalLengthPx: 1500) == 750)
        #expect(SceneProbe.patchSidePx(centreDepthM: 0, focalLengthPx: 1500) == nil)
        #expect(SceneProbe.patchSidePx(centreDepthM: .nan, focalLengthPx: 1500) == nil)
    }
}
