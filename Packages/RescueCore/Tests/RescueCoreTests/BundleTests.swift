import Foundation
import Testing
@testable import RescueCore

@Suite struct BundleTests {
    @Test func everyReferenceResolves() throws {
        let bundle = try loadBundle()
        let definition = bundle.definition
        let stateIDs = Set(definition.states.map(\.id))
        let phraseIDs = Set(bundle.phrases.phrases.map(\.id))

        #expect(stateIDs.count == definition.states.count, "duplicate state id")
        #expect(phraseIDs.count == bundle.phrases.phrases.count, "duplicate phrase id")
        #expect(stateIDs.contains(definition.initialState))
        #expect(Set(definition.speechGate.openStates).isSubset(of: stateIDs))
        #expect(phraseIDs.contains(definition.loweringReportPhrase))
        #expect(Set(definition.keepQueuedPhrases).isSubset(of: phraseIDs))
        #expect(Set(definition.resourceHints.values).isSubset(of: phraseIDs))
        #expect(Set(definition.correctionPhrases.values).isSubset(of: phraseIDs))

        for state in definition.states {
            for phrase in state.entryPhrases + state.allowedSay + state.repeating.map(\.phrase) {
                #expect(phraseIDs.contains(phrase), "\(state.id) references unknown phrase \(phrase)")
            }
            for transition in state.transitions {
                #expect(stateIDs.contains(transition.to), "\(state.id) goes to unknown \(transition.to)")
                for phrase in transition.phrases ?? [] { #expect(phraseIDs.contains(phrase)) }
            }
            if let timeout = state.timeout {
                #expect(stateIDs.contains(timeout.to))
                if let rule = timeout.ifBreathsAtLeast { #expect(stateIDs.contains(rule.to)) }
            }
            if let target = state.afterPads { #expect(stateIDs.contains(target)) }
            #expect(!state.citation.isEmpty, "\(state.id) has no citation")
        }
    }

    @Test func transitionKeysAreRealEvents() throws {
        let bundle = try loadBundle()
        let human = Set(HumanAction.allCases.map { "human.\($0.rawValue)" })
        let model = Set(Finding.allCases.map { "model.\($0.rawValue)" })
        for state in bundle.definition.states {
            for transition in state.transitions {
                #expect(human.contains(transition.on) || model.contains(transition.on), "\(state.id): \(transition.on)")
            }
        }
    }

    @Test func everyCategoryHasACorrectionPhrase() throws {
        let bundle = try loadBundle()
        for category in SentinelFlag.Category.allCases {
            #expect(bundle.definition.correctionPhrases[category.rawValue] != nil, "\(category)")
        }
    }

    @Test func phrasesFitAFiveSecondClip() throws {
        let bundle = try loadBundle()
        for phrase in bundle.phrases.phrases {
            let words = phrase.text.split(separator: " ").count
            #expect(words <= 14, "\(phrase.id) has \(words) words")
            #expect(!phrase.citation.isEmpty)
        }
    }

    /// Pins what the required phrases say, so an edit can't quietly reverse one. A reviewer's sign-off
    /// on `clinical/` is still what makes the wording right. These only catch it changing meaning.
    @Test(arguments: [
        ("ask_responsive", ["shoulders", "shout", "responding"], ["wait"]),
        ("ask_breathing", ["breathing normally", "gasping does not count"], ["wait"]),
        ("gasping_not_normal", ["not normal", "not breathing"], ["is normal"]),
        ("watch_intro", ["call 911", "mark breath"], ["tap the screen"]),
        ("confirm_by_tap", ["tap yes", "start cpr"], ["do not"]),
        ("call_911", ["call 911", "speaker"], ["wait", "do not call"]),
        ("roll_flat", ["on their back", "firm surface"], ["side", "stomach"]),
        ("hands_center", ["heel of one hand", "center of the chest"], ["stomach"]),
        ("start_compressions", ["push hard", "do not stop"], ["wait", "ambulance"]),
        ("push_hard", ["push hard", "two inches"], ["stop", "gently"]),
        ("switch_compressors", ["switch", "short"], ["stop"]),
        ("no_pulse_check", ["do not check", "keep pushing"], ["check for a pulse first"]),
        ("keep_going", ["keep going", "do not stop"], ["may stop"]),
        ("assign_helper", ["call 911", "find an aed"], ["stop"]),
        ("aed_spotted", ["aed", "keep pushing"], ["stop"]),
        ("aed_on", ["turn the aed on", "keep pushing"], ["remove"]),
        ("pads_place", ["bare the chest", "pads"], ["stop"]),
        ("aed_authority", ["follow the aed", "stay clear"], ["keep pushing"]),
        ("aed_reminder", ["start pushing", "aed"], ["stop"]),
        ("resume_compressions", ["start pushing"], ["stop"]),
        ("responsive_card", ["stay with them", "call 911"], ["do not call"]),
        ("responsive_recheck", ["still responding", "not responding now"], ["fine"]),
        ("special_card", ["call 911", "dispatcher"], ["cpr"]),
        ("special_recheck", ["call 911", "dispatcher", "back"], ["cpr"]),
        ("correct_pulse", ["correction", "do not check"], ["check his pulse"]),
        ("correct_stop", ["correction", "do not stop"], ["may stop", "can stop"]),
        ("correct_dose", ["correction", "ignore"], ["give"]),
        ("correct_death", ["correction", "keep going", "only ems"], ["dead"]),
        ("correct_reassure", ["correction", "not breathing"], ["fine"]),
    ])
    func requiredPhrasesSayWhatTheyMust(id: String, required: [String], forbidden: [String]) throws {
        let text = try #require(try loadBundle().text(forPhrase: id), "\(id) is missing").lowercased()
        for words in required { #expect(text.contains(words), "\(id) lost \"\(words)\"") }
        for words in forbidden { #expect(!text.contains(words), "\(id) now says \"\(words)\"") }
    }

    @Test func nothingShippedTripsTheValidators() throws {
        for phrase in try loadBundle().phrases.phrases {
            #expect(TranscriptValidator.check(phrase.text).isEmpty, "\(phrase.id)")
        }
    }

    @Test func speechGateIsExactlyTheApprovedList() throws {
        let open = try loadBundle().definition.speechGate.openStates
        // SAFETY.md and docs/plan.md: intake, placing hands, resource scan, and handoff. Widening
        // this is a decision for the plan first.
        #expect(Set(open) == ["intake_responsive", "intake_breathing", "place_hands", "resource_scan", "handoff"])
    }

    @Test func frameUplinkIsExactlyTheseStates() throws {
        let states = try loadBundle().definition.states.filter(\.frameUplink).map(\.id)
        #expect(Set(states) == ["intake_responsive", "intake_breathing", "resource_scan"])
    }

    /// S1 isn't built. Nothing may ask for rate feedback with no measurement behind it.
    @Test func noRatePhraseCanBeAskedFor() throws {
        let definition = try loadBundle().definition
        for state in definition.states {
            for phrase in state.allowedSay + state.entryPhrases + state.repeating.map(\.phrase) {
                #expect(!phrase.hasPrefix("rate_"), "\(state.id) can play \(phrase)")
            }
        }
    }

    /// A state with no timeout would stop here forever, so each exit is pinned.
    @Test func everyCprStateCanBeLeftOnlyTheseWays() throws {
        let definition = try loadBundle().definition
        for state in definition.states where state.kind == .cpr {
            #expect(state.transition(on: "human.ems_arrived")?.to == "handoff", "\(state.id)")
            #expect(state.transition(on: "human.patient_moving")?.to == "watch_breathing", "\(state.id)")
        }
    }

    /// The setup steps wait for a tap and say their line again every 10 s. Start CPR is always one tap.
    @Test func setupStepsWaitAndRepeatTheirLine() throws {
        let definition = try loadBundle().definition
        for (id, line) in [("call_911", "call_911"), ("position_patient", "roll_flat"), ("place_hands", "hands_center")] {
            let state = try #require(definition.states.first { $0.id == id })
            #expect(state.timeout == nil, "\(id)")
            #expect(state.repeating.map(\.phrase) == [line], "\(id)")
            #expect(state.repeating.map(\.everySeconds) == [10], "\(id)")
            #expect(state.transition(on: "human.start_cpr")?.to == "compressions", "\(id)")
        }
    }

    @Test func theAdultGateIsOnBothIntakeQuestions() throws {
        let definition = try loadBundle().definition
        for id in ["intake_responsive", "intake_breathing"] {
            let state = try #require(definition.states.first { $0.id == id })
            #expect(state.transition(on: "human.not_adult")?.to == "special_patient", "\(id)")
        }
    }

    @Test func contentStaysMarkedDraftUntilReviewed() throws {
        let bundle = try loadBundle()
        if bundle.definition.reviewer == nil { #expect(bundle.definition.status == "DRAFT") }
        if bundle.phrases.reviewer == nil { #expect(bundle.phrases.status == "DRAFT") }
    }

    @Test func toolContractMatchesEnums() throws {
        let url = repoRoot().appendingPathComponent("contracts/tools.v1.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let tools = try #require(root["function_declarations"] as? [[String: Any]])
        func properties(_ name: String) throws -> [String: [String: Any]] {
            let tool = try #require(tools.first { $0["name"] as? String == name })
            let parameters = try #require(tool["parameters"] as? [String: Any])
            return try #require(parameters["properties"] as? [String: [String: Any]])
        }

        #expect(Set(tools.compactMap { $0["name"] as? String }) == ["report_finding", "report_resources", "say", "locate_object", "log_event", "report_scene"])
        #expect(Set(try properties("report_finding")["kind"]?["enum"] as? [String] ?? []) == Set(Finding.arrestCases.map(\.rawValue)))
        let items = try properties("report_resources")["items"]?["items"] as? [String: Any]
        #expect(Set(items?["enum"] as? [String] ?? []) == Set(Resource.allCases.map(\.rawValue)))
        #expect(Set(try properties("locate_object")["label"]?["enum"] as? [String] ?? []) == Set(LocatableObject.allCases.map(\.rawValue)))
        #expect(Set(try properties("log_event")["kind"]?["enum"] as? [String] ?? []) == Set(ModelNote.allCases.map(\.rawValue)))
    }

    @Test func coreHasNoNetworkOrMediaCode() throws {
        let sources = repoRoot().appendingPathComponent("Packages/RescueCore/Sources/RescueCore")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                #expect(line == "import Foundation", "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("URLSession"), "\(file.lastPathComponent) uses URLSession")
        }
    }
}
