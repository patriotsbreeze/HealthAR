import Foundation
import Testing
@testable import RescueCore

private let earlierSteps = ["limb_start", "limb_flags", "limb_splint", "limb_wait"]
private let limbSteps = earlierSteps + ["limb_danger"]
private let chestSteps = ["chest_call", "chest_aspirin_check", "chest_aspirin", "chest_wait", "chest_scan"]
private let dangerFindings = [Finding.heavyBleeding, .limbDiscolored, .neckBackInjury]
private let dangerPhrases = ["call_911", "limb_danger_care", "limb_tourniquet"]

/// The broken bone module as it ships, through the real engine.
@Suite struct BrokenBoneFlowTests {
    private func inTriage() throws -> Session {
        var session = Session(engine: ProtocolEngine(bundle: try loadMergedBundle()))
        session.human(.yes)
        return session
    }

    private func inFlow() throws -> Session {
        var session = try inTriage()
        session.human(.triageLimb)
        return session
    }

    private func inTalk() throws -> Session {
        var session = try inTriage()
        session.human(.triageOther)
        return session
    }

    /// By the taps that get there, so each is the real path.
    private func session(in id: String) throws -> Session {
        var session = try inFlow()
        if id == "limb_start" { return session }
        session.human(.done)
        if id == "limb_flags" { return session }
        if id == "limb_danger" {
            session.human(.yes)
            return session
        }
        session.human(.no)
        if id == "limb_splint" { return session }
        session.human(.done)
        #expect(session.state.stateID == id)
        return session
    }

    private func inChest(_ id: String) throws -> Session {
        var session = try inTriage()
        session.human(.triageChest)
        if id == "chest_call" { return session }
        session.human(.done)
        if id == "chest_aspirin_check" { return session }
        if id == "chest_aspirin" {
            session.human(.no)
            return session
        }
        session.human(.yes)
        if id == "chest_wait" { return session }
        session.human(.scan)
        #expect(session.state.stateID == id)
        return session
    }

    private func report(_ finding: Finding, _ confidence: Confidence, into session: inout Session) {
        session.model(.reportFinding(finding, source: .heard, confidence: confidence))
    }

    private func voiceOpen(_ session: Session) -> Bool {
        session.engine.policy(for: session.state, at: session.now).modelSpeechOpen
    }

    private func explanation(_ session: Session) -> FlowExplanation? {
        FlowExplanation.build(from: session.log.entries, bundle: session.engine.bundle)
    }

    // MARK: - The steps

    @Test(arguments: [
        ("limb_start", 1, false), ("limb_flags", 1, false), ("limb_splint", 1, false),
        ("limb_wait", 1, true), ("limb_danger", 2, true),
    ])
    func eachStepHasItsUrgencyAndVoice(id: String, urgency: Int, open: Bool) throws {
        let session = try session(in: id)
        let definition = try #require(session.engine.definition(of: id))
        #expect(session.state.stateID == id)
        #expect(definition.kind == .flow)
        #expect(definition.flow == "possible_broken_bone")
        #expect(definition.urgency == urgency)
        #expect(voiceOpen(session) == open)
        #expect(definition.overlay == .injurySite)
    }

    // MARK: - By taps

    @Test func theWholeFlowByTaps() throws {
        var session = try inFlow()
        #expect(session.state.stateID == "limb_start")
        #expect(session.phrases == ["limb_possible"])
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_broken_bone"])
        #expect(session.entries(.flowEntered).last?.source == .bystander)

        session.human(.done)
        #expect(session.state.stateID == "limb_flags")
        #expect(session.phrases == ["limb_danger_ask"])

        session.human(.no)
        #expect(session.state.stateID == "limb_splint")
        #expect(session.phrases == ["limb_wound", "limb_support"])
        #expect(session.entries(.answer).last?.detail == "danger_signs=no")
        #expect(session.entries(.answer).last?.source == .bystander)

        session.human(.done)
        #expect(session.state.stateID == "limb_wait")
        #expect(session.phrases == ["limb_seek_care"])

        #expect(session.entries(.flowEntered).count == 1, "one flow, however many steps")
        #expect(session.entries(.callPrompted).isEmpty, "only the danger branch tells them to call")
        #expect(!session.allPhrases.contains("call_911"))
        #expect(!session.state.metronomeOn)
    }

    @Test(arguments: [HumanAction.yes, .unsure])
    func anythingButNoTakesTheDangerBranch(action: HumanAction) throws {
        var session = try session(in: "limb_flags")
        session.human(action)
        #expect(session.state.stateID == "limb_danger")
        #expect(session.phrases == dangerPhrases)
        #expect(session.entries(.answer).last?.detail == "danger_signs=\(action.rawValue)")
        #expect(session.entries(.answer).last?.source == .bystander)
        #expect(session.entries(.callPrompted).count == 1)
        #expect(session.effects.contains(.dropQueuedPhrases(keeping: ["call_911"])))
    }

