import Testing
@testable import PlumbCoach

@Suite("Praise ledger")
struct PraiseLedgerTests {
    private let config = CuePolicy.Config()

    /// Feeds one on-target look per compression, a quarter second apart. Returns the counts at which praise was earned.
    private func praisedCounts(_ ledger: inout PraiseLedger, counts: ClosedRange<Int>) -> [Int] {
        counts.filter { count in
            ledger.earn(.onTarget, compressions: count, now: Double(count) * 0.25, config: config)
        }
    }

    @Test("With nothing to fix, a few good compressions earn nothing")
    func nothingOwedNothingGiven() {
        var ledger = PraiseLedger()
        #expect(praisedCounts(&ledger, counts: 1...40).isEmpty)
    }

    @Test("After a correction, praise comes once the required compressions have been on target, and only once")
    func fixIsPraisedOnce() {
        var ledger = PraiseLedger()
        ledger.interrupt()
        #expect(praisedCounts(&ledger, counts: 10...40) == [14])
    }

    @Test("A correction on screen wipes out earlier good work: the fix is counted from after it")
    func interruptRestartsTheCount() {
        var ledger = PraiseLedger()
        #expect(praisedCounts(&ledger, counts: 1...9).isEmpty)
        ledger.interrupt()
        #expect(praisedCounts(&ledger, counts: 10...40) == [14])
    }

    @Test("One off-target look restarts the count towards the fix")
    func offTargetRestartsTheCount() {
        var ledger = PraiseLedger()
        ledger.interrupt()
        #expect(praisedCounts(&ledger, counts: 10...12).isEmpty)
        let earnedOffTarget = ledger.earn(.offTarget, compressions: 13, now: 3.25, config: config)
        #expect(!earnedOffTarget)
        #expect(praisedCounts(&ledger, counts: 14...40) == [18])
    }

    @Test("Praise is on screen for the show time and not a moment longer, and can be taken down early")
    func showWindow() {
        var ledger = PraiseLedger()
        ledger.interrupt()
        #expect(praisedCounts(&ledger, counts: 10...14) == [14])
        let givenAt = 14 * 0.25
        #expect(ledger.isShowing(at: givenAt))
        #expect(ledger.isShowing(at: givenAt + 1.99))
        #expect(!ledger.isShowing(at: givenAt + 2))

        ledger.hide()
        #expect(!ledger.isShowing(at: givenAt))
    }
}
