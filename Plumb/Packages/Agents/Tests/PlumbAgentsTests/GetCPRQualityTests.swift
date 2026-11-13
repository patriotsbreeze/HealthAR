import Foundation
import PlumbContracts
import Testing
@testable import PlumbAgents

/// An ordinary digest with a few fields changed.
private func changed(_ change: (inout WorldDigest) -> Void) -> WorldDigest {
    var digest = freshDigest()
    change(&digest)
    return digest
}

@Suite struct GetCPRQualityTests {
    @Test func summaryStatesTheNumbersAndTheirAge() async throws {
        let digest = try await GetCPRQuality(read: { freshDigest() }).run(.init())

        #expect(digest.spanSummary == "87 compressions, 112 per minute, 54 mm deep, measured 0.4 seconds ago.")
    }

    @Test func summarySaysWhenTheNumbersAreStale() async throws {
        let stale = changed { $0.stale = true; $0.ageS = 6.24 }

        let digest = try await GetCPRQuality(read: { stale }).run(.init())

        #expect(digest.spanSummary == "The numbers are stale, last measured 6.2 seconds ago, so the hands cannot be seen right now.")
    }

    @Test func staleNumbersAreWithheldFromTheModel() async throws {
        let stale = changed { $0.stale = true }

        let digest = try await GetCPRQuality(read: { stale }).run(.init())

        #expect(digest.stale)
        #expect(digest.ratePerMin == nil)
        #expect(digest.depthMM == nil)
        #expect(digest.depthSpreadMM == nil)
        #expect(digest.handsOnFraction == nil)
    }

    @Test func depthIsWithheldUnlessTheLockIsFull() async throws {
        let estimating = changed { $0.lock = .rateOnly }

        let digest = try await GetCPRQuality(read: { estimating }).run(.init())

        #expect(digest.ratePerMin == 112)
        #expect(digest.depthMM == nil)
        #expect(digest.spanSummary.contains("depth not trusted"))
    }

    @Test func nothingIsReportedWhenTheSignalIsLost() async throws {
        let lost = changed { $0.lock = .lost }

        let digest = try await GetCPRQuality(read: { lost }).run(.init())

        #expect(digest.ratePerMin == nil)
        #expect(digest.depthMM == nil)
    }

    @Test func numbersAreRoundedToWhatCanBeSaidAloud() async throws {
        let digest = try await GetCPRQuality(read: { freshDigest() }).run(.init())

        #expect(digest.ratePerMin == 112)
        #expect(digest.depthMM == 54)
        #expect(digest.depthSpreadMM == 3)
        #expect(digest.handsOnFraction == 0.87)
        #expect(digest.ageS == 0.4)
    }

    @Test func aPauseIsPartOfTheSummary() async throws {
        let paused = changed { $0.isPaused = true; $0.pauseSeconds = 4.96 }

        let digest = try await GetCPRQuality(read: { paused }).run(.init())

        #expect(digest.spanSummary.contains("paused for 5.0 seconds"))
    }

    @Test func throughTheConductorTheResultIsTheDigestAndTheSpanCarriesTheSummary() async throws {
        let logged = Locked<[LogEntry.Body]>([])
        let conductor = Conductor(now: { 3 }, sink: { body in logged.with { $0.append(body) } })
        await conductor.register(GetCPRQuality(read: { freshDigest() }))

        let outcome = await conductor.call(name: "get_cpr_quality", argumentsJSON: Data("{}".utf8))

        let digest = try JSONDecoder().decode(WorldDigest.self, from: try #require(outcome.resultJSON))
        #expect(digest.count == 87)
        #expect(digest.ratePerMin == 112)
        #expect(logged.current == [.toolCall(name: "get_cpr_quality", durationS: 0, ok: true,
                                             summary: "87 compressions, 112 per minute, 54 mm deep, measured 0.4 seconds ago.")])
    }
}
