import Foundation
@testable import HealthAISim
import RescueVision
import Testing

/// The form score and when a correction is said, on a made-up clock.
struct FormCoachTests {
    private let good = CompressionFeedback(perMinute: 110, armsLocked: true, handsOnChest: true)
    private let bentArms = CompressionFeedback(perMinute: 110, armsLocked: false, handsOnChest: true)

    @Test func noScoreUntilEnoughIsSeen() {
        var coach = FormCoach()
        #expect(coach.update(good, at: 0, canSpeak: true).reading.score == nil)
        #expect(coach.update(good, at: 2, canSpeak: true).reading.score == nil)
        #expect(coach.update(good, at: 3, canSpeak: true).reading.score == 100)
    }

    @Test func scoreIsTheShareOfGoodPushes() {
        var coach = FormCoach()
        for t in stride(from: 0.0, to: 4, by: 0.2) { _ = coach.update(good, at: t, canSpeak: false) }
        for t in stride(from: 4.0, to: 8, by: 0.2) { _ = coach.update(bentArms, at: t, canSpeak: false) }
        #expect(coach.update(bentArms, at: 8, canSpeak: false).reading.score == 49)
    }

    @Test func unseenFramesDontCount() {
        var coach = FormCoach()
        _ = coach.update(good, at: 0, canSpeak: true)
        _ = coach.update(nil, at: 1.5, canSpeak: true)
        #expect(coach.update(good, at: 3, canSpeak: true).reading.score == 100)
    }

    @Test func aCorrectionIsSaidOnceItHoldsThenNotAgainTooSoon() {
        var coach = FormCoach()
        #expect(coach.update(bentArms, at: 0, canSpeak: true).say == nil)
        #expect(coach.update(bentArms, at: 1, canSpeak: true).say == .lockElbows)
        #expect(coach.update(bentArms, at: 5, canSpeak: true).say == nil)
        #expect(coach.update(bentArms, at: 9, canSpeak: true).say == .lockElbows)
    }

    @Test func nothingIsSaidOverTheAppsOwnVoice() {
        var coach = FormCoach()
        _ = coach.update(bentArms, at: 0, canSpeak: false)
        #expect(coach.update(bentArms, at: 1, canSpeak: false).say == nil)
        #expect(coach.update(bentArms, at: 1.2, canSpeak: true).say == .lockElbows)
    }
}
