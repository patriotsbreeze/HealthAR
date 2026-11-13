import Foundation
@testable import HealthAISim
import RescueCore
import RescueLive
import Testing

/// Keeps `evals/utterances.json` honest: each expected call must get through the real router, and
/// the real engine must do with it what the row says. It says nothing about the model itself.
@MainActor
@Suite struct EvalSetTests {
    private struct EvalSet: Decodable {
        var utterances: [Row]
    }

    private struct Row: Decodable {
        struct Result: Decodable {
            var moves_to: String?
            var rejected: String?
            var plays: String?
            var adds_resources: [String]?
            var logs_note: String?
            var holds_model_speech: Bool?
            var pauses_audio: Bool?
            var locates: String?
        }

        var id: Int
        var state: String
        var utterance: String
        var expected_tool: String
        var expected_args: JSONValue
        var engine_result: Result
    }

    private func evalSet() throws -> EvalSet {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "evals/utterances.json"))
        return try JSONDecoder().decode(EvalSet.self, from: data)
    }

    @Test func thereAreTwentyAndEachCoversARealState() throws {
        let rows = try evalSet().utterances
        #expect(rows.count == 20)
        #expect(Set(rows.map(\.id)).count == 20)
        let states = Set(try shippedBundle().definition.states.map(\.id))
        #expect(Set(rows.map(\.state)).isSubset(of: states))
    }

    @Test func everyExpectedCallDoesWhatTheRowSays() throws {
        for row in try evalSet().utterances {
            let label = "row \(row.id): \(row.utterance)"
            let fixture = try Fixture(canLocate: false)
            let coordinator = fixture.coordinator
            coordinator.beginRescue()
            if coordinator.state.stateID != row.state { coordinator.force(stateID: row.state) }
            fixture.audio.clearCalls()
            let before = coordinator.state

            guard case var .object(args) = row.expected_args else {
                Issue.record("\(label): args are not an object")
                continue
            }
            args["state_version"] = .number(Double(coordinator.state.version))
            if row.expected_tool == "report_finding" {
                args["confidence"] = "high"
                if args["source"] == nil { args["source"] = "heard" }
            }

            let router = ToolRouter(clock: fixture.clock.reader)
            let routed = router.route(RealtimeFunctionCall(id: "eval", name: row.expected_tool, args: .object(args)))
            let proposal = try #require(routed.proposal, "\(label): the router refused it")
            coordinator.dispatch(.model(proposal))

            let result = row.engine_result
            let state = coordinator.state
            if let target = result.moves_to {
                #expect(state.stateID == target, "\(label)")
            } else {
                #expect(state.stateID == before.stateID, "\(label)")
            }
            if let reason = result.rejected {
                #expect(fixture.logDetails(.proposalRejected).last?.hasSuffix(reason) == true, "\(label)")
            }
            if let phrase = result.plays {
                #expect(fixture.audio.played.contains(phrase), "\(label)")
            }
            if let resources = result.adds_resources {
                #expect(Set(resources).isSubset(of: Set(state.resources.map(\.rawValue))), "\(label)")
            }
            if let note = result.logs_note {
                #expect(fixture.logDetails(.modelNote).contains(note), "\(label)")
            }
            if result.holds_model_speech == true {
                #expect(state.modelSpeechHoldUntil != nil, "\(label)")
            }
            if result.pauses_audio == true {
                #expect(fixture.audio.calls.contains(.pause(8)), "\(label)")
                #expect(!fixture.audio.metronome.contains(false), "\(label)")
            }
            if result.locates != nil {
                #expect(fixture.vision.applied.contains(.locate(.aed)), "\(label)")
            }
        }
    }
}
