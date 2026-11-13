import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

private func answer(_ intent: AskIntent, _ digest: WorldDigest = freshDigest()) -> String {
    OfflineAnswerer.answer(intent: intent, digest: digest, targets: .adult)
}

@Suite struct OfflineAnswererTests {
    // MARK: - Trusted numbers

    @Test func everyIntentHasItsSentenceForOrdinaryNumbers() {
        #expect(answer(.rate) == "112 per minute, within the target of 100 to 120.")
        #expect(answer(.depth) == "5.5 centimetres deep, within the target of 5 to 6.")
        #expect(answer(.overall) == "112 per minute, within the target. 5.5 centimetres deep, within the target.")
        #expect(answer(.count) == "87 compressions so far.")
        #expect(answer(.pauses) == "No pause right now. Compressing 87 percent of the time so far.")
        #expect(answer(.unknown) == "I can answer about rate, depth, pauses and count.")
    }

    @Test func rateIsComparedWithItsTarget() {
        #expect(answer(.rate, changedDigest { $0.ratePerMin = 95.4 }) == "95 per minute, below the target of 100 to 120.")
        #expect(answer(.rate, changedDigest { $0.ratePerMin = 131 }) == "131 per minute, above the target of 100 to 120.")
        #expect(answer(.rate, changedDigest { $0.ratePerMin = 100 }) == "100 per minute, within the target of 100 to 120.")
        #expect(answer(.rate, changedDigest { $0.ratePerMin = 120 }) == "120 per minute, within the target of 100 to 120.")
    }

    @Test func roundingNeverMakesARateOutsideTheTargetSoundInside() {
        #expect(answer(.rate, changedDigest { $0.ratePerMin = 99.6 }) == "Just under 100 per minute, below the target of 100 to 120.")
        #expect(answer(.rate, changedDigest { $0.ratePerMin = 120.3 }) == "Just over 120 per minute, above the target of 100 to 120.")
    }

    @Test func depthIsSaidToTheHalfCentimetre() {
        #expect(answer(.depth, changedDigest { $0.depthMM = 44 }) == "4.5 centimetres deep, below the target of 5 to 6.")
        #expect(answer(.depth, changedDigest { $0.depthMM = 52.4 }) == "5 centimetres deep, within the target of 5 to 6.")
        #expect(answer(.depth, changedDigest { $0.depthMM = 57.6 }) == "6 centimetres deep, within the target of 5 to 6.")
        #expect(answer(.depth, changedDigest { $0.depthMM = 10 }) == "1 centimetre deep, below the target of 5 to 6.")
    }

    @Test func roundingNeverMakesAShallowPushSoundDeepEnough() {
        // 48.6 mm rounds to 5 cm, which is the target, but the push is short of it.
        #expect(answer(.depth, changedDigest { $0.depthMM = 48.6 }) == "Just under 5 centimetres deep, below the target of 5 to 6.")
        #expect(answer(.overall, changedDigest { $0.depthMM = 48.6 }) == "112 per minute, within the target. Just under 5 centimetres deep, below the target.")
    }

    @Test func depthAboveTheTargetGetsNoVerdict() {
        // The rules do not judge "too deep", so neither does the answer.
        #expect(answer(.depth, changedDigest { $0.depthMM = 64 }) == "6.5 centimetres deep. The target is 5 to 6.")
        #expect(answer(.overall, changedDigest { $0.depthMM = 64 }) == "112 per minute, within the target. 6.5 centimetres deep.")
    }

    // MARK: - Lock states

    @Test func depthIsNeverSaidWhileItIsStillBeingEstimated() {
        let estimating = changedDigest { $0.lock = .estimating }

        #expect(answer(.depth, estimating) == "Depth is still being estimated.")
        #expect(answer(.overall, estimating) == "112 per minute, within the target. Depth is still being estimated.")
        #expect(answer(.rate, estimating) == "112 per minute, within the target of 100 to 120.")
    }

    @Test func onlyTheRateIsSaidWhenOnlyTheRhythmIsTrusted() {
        let rateOnly = changedDigest { $0.lock = .rateOnly }

        #expect(answer(.depth, rateOnly) == "Depth can't be measured right now, only the rate.")
        #expect(answer(.overall, rateOnly) == "112 per minute, within the target. Depth can't be measured right now.")
        #expect(answer(.rate, rateOnly) == "112 per minute, within the target of 100 to 120.")
    }

    @Test func staleNumbersMeanItCannotSeeTheHands() {
        let stale = changedDigest { $0.stale = true; $0.ageS = 6 }

        for intent in AskIntent.allCases where intent != .unknown {
            #expect(answer(intent, stale) == "I can't see the hands right now.")
        }
        #expect(answer(.unknown, stale) == OfflineAnswerer.topics)
    }

    @Test func aLostSignalMeansItCannotSeeTheHandsEvenIfNotMarkedStale() {
        let lost = changedDigest { $0.lock = .lost }

        for intent in AskIntent.allCases where intent != .unknown {
            #expect(answer(intent, lost) == OfflineAnswerer.cannotSee)
        }
    }

    // MARK: - Missing numbers