    @Test(arguments: limbSteps)
    func notThisGoesBackAndCutsNothing(id: String) throws {
        var session = try session(in: id)
        session.human(.notThis)
        #expect(session.state.stateID == "triage")
        #expect(session.phrases == ["triage_ask"])
        #expect(!session.effects.contains(.cutPhrases))
        #expect(explanation(session) == nil)
    }

    // MARK: - By silence

    @Test func silenceTakesTheDangerBranch() throws {
        var session = try inFlow()
        session.advance(5)
        #expect(session.state.stateID == "limb_start")
        session.advance(1)
        #expect(session.state.stateID == "limb_flags")
        #expect(session.phrases == ["limb_danger_ask"])

        session.advance(9)
        #expect(session.state.stateID == "limb_flags")
        session.advance(1)
        #expect(session.state.stateID == "limb_danger")
        #expect(session.phrases == dangerPhrases)
        #expect(session.entries(.answer).last?.detail == "danger_signs=no_reply")
        #expect(session.entries(.answer).last?.source == .timer)
        #expect(session.entries(.callPrompted).count == 1)

        session.advance(600)
        #expect(session.state.stateID == "limb_danger")
        #expect(!session.allPhrases.contains("limb_wound"))
        #expect(!session.state.metronomeOn)
    }

    /// Nobody tapped past anything, so queued steps still play.
    @Test func noTouchKeepsWhatIsQueued() throws {
        var session = try inFlow()
        for seconds in [6.0, 10] {
            session.advance(seconds)
            #expect(!session.effects.contains { if case .dropQueuedPhrases = $0 { true } else { false } })
            #expect(!session.effects.contains(.cutPhrases))
        }
        #expect(session.state.stateID == "limb_danger")
    }

    @Test func theSplintStepEndsOnItsOwn() throws {
        var session = try session(in: "limb_splint")
        session.advance(9)
        #expect(session.state.stateID == "limb_splint")
        session.advance(1)
        #expect(session.state.stateID == "limb_wait")
        #expect(session.phrases == ["limb_seek_care"])
    }

    @Test(arguments: [("limb_wait", "limb_seek_care"), ("limb_danger", "limb_danger_care")])
    func theOpenStepsReAskEveryThirtySecondsAndNeverMove(id: String, phrase: String) throws {
        var session = try session(in: id)
        for _ in 0..<20 {
            session.advance(29)
            #expect(session.phrases.isEmpty, "\(id)")
            session.advance(1)
            #expect(session.phrases == [phrase], "\(id)")
            #expect(session.state.stateID == id)
        }
    }

    // MARK: - Gloves and the cue lines

    /// Hands on the wound come first, so gloves get a line only when someone says they have some.
    @Test func glovesGetTheirLineOnceOnTheDangerStep() throws {
        var session = try session(in: "limb_danger")
        session.model(.reportResources([.gloves]))
        #expect(session.phrases == ["limb_gloves"])
        #expect(session.state.resources.contains(.gloves))

        session.advance(1)
        session.model(.reportResources([.gloves]))
        #expect(session.phrases.isEmpty, "once")
    }

    @Test func glovesWaitForTheFloor() throws {
        var session = try session(in: "limb_danger")
        session.modelFinding(.dispatcherSpeaking)
        session.model(.reportResources([.gloves]))
        #expect(session.phrases.isEmpty)
    }

    @Test(arguments: earlierSteps)
    func glovesSayNothingBeforeTheDangerStep(id: String) throws {
        var session = try session(in: id)
        session.model(.reportResources([.gloves, .towel]))
        #expect(session.phrases.isEmpty, "\(id)")
        #expect(session.state.resources.isSuperset(of: [.gloves, .towel]), "still on the record")
    }

    /// These lines answer a report or carry a cue, so the model can't play them and isn't offered them.
    @Test(arguments: [("limb_danger", "limb_gloves"), ("limb_wait", "limb_support")])
    func theCueLinesTakeNoSay(id: String, phrase: String) throws {
        var session = try session(in: id)
        let definition = try #require(session.engine.definition(of: id))
        #expect(definition.allowedSay.contains(phrase))
        #expect(!session.engine.brief(for: session.state, definition: definition, at: session.now).allowedSay.contains(phrase))

        session.model(.say(phraseID: phrase))
        #expect(session.phrases.isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix(SafetyGate.RejectReason.phraseNotAllowed.rawValue) == true)
    }

    // MARK: - By report

