import Testing
@testable import PlumbUI

/// The press behind `HoldToConfirm`: whoever is told a press began is told once that it ended, even when
/// the release never comes because the control left the screen, as "Hold to ask" does when "Hand over"
/// takes its place under a held finger.
@Suite struct HoldPressTests {
    /// Runs `steps` on a fresh press, `true` for the finger going down and `false` for an end of any
    /// kind, and gives back which of them began or ended a press.
    private func run(_ steps: [Bool]) -> [Bool] {
        var press = HoldPress()
        return steps.map { $0 ? press.begin() : press.end() }
    }

    @Test func aPressBeginsOnceHoweverLongTheFingerStaysDown() {
        #expect(run([true, true, true]) == [true, false, false])
    }

    @Test func aPressEndsOnceWhateverEndsIt() {
        // The finger comes up, and later the control leaves the screen: one end.
        #expect(run([true, false, false]) == [true, true, false])
    }

    @Test func aControlLeavingTheScreenWhileHeldEndsThePress() {
        // The release never comes; leaving the screen ends it instead, and a fresh press can begin.
        #expect(run([true, true, false, true]) == [true, false, true, true])
    }

    @Test func nothingEndsThatNeverBegan() {
        #expect(run([false]) == [false])
        var press = HoldPress()
        _ = press.begin()
        _ = press.end()
        #expect(!press.isHeld)
    }
}
