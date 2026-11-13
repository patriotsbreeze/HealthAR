import Testing
@testable import PlumbCoach

@Suite("Fault latch")
struct FaultLatchTests {
    /// Feeds a fresh latch a series of (margin, time) readings, with a 3-unit dead band and a 2.5 s
    /// persistence window. Returns whether the fault was believed after each one.
    private func believed(after readings: [(margin: Double, at: Double)]) -> [Bool] {
        var latch = FaultLatch()
        return readings.map { reading in
            latch.observe(outsideBy: reading.margin, deadBand: 3, persistS: 2.5, now: reading.at)
            return latch.isConfirmed
        }
    }

    @Test("True on two looks a full window apart is enough; anything sooner is not")
    func twoLooksAWindowApart() {
        #expect(believed(after: [(10, 0), (10, 2.4), (10, 2.5)]) == [false, false, true])
    }

    @Test("A sighting that is not repeated within the window is forgotten")
    func staleSightingLapses() {
        // The second look comes too late to back up the first, so it starts a spell of its own.
        // Times are multiples of a quarter second so the subtraction is exact.
        #expect(believed(after: [(10, 0), (10, 2.75), (10, 5)]) == [false, false, false])
        #expect(believed(after: [(10, 0), (10, 2.75), (10, 5.25)]) == [false, false, true])
    }

    @Test("The fault is only ever confirmed on a look where it is actually present")
    func notConfirmedFromInsideTheDeadBand() {
        #expect(believed(after: [(10, 0), (1, 3), (-1, 6)]) == [false, false, false])
    }

    @Test("Once confirmed it holds through the dead band and clears only when back inside by the full band")
    func holdsUntilClearlyFixed() {
        let readings: [(margin: Double, at: Double)] = [(10, 0), (10, 2.5), (3, 3), (0, 4), (-2.9, 5), (-3, 6)]
        #expect(believed(after: readings) == [false, true, true, true, true, false])
    }

    @Test("Clearing forgets the suspicion too, so the next spell starts from nothing")
    func clearingStartsOver() {
        #expect(believed(after: [(10, 0), (-3, 1), (10, 2.5), (10, 5)]) == [false, false, false, true])
    }

    @Test("Exactly a dead band outside is not yet a fault; a hair more is")
    func tripIsStrict() {
        #expect(believed(after: [(3, 0), (3, 10)]) == [false, false])
        #expect(believed(after: [(3.01, 0), (3.01, 2.5)]) == [false, true])
    }
}