    @Test(arguments: [
        ("triage", Finding.limbInjury, "limb_start"),
        ("triage", .heavyBleeding, "limb_danger"),
        ("triage", .limbDiscolored, "limb_danger"),
        ("triage", .neckBackInjury, "limb_danger"),
        ("general_talk", .limbInjury, "limb_start"),
        ("general_talk", .heavyBleeding, "limb_danger"),
        ("general_talk", .limbDiscolored, "limb_danger"),
        ("general_talk", .neckBackInjury, "limb_danger"),
    ])
    func aSureEnoughReportRoutesIn(from: String, finding: Finding, to: String) throws {
        func start() throws -> Session { from == "triage" ? try inTriage() : try inTalk() }

        var low = try start()
        let before = low.state
        report(finding, .low, into: &low)
        #expect(low.state == before, "below the edge's confidence it stays on the record only")
        #expect(low.entries(.observation).last?.detail == "\(finding.rawValue),heard,low")
        #expect(low.effects.isEmpty)

        for confidence in [Confidence.medium, .high] {
            var session = try start()
            report(finding, confidence, into: &session)
            #expect(session.state.stateID == to)
            #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,\(confidence.rawValue)")
            #expect(session.entries(.finding).last?.detail == finding.rawValue)
            #expect(session.entries(.flowEntered).map(\.detail) == ["possible_broken_bone"])
            #expect(session.entries(.flowEntered).last?.source == .aiInferred)
            #expect(session.phrases == (to == "limb_danger" ? dangerPhrases : ["limb_possible"]))
        }
    }

    @Test(arguments: earlierSteps, dangerFindings)
    func aSureDangerReportMovesAnyEarlierStep(id: String, finding: Finding) throws {
        var low = try session(in: id)
        let before = low.state
        report(finding, .low, into: &low)
        #expect(low.state == before)
        #expect(low.effects.isEmpty)
        #expect(low.entries(.observation).last?.detail == "\(finding.rawValue),heard,low")

        for confidence in [Confidence.medium, .high] {
            var session = try session(in: id)
            report(finding, confidence, into: &session)
            #expect(session.state.stateID == "limb_danger")
            #expect(session.phrases == dangerPhrases)
            #expect(session.entries(.callPrompted).count == 1)
            #expect(session.entries(.flowEntered).count == 1, "the same flow")
        }
    }

    @Test(arguments: [Finding.limbInjury] + dangerFindings, Confidence.allCases)
    func aDangerReportInTheDangerStepIsOnlyRecorded(finding: Finding, confidence: Confidence) throws {
        var session = try session(in: "limb_danger")
        let before = session.state
        report(finding, confidence, into: &session)
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,\(confidence.rawValue)")
    }

    /// Where a report can enter is what the plan lists, and each has to be sure enough.
    @Test func everyModelEdgeIntoTheFlowIsOneOfTheListedOnes() throws {
        let definition = try loadMergedBundle().definition
        let limb = Set(definition.states.filter { $0.flow == "possible_broken_bone" }.map(\.id))
        var entries = 0
        for state in definition.states where !limb.contains(state.id) {
            for edge in state.transitions where edge.on.hasPrefix("model.") && limb.contains(edge.to) {
                #expect(["triage", "general_talk"].contains(state.id), "\(state.id) \(edge.on)")
                #expect(edge.to == (edge.on == "model.limb_injury" ? "limb_start" : "limb_danger"), "\(state.id) \(edge.on)")
                #expect(edge.minConfidence == .medium, "\(state.id) \(edge.on)")
                entries += 1
            }
        }
        #expect(entries == 8)

        var inside = 0
        for state in definition.states where limb.contains(state.id) {
            for edge in state.transitions where edge.on.hasPrefix("model.") && limb.contains(edge.to) {
                #expect(edge.to == "limb_danger", "\(state.id) \(edge.on)")
                #expect(edge.minConfidence == .medium, "\(state.id) \(edge.on)")
                inside += 1
            }
        }
        #expect(inside == 12)
    }

    @Test(arguments: [Finding.limbInjury] + dangerFindings)
    func aRoutingReportAtIntakeDoesNothing(finding: Finding) throws {
        var session = Session(engine: ProtocolEngine(bundle: try loadMergedBundle()))
        let before = session.state
        session.modelFinding(finding)
        #expect(session.state == before)
        #expect(session.entries(.observation).isEmpty)
        #expect(session.entries(.proposalRejected).last?.detail.hasSuffix("not_applicable") == true)
    }

    // MARK: - Across the flows