    @Test func beforeAnyCompressionsThereIsNothingToReport() {
        let none = changedDigest { $0.count = 0; $0.ratePerMin = nil; $0.depthMM = nil; $0.handsOnFraction = nil }

        for intent in AskIntent.allCases where intent != .unknown {
            #expect(answer(intent, none) == "No compressions yet.")
        }
    }

    @Test func aMissingRateOrDepthIsSaidToBeMissing() {
        #expect(answer(.rate, changedDigest { $0.ratePerMin = nil }) == "The rate needs a few more compressions.")
        #expect(answer(.depth, changedDigest { $0.depthMM = nil }) == "No depth measured yet.")
        #expect(answer(.overall, changedDigest { $0.ratePerMin = nil; $0.depthMM = nil })
            == "The rate needs a few more compressions. No depth measured yet.")
    }

    @Test func valuesThatAreNotRealReadingsAreTreatedAsNotMeasured() {
        #expect(answer(.rate, changedDigest { $0.ratePerMin = .nan }) == "The rate needs a few more compressions.")
        #expect(answer(.rate, changedDigest { $0.ratePerMin = .infinity }) == "The rate needs a few more compressions.")
        #expect(answer(.depth, changedDigest { $0.depthMM = -.infinity }) == "No depth measured yet.")
        #expect(answer(.depth, changedDigest { $0.depthMM = -3 }) == "No depth measured yet.")
        #expect(answer(.pauses, changedDigest { $0.handsOnFraction = .nan }) == "No pause right now.")
        #expect(answer(.pauses, changedDigest { $0.handsOnFraction = 1.4 }) == "No pause right now.")
        #expect(answer(.pauses, changedDigest { $0.isPaused = true; $0.pauseSeconds = .nan }) == "Paused just now.")
    }

    // MARK: - Pauses and count

    @Test func duringAPauseTheRollingNumbersAreNotSaid() {
        let paused = changedDigest { $0.isPaused = true; $0.pauseSeconds = 4.96 }

        #expect(answer(.pauses, paused) == "Paused for 5 seconds.")
        #expect(answer(.overall, paused) == "Paused for 5 seconds.")
        #expect(answer(.rate, paused) == "Paused for 5 seconds, so there is no rate right now.")
        #expect(answer(.depth, paused) == "Paused for 5 seconds, so there is no depth right now.")
        #expect(answer(.count, paused) == "87 compressions so far.")
    }

    @Test func shortPausesAreSaidPlainly() {
        #expect(answer(.pauses, changedDigest { $0.isPaused = true; $0.pauseSeconds = 1.2 }) == "Paused for 1 second.")
        #expect(answer(.pauses, changedDigest { $0.isPaused = true; $0.pauseSeconds = 0.3 }) == "Paused just now.")
    }

    @Test func withoutAShareOfTimeThePauseAnswerIsShort() {
        #expect(answer(.pauses, changedDigest { $0.handsOnFraction = nil }) == "No pause right now.")
    }

    @Test func oneCompressionIsSingular() {
        #expect(answer(.count, changedDigest { $0.count = 1 }) == "1 compression so far.")
    }

    // MARK: - Over every state

    /// Every combination of trust, pause, count and value, for every intent.
    private static func everyDigest() -> [WorldDigest] {
        var all: [WorldDigest] = []
        for lock in LockState.allCases {
            for stale in [false, true] {
                for isPaused in [false, true] {
                    for count in [0, 1, 87] {
                        for rate in [nil, 95, 111.7, 131, Double.nan] as [Double?] {
                            for depth in [nil, 44, 54.2, 64, Double.infinity] as [Double?] {
                                all.append(WorldDigest(lock: lock, count: count, ratePerMin: rate, depthMM: depth,
                                                       depthSpreadMM: 3, isPaused: isPaused, pauseSeconds: 3.2,
                                                       handsOnFraction: 0.8, ageS: stale ? 9 : 0.3, stale: stale))
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    @Test func noAnswerEverMakesAClaimItMustNotMake() {
        let banned = ["breath", "surviv", "alive", "pulse", "heart", "patient", "diagnos", "validated", "clinical",
                      "accura", "first"]
        var wrong: Set<String> = []
        for digest in Self.everyDigest() {
            for intent in AskIntent.allCases {
                let said = answer(intent, digest)
                let lower = said.lowercased()
                if said.isEmpty || !said.hasSuffix(".") || banned.contains(where: lower.contains)
                    || KeywordIntentClassifier.words(in: said).contains("ai") {
                    wrong.insert(said)
                }
            }
        }
        #expect(wrong.isEmpty)
    }

    @Test func untrustedNumbersAreNeverSaid() {
        var wrong: [String] = []
        for digest in Self.everyDigest() {
            for intent in AskIntent.allCases {
                let said = answer(intent, digest)
                if digest.stale || digest.lock == .lost, ![OfflineAnswerer.cannotSee, OfflineAnswerer.topics].contains(said) {
                    wrong.append("stale or lost: \(said)")
                }
                if digest.lock != .locked || digest.isPaused, said.contains("centimetre") {
                    wrong.append("depth not trusted (\(digest.lock), paused \(digest.isPaused)): \(said)")
                }
                if digest.isPaused, said.contains("per minute") {
                    wrong.append("rate during a pause: \(said)")
                }
            }
        }
        #expect(wrong.isEmpty)
    }
}
