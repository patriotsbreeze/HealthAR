import Foundation
@testable import HealthAISim
import RescueAudio
import RescueCore
import Testing

/// The rail's alerts: the same words as the chips they replace, one to a line, in the same order.
@MainActor
@Suite struct StatusAlertsTests {
    private func begun() throws -> Fixture {
        let fixture = try Fixture(bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        return fixture
    }

    @Test func aQuietStartHasNone() throws {
        #expect(try begun().coordinator.statusAlerts.isEmpty)
    }

    @Test func aCallSaysToTapSpeaker() throws {
        let fixture = try begun()
        fixture.coordinator.dispatch(.callChanged(active: true))
        #expect(fixture.coordinator.statusAlerts == [
            StatusAlert(text: "Call active, tap Speaker", symbol: "phone.connection.fill", weight: .act),
        ])
    }

    @Test func theAEDTalkingPausesThePhone() throws {
        let fixture = try begun()
        fixture.coordinator.perform(.startCpr)
        fixture.coordinator.seedKeyword(.aedTalking)
        #expect(fixture.coordinator.statusAlerts.map(\.text) == ["AED talking, phone paused"])
        #expect(fixture.coordinator.statusAlerts.first?.weight == .info)
    }

    @Test func aDispatcherHeardClosesTheMic() throws {
        let fixture = try begun()
        fixture.coordinator.seedKeyword(.dispatcherTalking)
        #expect(fixture.coordinator.statusAlerts.map(\.text).contains("Dispatcher heard, mic closed"))
    }

    @Test func noSoundSaysToFollowTheScreen() async throws {
        let fixture = try begun()
        fixture.audio.onStatus?(.outputLost(reason: "route change"))
        try await waitUntil("the loss shows") { fixture.coordinator.audioHealth == .outputLost }
        #expect(fixture.coordinator.statusAlerts.map(\.text) == ["No sound, follow the screen"])
        #expect(fixture.coordinator.statusAlerts.first?.weight == .act)
    }

    @Test func noVoiceSaysToReadTheScreen() async throws {
        let fixture = try begun()
        fixture.audio.onStatus?(.readAloudFailed)
        try await waitUntil("the failure shows") { fixture.coordinator.audioHealth == .voiceFailed }
        #expect(fixture.coordinator.statusAlerts.map(\.text) == ["No voice, read the screen"])
    }

    /// Each stays on its own line, in a fixed order, whatever turned on first.
    @Test func severalKeepTheirOrder() async throws {
        let fixture = try begun()
        fixture.audio.onStatus?(.outputLost(reason: "route change"))
        try await waitUntil("the loss shows") { fixture.coordinator.audioHealth == .outputLost }
        fixture.coordinator.seedKeyword(.dispatcherTalking)
        fixture.coordinator.dispatch(.callChanged(active: true))
        let texts = fixture.coordinator.statusAlerts.map(\.text)
        #expect(texts.first == "Call active, tap Speaker")
        #expect(texts.last == "No sound, follow the screen")
        #expect(Set(texts).count == texts.count, "one line each")
    }
}