    /// A second concern goes on the record for the people who take over. An edge here would drop this
    /// whole module any time the heart attack one failed to load.
    @Test(arguments: limbSteps, [Finding.chestPain, .otherHeartSigns])
    func aChestPainReportInALimbStepIsOnlyAnObservation(id: String, finding: Finding) throws {
        for confidence in Confidence.allCases {
            var session = try session(in: id)
            let before = session.state
            let logged = session.log.entries.count
            report(finding, confidence, into: &session)

            #expect(session.state == before)
            #expect(session.effects.isEmpty)
            let added = session.log.entries.dropFirst(logged)
            #expect(added.map(\.kind) == [.observation])
            #expect(added.first?.detail == "\(finding.rawValue),heard,\(confidence.rawValue)")

            let row = HandoffBuilder.build(from: session.log.entries).items.first { $0.value == "\(LogFacts.words(finding.rawValue)) (\(confidence.rawValue))" }
            #expect(row?.label == "AI heard")
            #expect(row?.source == .aiInferred)
            #expect(explanation(session)?.headline == "Possible broken bone. Not a diagnosis.")
        }
    }

    @Test(arguments: chestSteps, [Finding.limbInjury] + dangerFindings)
    func aLimbReportInAChestStepIsOnlyAnObservation(id: String, finding: Finding) throws {
        var session = try inChest(id)
        let before = session.state
        session.modelFinding(finding)
        #expect(session.state == before)
        #expect(session.effects.isEmpty)
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),heard,high")
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_heart_attack"])
    }

    // MARK: - Panel and card

    @Test func aTappedFlowSaysWhyAndSaysPossible() throws {
        let built = try #require(explanation(try inFlow()))
        #expect(built.headline == "Possible broken bone. Not a diagnosis.")
        #expect(built.chooser == .person)
        #expect(built.lines.last?.hasPrefix("You tapped: possible broken bone, ") == true)
        #expect(built.why == "Why: Injured arm or leg, or a sign of serious injury, in an awake adult.")
        #expect(built.source.hasPrefix("Source: AHA/Red Cross First Aid 2024"))
        #expect(built.source.hasSuffix("DRAFT."))
    }

    /// A dispatcher hearing only "possible broken bone" wouldn't know about the bleeding.
    @Test(arguments: [
        (Finding.heavyBleeding, "heavy bleeding"),
        (.neckBackInjury, "neck back injury"),
        (.limbDiscolored, "limb discolored"),
    ])
    func theCallerScriptSaysWhatTheAIReported(finding: Finding, words: String) throws {
        var session = try inTriage()
        session.modelFinding(finding)
        let script = CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: [])
        #expect(script.situation == "Adult unwell, responding, possible broken bone, AI reported \(words).")
    }

    @Test func theCallerScriptSaysWhatMovedTheStep() throws {
        var session = try inFlow()
        session.modelFinding(.heavyBleeding)
        session.modelFinding(.chestPain)
        let script = CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: [])
        #expect(script.situation == "Adult unwell, responding, possible broken bone, AI reported heavy bleeding.")
    }

    /// After the question, a danger the tap couldn't know about still moves the step.
    @Test func aStaleDangerReportOutranksTheNoItCrossed() throws {
        var session = try session(in: "limb_flags")
        let old = session.proposal(.reportFinding(.heavyBleeding, source: .heard, confidence: .high))
        session.human(.no)
        #expect(session.state.stateID == "limb_splint")
        session.now += 2
        session.send(.model(old))
        #expect(session.state.stateID == "limb_danger")
    }

    /// Backing out says it isn't a broken bone, not that the bleeding has stopped.
    @Test func aDangerReportStillRoutesAfterNotThis() throws {
        var session = try inFlow()
        session.human(.notThis)
        let before = session.state
        session.modelFinding(.limbInjury)
        #expect(session.state == before)
        session.modelFinding(.heavyBleeding)
        #expect(session.state.stateID == "limb_danger")
    }

    @Test func aReportedFlowSaysWhatWasHeard() throws {
        var session = try inTriage()
        session.modelFinding(.heavyBleeding)
        let built = try #require(explanation(session))
        #expect(built.chooser == .ai)
        #expect(built.lines.last?.hasPrefix("AI heard: heavy bleeding (high), ") == true)
    }

    @Test func theCardCarriesTheConcernAndTheAnswer() throws {
        var session = try session(in: "limb_flags")
        session.human(.yes)

        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(card.items.first { $0.label == "Concern" }?.value == "Possible broken bone. Not a diagnosis.")
        #expect(card.items.first { $0.label == "Danger signs" }?.value == "yes")
        #expect(card.items.first { $0.label == "911 prompted" }?.value != "not recorded")
        #expect(!card.items.contains { $0.label == "Coaching started" }, "nothing here reached CPR")
        #expect(!card.items.contains { $0.label.hasPrefix("Aspirin") })
        #expect(card.readout.contains("Concern: possible broken bone, not a diagnosis."))

        let script = CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: [])
        #expect(script.situation.contains("possible broken bone"))
    }

    @Test func noReplyIsNotReadAsAnAnswer() throws {
        var session = try inFlow()
        session.advance(6)
        session.advance(10)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(card.items.first { $0.label == "Danger signs" }?.value == "no reply")
        #expect(card.items.first { $0.label == "Danger signs" }?.source == .timer)
    }
}
