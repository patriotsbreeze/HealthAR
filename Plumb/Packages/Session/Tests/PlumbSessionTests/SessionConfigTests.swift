import Testing
@testable import PlumbSession

@Suite struct SessionConfigTests {
    /// The shipped numbers, written out once more so a change to any of them is a visible decision.
    @Test func theShippedValuesAreTheDocumentedOnes() {
        let config = SessionConfig.standard
        #expect(config == SessionConfig())
        #expect(config.bucketS == 10)
        #expect(config.maxBuckets == 720)
        #expect(config.sliverShare == 1e-9)
        #expect(config.depthLowQuantile == 0.10)
        #expect(config.depthHighQuantile == 0.90)
        #expect(config.depthStepCM == 0.5)
        #expect(config.sessionRateMinIntervals == 1)
        #expect(config.citedRateMinIntervals == 2)
        #expect(config.staleAfterS == 2)
        #expect(config.maxSentences == 3)
        #expect(config.maxWords == 30)
        #expect(config.wholeWordStemLength == 3)
        #expect(config.countNounReach == 2)
        #expect(config.roundingSlack == 1e-6)
    }
}
