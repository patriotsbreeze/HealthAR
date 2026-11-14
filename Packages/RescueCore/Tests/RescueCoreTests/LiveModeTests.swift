import Foundation
import Testing
@testable import RescueCore

@Suite struct LiveModeTests {
    private func merged() throws -> Session {
        Session(engine: ProtocolEngine(bundle: try loadMergedBundle()))
    }

    // MARK: - Which session a state needs

    @Test func everyStateAsksForTheModeItsKindSays() throws {
        for state in try loadMergedBundle().definition.states {
            switch state.kind {
            case .intake, .watch, .setup, .cpr: #expect(state.kind.liveMode == .arrest, "\(state.id)")
            case .triage, .flow: #expect(state.kind.liveMode == .awake, "\(state.id)")
            case .card: #expect(state.kind.liveMode == nil, "\(state.id)")
            }
        }
    }

    @Test func eachModeChecksTheLinesThatAreWrongForIt() {
        #expect(LiveMode.arrest.profile == .arrest)
        #expect(LiveMode.awake.profile == .awake)
    }

    private func declaredFindings(_ file: String) throws -> Set<String> {
        let url = repoRoot().appendingPathComponent("contracts/\(file)")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let tools = try #require(root["function_declarations"] as? [[String: Any]])
        let tool = try #require(tools.first { $0["name"] as? String == "report_finding" })
        let parameters = try #require(tool["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: [String: Any]])
        return Set(try #require(properties["kind"]?["enum"] as? [String]))
    }

    /// The router refuses by this list, and the model reads the contract, so they have to agree.
    @Test(arguments: [(LiveMode.arrest, "tools.v1.json"), (LiveMode.awake, "tools.awake.v1.json")])
    func eachModeAllowsExactlyWhatItsContractDeclares(mode: LiveMode, file: String) throws {
        #expect(Set(mode.allowedFindings.map(\.rawValue)) == (try declaredFindings(file)))
    }

    // MARK: - The re-ask hold

    private func triage() throws -> Session {
        var session = try merged()
        session.human(.yes)
        #expect(session.state.stateID == "triage")
        return session
    }

    @Test func aReAskPlaysOnTimeWithTheAIQuiet() throws {
        var session = try triage()
        session.advance(29.8)
        #expect(!session.phrases.contains("triage_recheck"))
        session.advance(0.4)
        #expect(session.phrases.contains("triage_recheck"))
    }

    @Test func aReAskWaitsForTheAIsTurnToEnd() throws {
        var session = try triage()
        session.send(.modelTurn(active: true))
        session.advance(30.2)
        #expect(!session.phrases.contains("triage_recheck"), "a local phrase would cut the answer off")
        session.advance(3)
        #expect(!session.phrases.contains("triage_recheck"))

        session.send(.modelTurn(active: false))
        session.advance(0.2)
        #expect(session.phrases.contains("triage_recheck"))
    }

    @Test func aReAskWaitsNoMoreThanEightSeconds() throws {
        var session = try triage()
        session.send(.modelTurn(active: true))
        session.advance(37.8)
        #expect(!session.phrases.contains("triage_recheck"))
        session.advance(0.4)
        #expect(session.phrases.contains("triage_recheck"), "a turn that never ends can't hold it off")

        // And the next one is due a full period on, not at once.
        session.advance(0.4)
        #expect(!session.phrases.contains("triage_recheck"))
    }

    @Test func aHoldNeverStopsATimeoutOrAnEntryPhrase() throws {
        var session = try merged()
        session.human(.yes)
        session.human(.triageChest)
        session.human(.done)
        session.human(.no)
        #expect(session.state.stateID == "chest_aspirin")
        session.send(.modelTurn(active: true))
        session.advance(15.2)
        #expect(session.state.stateID == "chest_wait")
        #expect(session.phrases.contains("chest_wait_line"))
    }

    /// The arrest path's prompts run as they always have.
    @Test func noHoldOffTheAwakeStates() throws {
        var session = Session(engine: ProtocolEngine(bundle: try loadBundle()))
        session.human(.startCpr)
        session.send(.modelTurn(active: true))
        #expect(!session.state.modelTurnActive)
        session.advance(60.2)
        #expect(session.phrases.contains("push_hard"))

        var card = Session(engine: ProtocolEngine(bundle: try loadBundle()))
        card.human(.yes)
        #expect(card.state.stateID == "responsive_patient")
        card.send(.modelTurn(active: true))
        card.advance(30.2)
        #expect(card.phrases.contains("responsive_recheck"))
    }

    @Test func leavingTheAwakeStatesEndsTheTurn() throws {
        var session = try triage()
        session.send(.modelTurn(active: true))
        session.human(.triageChest)
        #expect(session.state.modelTurnActive, "the same session is still talking")
        session.human(.patientUnresponsive)
        #expect(session.state.stateID == "intake_breathing")
        #expect(!session.state.modelTurnActive, "that session is gone, and no end is coming for this turn")
    }

    @Test func aTurnEventMovesNothing() throws {
        var session = try triage()
        let before = session.state
        session.send(.modelTurn(active: true))
        session.send(.modelTurn(active: false))
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
    }

    // MARK: - Frames

    @Test func onlyAnAwakeStateSendsFramesOnBurstsAlone() throws {
        let bundle = try loadMergedBundle()
        let engine = ProtocolEngine(bundle: bundle)
        for definition in bundle.definition.states {
            var state = engine.start(at: 0).state
            state.stateID = definition.id
            #expect(engine.policy(for: state, at: 0).frameBurstsOnly == definition.kind.isAwake, "\(definition.id)")
        }
    }

    // MARK: - Briefs

    /// Exactly what an arrest session has always been sent, field for field, on every path.
    @Test func anArrestBriefIsByteForByteWhatItWas() throws {
        let brief = StateBrief(
            version: 7,
            stateID: "compressions",
            allowedSay: ["keep_going"],
            modelSpeechOpen: false,
            recentlyPlayed: ["a", "b"],
            resources: ["aed"],
            elapsedSeconds: 12
        )
        #expect(brief.text == """
        STATE BRIEF version=7 state=compressions elapsed_seconds=12
        you_may_speak=false
        allowed_say=[keep_going]
        recently_played=[a,b]
        resources=[aed]
        """)
    }

    @Test func arrestStatesSetNoneOfTheAwakeFields() throws {
        let bundle = try loadBundle()
        let engine = ProtocolEngine(bundle: bundle)
        var state = engine.start(at: 0).state
        state.aspirinAdvised = true
        state.aspirinRuledOut = true
        for definition in bundle.definition.states {
            let brief = engine.brief(for: state, definition: definition, at: 0)
            #expect(brief.mode == nil && brief.flow == nil && brief.stepText == nil, "\(definition.id)")
            #expect(!brief.text.contains("aspirin"), "\(definition.id)")
            #expect(!brief.text.contains("mode="), "\(definition.id)")
        }
    }

    @Test func anAwakeBriefSaysTheStepTheFlowAndTheAspirin() throws {
        let bundle = try loadMergedBundle()
        let engine = ProtocolEngine(bundle: bundle)
        var session = Session(engine: engine)
        session.human(.yes)
        session.human(.triageChest)

        let brief = try #require(lastBrief(session))
        #expect(brief.stateID == "chest_call")
        #expect(brief.text.contains("mode=awake"))
        #expect(brief.text.contains("flow=possible_heart_attack"))
        #expect(brief.text.contains("step=\(bundle.text(forPhrase: "chest_possible") ?? "?")"))
        #expect(brief.text.contains("aspirin=not_asked"))
    }

    @Test func theModelIsNeverToldTheAmount() throws {
        var session = try merged()
        session.human(.yes)
        session.human(.triageChest)
        session.human(.done)
        session.human(.no)
        let dose = try #require(lastBrief(session))
        #expect(dose.stateID == "chest_aspirin")
        #expect(!dose.text.contains("mg"))
        #expect(dose.text.contains("step=none"))
        #expect(dose.text.contains("aspirin=advised"))

        session.human(.done)
        let wait = try #require(lastBrief(session))
        #expect(wait.stateID == "chest_wait")
        #expect(wait.text.contains("aspirin=advised"), "recently_played would have let this go")
    }

    /// On every way to the wait, so "the app will tell you how much" has no route to look true.
    @Test func theBriefSaysWhereAspirinStands() throws {
        func atTheCheck() throws -> Session {
            var session = try merged()
            session.human(.yes)
            session.human(.triageChest)
            session.human(.done)
            return session
        }

        var tapped = try atTheCheck()
        tapped.human(.yes)
        #expect(try #require(lastBrief(tapped)).text.contains("aspirin=ruled_out"))

        var unsure = try atTheCheck()
        unsure.human(.unsure)
        #expect(try #require(lastBrief(unsure)).text.contains("aspirin=ruled_out"))

        // Silence stays on the check, so the brief there still says nobody has answered.
        var silent = try atTheCheck()
        #expect(try #require(lastBrief(silent)).text.contains("aspirin=not_asked"))
        silent.advance(20)
        #expect(silent.state.stateID == "chest_aspirin_check")
        #expect(!silent.state.aspirinRuledOut && !silent.state.aspirinAdvised)
        #expect(lastBrief(silent).map { !$0.text.contains("aspirin=ruled_out") } ?? true)

        var reported = try atTheCheck()
        reported.modelFinding(.aspirinUnsafe)
        #expect(try #require(lastBrief(reported)).text.contains("aspirin=ruled_out"))

        // A risk heard after the dose still has the last word, since the line that goes with it says no aspirin.
        var late = try atTheCheck()
        late.human(.no)
        late.modelFinding(.aspirinUnsafe)
        #expect(late.state.aspirinAdvised)
        #expect(try #require(lastBrief(late)).text.contains("aspirin=ruled_out"))
    }

    @Test func leavingTheCheckAnyOtherWayRulesNothingOut() throws {
        var session = try merged()
        session.human(.yes)
        session.human(.triageChest)
        session.human(.done)
        session.human(.notThis)
        #expect(session.state.stateID == "triage")
        #expect(try #require(lastBrief(session)).text.contains("aspirin=not_asked"))
    }

    /// The first brief to the session that takes over is otherwise full of ids it has never seen.
    @Test(arguments: [HumanAction.patientUnresponsive, .startCpr, .emsArrived])
    func leavingTheAwakeStatesForgetsTheirPhraseIDs(action: HumanAction) throws {
        var session = try merged()
        session.human(.yes)
        session.human(.triageChest)
        session.send(.phrasePlayed("chest_possible"))
        session.send(.phrasePlayed("chest_sit"))
        session.human(action)
        #expect(session.state.recentlyPlayed.isEmpty)
        #expect(try #require(lastBrief(session)).recentlyPlayed.isEmpty)
    }

    @Test func anArrestSessionsPhrasesStayInItsBriefs() throws {
        var session = try merged()
        session.send(.phrasePlayed("ask_responsive"))
        session.human(.no)
        #expect(try #require(lastBrief(session)).recentlyPlayed == ["ask_responsive"])
    }

    @Test func onlyAnAwakeStateHoldsModelAudioForItsPhrases() throws {
        let engine = ProtocolEngine(bundle: try loadMergedBundle())
        for state in engine.bundle.definition.states {
            var running = engine.start(at: 0).state
            running.stateID = state.id
            #expect(engine.policy(for: running, at: 0).modelAudioWaitsForPhrases == state.kind.isAwake, "\(state.id)")
        }
    }

    /// What the AI is told is the app's own voice. Every line the report edges listen for, and never the amount.
    @Test func theAppsLinesAreEveryAwakeLineButTheDose() throws {
        let bundle = try loadMergedBundle()
        let lines = bundle.awakeLines
        #expect(Set(lines).count == lines.count)
        for id in ["triage_ask", "triage_recheck", "general_intro", "choking_steps", "chest_possible", "aspirin_check", "aspirin_skip",
                   "aspirin_stop", "chest_wait_line", "aed_look", "limb_possible", "limb_danger_ask", "limb_danger_care", "limb_gloves"] {
            #expect(lines.contains(try #require(bundle.text(forPhrase: id))), "\(id)")
        }
        for line in lines {
            #expect(!line.contains("mg"), "\(line)")
            #expect(TranscriptValidator.check(line, profile: .awake).isEmpty, "\(line)")
        }
        #expect(!lines.contains(try #require(bundle.text(forPhrase: "aspirin_give"))))
    }

    @Test func briefsGoOutOnEntryAndNothingElse() throws {
        var session = try triage()
        session.send(.modelTurn(active: true))
        #expect(lastBrief(session) == nil)
        session.advance(1)
        #expect(lastBrief(session) == nil)
        session.send(.phrasePlayed("triage_ask"))
        #expect(lastBrief(session) == nil)
        session.send(.sentinelFlag(SentinelFlag(category: .diagnosis, excerpt: "x")))
        #expect(lastBrief(session) == nil)
        session.send(.callChanged(active: true))
        #expect(lastBrief(session) == nil)
        session.human(.triageChest)
        #expect(lastBrief(session) != nil)
    }

    private func lastBrief(_ session: Session) -> StateBrief? {
        session.effects.compactMap { if case let .sendStateBrief(brief) = $0 { brief } else { nil } }.last
    }

    // MARK: - No pack

    /// The session still hears and reports, and nothing it says can be heard.
    @Test func withNoPackEveryAwakeBriefSaysDoNotSpeak() throws {
        let bundle = try loadMergedBundle().closingAwakeVoice()
        let engine = ProtocolEngine(bundle: bundle)
        var state = engine.start(at: 0).state
        for definition in bundle.definition.states where definition.kind.isAwake {
            state.stateID = definition.id
            #expect(!engine.policy(for: state, at: 0).modelSpeechOpen, "\(definition.id)")
            #expect(engine.brief(for: state, definition: definition, at: 0).text.contains("you_may_speak=false"), "\(definition.id)")
        }
    }

    // MARK: - The seeded beat

    @Test func theSeededAwakeLineIsCaughtAndCorrectedInAnOpenState() throws {
        let flags = TranscriptValidator.check("Seeded test line. It's definitely a heart attack.", profile: .awake)
        #expect(flags.map(\.category) == [.diagnosis])
        #expect(TranscriptValidator.check("Seeded test line. It's definitely a heart attack.", profile: .arrest).isEmpty)

        var session = try triage()
        session.send(.sentinelFlag(try #require(flags.first)))
        #expect(session.phrases == ["correct_diagnosis"])
        #expect(session.state.stateID == "triage")
    }
}
