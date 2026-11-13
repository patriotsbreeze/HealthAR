import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

/// Attempts to get something that is not the device accepted, and the device refused.
@Suite struct SceneJudgeAttackTests {
    private let aedCase = Box(width: 0.3, height: 0.25, proud: 0.08)

    // MARK: Things that are not the device

    @Test func aShelfRunningOffTheEdgeOfTheGridIsNotAccepted() {
        // 20 cm proud and 22 cm tall, and it carries on past the left edge for nobody knows how far.
        for grid in [8, 16, 32] {
            for span in [0.5, 0.6, 1.0] {
                let verdict = SceneJudge.judge(Patch.probe(grid: grid, span: span) { x, y in
                    x < 0.1 && abs(y) < 0.11 ? 1.8 : 2.0
                })
                #expect(!verdict.accepted, "grid \(grid), span \(span): \(verdict.reason)")
                #expect(verdict.finding == .cutOff, "grid \(grid), span \(span): \(verdict.reason)")
                #expect(verdict.reason == "Only part of it is in view.")
            }
        }
    }

    @Test func aGridThatIsHalfNearSurfaceAndHalfFarIsNotAccepted() {
        // A pillar or a door frame: no object, only a step in depth across the grid.
        for grid in [8, 16, 32] {
            for span in [0.4, 0.5, 0.6, 1.0] {
                for edge in [-0.1, 0, 0.1] {
                    let verdict = SceneJudge.judge(Patch.probe(grid: grid, span: span) { x, _ in
                        x < edge * span ? 1.7 : 2.0
                    })
                    #expect(!verdict.accepted, "grid \(grid), span \(span), edge \(edge): \(verdict.reason)")
                }
            }
        }
    }

    @Test func aCornerOfSomethingBiggerIsNotAccepted() {
        for grid in [8, 16, 32] {
            let verdict = SceneJudge.judge(Patch.probe(grid: grid, span: 0.8) { x, y in
                x < 0.1 && y < 0.1 ? 1.8 : 2.0
            })
            #expect(!verdict.accepted, "grid \(grid): \(verdict.reason)")
        }
    }

    @Test func aFlatWallIsNeverAcceptedHoweverNoisyTheSensor() {
        var accepted: [String] = []
        for noise in [0.005, 0.01, 0.015, 0.02, 0.025, 0.03, 0.04, 0.05] {
            for grid in [8, 16, 32] {
                for seed in 1...200 {
                    let probe = Patch.probe(grid: grid, noise: noise, seed: UInt64(seed), depth: Patch.plane())
                    if SceneJudge.judge(probe).accepted {
                        accepted.append("noise \(noise), grid \(grid), seed \(seed)")
                    }
                }
            }
        }
        #expect(accepted.isEmpty, "a bare wall was accepted: \(accepted)")
    }

    @Test func aFlatSurfaceIsFlatWhicheverWayItTilts() {
        // Each of these has well over half a metre of depth change across the grid and no relief.
        for (tiltX, tiltY) in [(1.5, 0.0), (-2.0, 0.0), (0.0, 1.5), (0.0, -2.0), (1.0, 1.0), (-1.2, 0.8)] {
            for noise in [0, 0.005, 0.01] {
                for seed in 1...20 {
                    let probe = Patch.probe(noise: noise, seed: UInt64(seed), depth: Patch.plane(tiltX: tiltX, tiltY: tiltY))
                    let verdict = SceneJudge.judge(probe)
                    #expect(verdict.finding == .flat, "tilt \(tiltX), \(tiltY), noise \(noise): \(verdict.reason)")
                }
            }
        }
    }

    @Test func aBoxInReadingsTooNoisyToTrustIsNotAccepted() {
        // 8 cm of relief cannot be told from 4 cm of noise.
        for seed in 1...50 {
            let probe = Patch.probe(noise: 0.04, seed: UInt64(seed), depth: Patch.box(aedCase))
            #expect(!SceneJudge.judge(probe).accepted)
        }
    }

    // MARK: The device, seen badly

    @Test func acceptsTheCaseWhenThePointIsNearItsCorner() {
        for grid in [8, 16, 32] {
            let probe = Patch.probe(grid: grid, noise: 0.004, depth: Patch.box(aedCase, offsetX: 0.13, offsetY: 0.1))
            let verdict = SceneJudge.judge(probe)
            #expect(verdict.accepted, "grid \(grid): \(verdict.reason)")
        }
    }

    @Test func acceptsTheCaseOnASurfaceTiltedEitherWay() {
        for (tiltX, tiltY) in [(1.5, 0.0), (-1.5, 0.0), (0.0, 2.0), (0.0, -2.0), (1.0, 1.0)] {
            for grid in [8, 16, 32] {
                let probe = Patch.probe(grid: grid, noise: 0.004, depth: Patch.box(aedCase, tiltX: tiltX, tiltY: tiltY))
                let verdict = SceneJudge.judge(probe)
                #expect(verdict.accepted, "tilt \(tiltX), \(tiltY), grid \(grid): \(verdict.reason)")
            }
        }
    }

    @Test func acceptsTheCaseWithACentimetreOfSensorNoise() {
        for seed in 1...50 {
            let probe = Patch.probe(noise: 0.01, seed: UInt64(seed), depth: Patch.box(aedCase))
            let verdict = SceneJudge.judge(probe)
            #expect(verdict.accepted, "seed \(seed): \(verdict.reason)")
        }
    }

    @Test func acceptsTheLargestPlausibleCaseEvenOffCentre() {
        let large = Box(width: 0.55, height: 0.5, proud: 0.15)
        for grid in [8, 16, 32] {
            let verdict = SceneJudge.judge(Patch.probe(grid: grid, noise: 0.004, depth: Patch.box(large, offsetX: 0.15)))
            #expect(verdict.accepted, "grid \(grid): \(verdict.reason)")
        }
    }

    @Test func aCaseCutOffByTheGridIsReportedAsCutOffNotAsTheWrongSize() throws {
        // The grid is too small for the case: 18 cm of it shows, the rest is out of view.
        let probe = Patch.probe(span: 0.4, noise: 0.004, depth: Patch.box(aedCase, offsetX: 0.17))

        let verdict = SceneJudge.judge(probe)

        #expect(!verdict.accepted)
        #expect(verdict.finding == .cutOff)
        #expect(verdict.reason == "Only part of it is in view.")
        #expect(abs(try #require(verdict.reliefM) - 0.08) < 0.01)
    }

    @Test func somethingCutOffThatIsAlreadyTooBigIsTooBig() {
        // 66 cm of it shows before it leaves the grid. However much more there is, that is too much.
        let verdict = SceneJudge.judge(Patch.probe { x, y in x < 0.1 && abs(y) < 0.33 ? 1.8 : 2.0 })

        #expect(verdict.finding == .wrongSize)
        #expect(verdict.reason == "Too big to be the device.")
    }

    @Test func aCutOffGuessRanksAboveEveryOtherRefusal() {
        let refusals: [SceneVerdict.Finding] = [.unmeasured, .outOfRange, .flat, .wrongSize]

        #expect(refusals.allSatisfy { $0 < .cutOff })
        #expect(SceneVerdict.Finding.cutOff < .plausible)
        #expect(!SceneVerdict(finding: .cutOff, reason: "").accepted)
    }
}
