import Testing
@testable import PlumbUI

@Suite struct ReadoutTests {
    @Test func rateIsAWholeNumber() {
        #expect(Readout.rate(109.6) == "110")
        #expect(Readout.rate(104) == "104")
    }

    @Test func elapsedIsMinutesAndSeconds() {
        #expect(Readout.elapsed(0) == "0:00")
        #expect(Readout.elapsed(8.9) == "0:08")
        #expect(Readout.elapsed(400) == "6:40")
        #expect(Readout.elapsed(3_725) == "62:05")
        #expect(Readout.elapsed(-3) == "0:00")
    }

    @Test func percentIsWhole() {
        #expect(Readout.percent(0.666) == "67%")
        #expect(Readout.percent(1) == "100%")
        #expect(Readout.percent(0) == "0%")
    }

    @Test func depthLabelsAreInCentimetresWithNoNeedlessDecimal() {
        #expect(Readout.centimetres(50) == "5\u{00A0}cm")
        #expect(Readout.centimetres(60) == "6\u{00A0}cm")
        #expect(Readout.centimetres(55) == "5.5\u{00A0}cm")
        #expect(Readout.centimetres(50.4) == "5\u{00A0}cm")
    }

    @Test func thePauseCountNeverRunsAhead() {
        #expect(Readout.wholeSeconds(3.99) == "3")
        #expect(Readout.wholeSeconds(4) == "4")
        #expect(Readout.wholeSeconds(-1) == "0")
    }

    @Test func toolTimesKeepOneDecimal() {
        #expect(Readout.seconds(1.24) == "1.2\u{00A0}s")
        #expect(Readout.seconds(0.6) == "0.6\u{00A0}s")
    }

    /// No decimal is shown that the measurement did not have: two seconds is "2 s", never "2.0 s".
    @Test func toolTimesShowNoNeedlessDecimal() {
        #expect(Readout.seconds(2) == "2\u{00A0}s")
        #expect(Readout.seconds(2.04) == "2\u{00A0}s")
        #expect(Readout.seconds(11.96) == "12\u{00A0}s")
        #expect(Readout.seconds(0) == "0\u{00A0}s")
    }

    @Test func aNumberIsNeverSplitFromItsUnit() {
        #expect(!Readout.centimetres(50).contains(" "))
        #expect(!Readout.seconds(2.1).contains(" "))
    }
}
