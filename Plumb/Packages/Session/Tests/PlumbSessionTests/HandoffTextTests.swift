import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct HandoffTextTests {
    private func stats(compressions: Int = 40, durationS: Double, pauses: [Double] = [],
                       started: Date? = fixtureStart) -> HandoffStats {
        HandoffStats(startedWallClock: started, durationS: durationS, compressions: compressions,
                     pauses: pauses.enumerated().map { HandoffStats.Pause(start: Double($0.offset) * 20, durationS: $0.element) },
                     longestPauseS: pauses.max())
    }

    @Test func headlineWithNoPauses() {
        let line = HandoffText.headline(stats(durationS: 45), timeZone: .gmt)
        #expect(line == "CPR started 14:02. Ran 45 s. No pauses.")
    }

    @Test func headlineWithOnePause() {
        let line = HandoffText.headline(stats(durationS: 45, pauses: [9]), timeZone: .gmt)
        #expect(line == "CPR started 14:02. Ran 45 s. 1 pause of 9 s.")
    }

    @Test func headlineWithManyPausesOverAMinute() {
        let line = HandoffText.headline(stats(durationS: 400, pauses: [4, 9, 6]), timeZone: .gmt)
        #expect(line == "CPR started 14:02. Ran 6 min 40 s. 3 pauses, longest 9 s.")
    }

    @Test func headlineWithNoCompressions() {
        let line = HandoffText.headline(stats(compressions: 0, durationS: 45), timeZone: .gmt)
        #expect(line == "No compressions recorded.")
    }

    @Test func headlineNeverShowsDecimals() {
        let line = HandoffText.headline(stats(durationS: 399.6, pauses: [8.6, 3.2]), timeZone: .gmt)
        #expect(line == "CPR started 14:02. Ran 6 min 40 s. 2 pauses, longest 9 s.")
    }

    @Test func headlineUsesTheGivenTimeZoneAndA24HourClock() throws {
        let india = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60))
        let newYork = try #require(TimeZone(secondsFromGMT: -5 * 3600))
        #expect(HandoffText.headline(stats(durationS: 45), timeZone: india).hasPrefix("CPR started 19:32."))
        #expect(HandoffText.headline(stats(durationS: 45), timeZone: newYork).hasPrefix("CPR started 09:02."))
    }

    @Test func headlineWithoutAStartTimeLeavesItOut() {
        let line = HandoffText.headline(stats(durationS: 45, started: nil), timeZone: .gmt)
        #expect(line == "Ran 45 s. No pauses.")
    }

    @Test(arguments: [
        (45.0, "45 s"), (400, "6 min 40 s"), (420, "7 min"), (59.4, "59 s"), (59.6, "1 min"),
        (60, "1 min"), (0, "0 s"), (0.4, "0 s"), (-12, "0 s"), (3725, "62 min 5 s"),
        (Double.nan, "0 s"), (-Double.infinity, "0 s"),
    ])
    func durationIsWholeMinutesAndSeconds(seconds: Double, expected: String) {
        #expect(HandoffText.duration(seconds) == expected)
    }

    @Test func percentIsWholeOrNotRecorded() {
        #expect(HandoffText.percent(0.83) == "83%")
        #expect(HandoffText.percent(0.826) == "83%")
        #expect(HandoffText.percent(0) == "0%")
        #expect(HandoffText.percent(1) == "100%")
        #expect(HandoffText.percent(1.2) == "100%")
        #expect(HandoffText.percent(-0.1) == "0%")
        #expect(HandoffText.percent(nil) == "not recorded")
        #expect(HandoffText.percent(.nan) == "not recorded")
    }

    @Test(arguments: [
        (46.0, 54.0, "4.5 to 5.5 cm"),
        (47, 58, "4.5 to 6 cm"),
        (42.8, 60.6, "4.5 to 6 cm"),
        (38, 43, "4 to 4.5 cm"),
        // Both ends round to the same half centimetre: the range opens to the marks either side.
        (38, 41, "3.5 to 4.5 cm"),
        (51, 52, "5 to 5.5 cm"),
        (53, 54, "5 to 5.5 cm"),
        (56, 57, "5.5 to 6 cm"),
        // One exact value still becomes a range, one step wide.
        (50, 50, "5 to 5.5 cm"),
        (52.4, 52.4, "5 to 5.5 cm"),
    ])
    func depthRangeRoundsToHalfCentimetres(lowMM: Double, highMM: Double, expected: String) {
        let stats = HandoffStats(depthMM: (lowMM + highMM) / 2, depthLowMM: lowMM, depthHighMM: highMM)
        #expect(HandoffText.depthRange(stats) == expected)
    }

    @Test func depthRangeIsNeverASingleValue() throws {
        for lowMM in stride(from: 20.0, through: 80.0, by: 0.7) {
            for width in [0.0, 0.3, 1, 2.5, 4.9, 5, 12] {
                let stats = HandoffStats(depthMM: lowMM, depthLowMM: lowMM, depthHighMM: lowMM + width)
                let text = try #require(HandoffText.depthRange(stats))
                let parts = text.split(separator: " ")
                #expect(parts.count == 4 && parts[1] == "to" && parts[3] == "cm", "\(text)")
                let low = try #require(Double(parts[0]))
                let high = try #require(Double(parts[2]))
                #expect(low < high, "\(text)")
                #expect((low * 2).rounded() == low * 2 && (high * 2).rounded() == high * 2, "\(text)")
            }
        }
    }

    @Test func depthRangeIsNilWhenDepthWasNotRecorded() {
        #expect(HandoffText.depthRange(HandoffStats(compressions: 12)) == nil)
    }

    @Test func depthRangeFromATypicalDepthAloneIsStillARange() {
        #expect(HandoffText.depthRange(HandoffStats(depthMM: 52)) == "5 to 5.5 cm")
    }
}
