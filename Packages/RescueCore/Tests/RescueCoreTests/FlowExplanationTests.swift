import Foundation
import Testing
@testable import RescueCore

@Suite struct FlowExplanationTests {
    private let source = "Source: AHA/Red Cross First Aid 2024, chest pain, COR 1 C-LD, COR 2b B-NR, COR 2b C-EO; ILCOR First Aid 2025, aspirin, weak. DRAFT."

    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadMergedBundle()) }

    private func explanation(_ session: Session) -> FlowExplanation? {
        FlowExplanation.build(from: session.log.entries, bundle: session.engine.bundle)
    }

    private func tappedIn() throws -> Session {
        var session = Session(engine: try engine())
        session.now += 6
        session.human(.yes)
        session.now += 3
        session.human(.triageChest)
        return session
    }

    private func heardIn(_ finding: Finding = .chestPain, source: ObservationSource = .heard, confidence: Confidence = .high) throws -> Session {
        var session = Session(engine: try engine())
        session.now += 6
        session.human(.yes)
        session.now += 5
        session.model(.reportFinding(finding, source: source, confidence: confidence))
        return session
    }

    // MARK: - When there's nothing to explain

    @Test func noFlowEnteredMeansNothing() throws {
        let core = Session(engine: ProtocolEngine(bundle: try loadBundle()))
        #expect(explanation(core) == nil)

        var merged = Session(engine: try engine())
        #expect(explanation(merged) == nil)
        merged.human(.yes)
        #expect(explanation(merged) == nil)
        merged.human(.triageOther)
        #expect(explanation(merged) == nil)
    }

    @Test func aReportBelowTheThresholdExplainsNothing() throws {
        let session = try heardIn(confidence: .low)
        #expect(session.state.stateID == "triage")
        #expect(explanation(session) == nil)
    }

    // MARK: - Who chose

    @Test func aPersonTapping() throws {
        let built = try #require(explanation(try tappedIn()))
        #expect(built.headline == "Possible heart attack. Not a diagnosis.")
        #expect(built.chooser == .person)
        #expect(built.chooser.rawValue == "You tapped")
        #expect(built.lines == ["You tapped: patient is awake, T+0:06", "You tapped: possible heart attack, T+0:09"])
        #expect(built.why == "Why: Chest pain or heart symptoms in an awake adult.")
        #expect(built.source == source)
    }

    @Test func theAIReporting() throws {
        let built = try #require(explanation(try heardIn()))
        #expect(built.headline == "Possible heart attack. Not a diagnosis.")
        #expect(built.chooser == .ai)
        #expect(built.chooser.rawValue == "AI chose")
        #expect(built.lines == ["You tapped: patient is awake, T+0:06", "AI heard: chest pain (high), T+0:11"])
        #expect(built.why == "Why: Chest pain or heart symptoms in an awake adult.")
        #expect(built.source == source)
    }

    /// What the AI only saw goes on the record but routes nothing, so there's no flow to explain.
    @Test func whatItSawRoutesNothing() throws {
        let session = try heardIn(.otherHeartSigns, source: .seen, confidence: .medium)
        #expect(explanation(session) == nil)
        #expect(session.entries(.observation).last?.detail == "other_heart_signs,seen,medium")
    }

    /// A low report just before it isn't what moved anything, and it isn't what's quoted.
    @Test func theReportQuotedIsTheOneThatRouted() throws {
        var session = Session(engine: try engine())
        session.human(.yes)
        session.model(.reportFinding(.otherHeartSigns, source: .heard, confidence: .low))
        session.now += 2
        session.model(.reportFinding(.chestPain, source: .heard, confidence: .medium))
        #expect(explanation(session)?.lines.last == "AI heard: chest pain (medium), T+0:02")
    }

    @Test func aLaterReportDoesNotRewriteWhyItWasChosen() throws {
        var session = try heardIn()
        session.human(.done)
        session.human(.yes)
        session.now += 5
        session.model(.reportFinding(.limbInjury, source: .heard, confidence: .high))
        let built = try #require(explanation(session))
        #expect(built.chooser == .ai)
        #expect(built.lines.last == "AI heard: chest pain (high), T+0:11")
    }

    /// The chip stays with who chose the flow, and the report that moved the step gets its own line.
    @Test func aReportThatMovedTheStepIsOnThePanel() throws {
        var session = Session(engine: try engine())
        session.now += 6
        session.human(.yes)
        session.now += 3
        session.human(.triageLimb)
        session.now += 2
        session.modelFinding(.heavyBleeding)
        #expect(session.state.stateID == "limb_danger")
        let built = try #require(explanation(session))
        #expect(built.chooser == .person)
        #expect(built.lines == [
            "You tapped: patient is awake, T+0:06",
            "You tapped: possible broken bone, T+0:09",
            "AI heard: heavy bleeding (high), T+0:11",
        ])
    }

    // MARK: - A report that moved nothing

    private func note(_ session: Session) -> String? { FlowExplanation.note(from: session.log.entries) }

    /// The screen has to say so, or a chest pain heard during the limb flow is invisible.
    @Test func aReportThatMovedNothingIsANote() throws {
        var session = Session(engine: try engine())
        session.human(.yes)
        session.human(.triageLimb)
        #expect(note(session) == nil)
        session.model(.reportFinding(.chestPain, source: .heard, confidence: .high))
        #expect(session.state.stateID == "limb_start")
        #expect(note(session) == "AI heard: chest pain (high). Nothing changed.")
        #expect(explanation(session)?.lines.contains { $0.contains("chest pain") } == false, "the panel is why this flow, and this isn't")
    }

    @Test func oneBelowTheThresholdIsANoteToo() throws {
        let session = try heardIn(confidence: .low)
        #expect(session.state.stateID == "triage")
        #expect(note(session) == "AI heard: chest pain (low). Nothing changed.")
    }

    @Test func theNoteIsThereOnlyUntilSomethingMoves() throws {
        var session = try tappedIn()
        session.model(.reportFinding(.limbInjury, source: .seen, confidence: .low))
        #expect(note(session) == "AI saw: limb injury (low). Nothing changed.")
        session.human(.done)
        #expect(note(session) == nil)
    }

    @Test func aReportThatMovedTheStepIsNoNote() throws {
        #expect(note(try heardIn()) == nil)
        #expect(note(Session(engine: ProtocolEngine(bundle: try loadBundle()))) == nil)
    }

    // MARK: - Staying current

    @Test func itHoldsAcrossEveryStepOfTheFlow() throws {
        var session = try tappedIn()
        let first = explanation(session)
        #expect(first != nil)
        for action in [HumanAction.done, .yes, .scan, .done] {
            session.human(action)
            #expect(explanation(session) == first, "\(session.state.stateID)")
        }
    }

    @Test func goingBackEndsIt() throws {
        var session = try tappedIn()
        session.human(.notThis)
        #expect(session.state.stateID == "triage")
        #expect(explanation(session) == nil)
    }

    @Test(arguments: [HumanAction.patientUnresponsive, .startCpr, .notAdult, .emsArrived])
    func leavingTheFlowEndsIt(action: HumanAction) throws {
        var session = try tappedIn()
        session.human(action)
        #expect(explanation(session) == nil, "\(session.state.stateID)")
    }

    @Test func aCollapseReportEndsIt() throws {
        var session = try tappedIn()
        session.modelFinding(.unresponsive)
        #expect(session.state.stateID == "intake_breathing")
        #expect(explanation(session) == nil)
    }

    @Test func theLatestChoiceIsTheOneExplained() throws {
        var session = try tappedIn()
        session.human(.notThis)
        session.now += 2
        session.modelFinding(.limbInjury)
        let built = try #require(explanation(session))
        #expect(built.headline == "Possible broken bone. Not a diagnosis.")
        #expect(built.chooser == .ai)
        #expect(built.lines == ["You tapped: patient is awake, T+0:06", "AI heard: limb injury (high), T+0:11"])
    }

    // MARK: - A forced walk

    /// The shape `OperatorForce.walk` logs. The app suite runs the real one, since this package can't see it.
    private func forced(_ session: inout Session, to id: String, flow: String?) {
        var drafts = [
            LogEntry.Draft(kind: .stateEntered, source: .system, detail: "operator_forced:\(id)"),
            LogEntry.Draft(kind: .stateEntered, source: .system, detail: id),
        ]
        if let flow { drafts.append(LogEntry.Draft(kind: .flowEntered, source: .system, detail: flow)) }
        session.log.append(drafts, at: session.now)
    }

    @Test func aForcedWalkIsNobodysChoice() throws {
        var session = Session(engine: try engine())
        forced(&session, to: "chest_wait", flow: "possible_heart_attack")
        let built = try #require(explanation(session))
        #expect(built.chooser == .neither)
        #expect(built.chooser.rawValue == "Set automatically")
        #expect(built.lines.isEmpty, "the walk invents no answers, so it can't quote one")
        #expect(built.headline == "Possible heart attack. Not a diagnosis.")
    }

    @Test func aForcedWalkKeepsARealTapThatCameBefore() throws {
        var session = Session(engine: try engine())
        session.now += 6
        session.human(.yes)
        forced(&session, to: "chest_scan", flow: "possible_heart_attack")
        let built = try #require(explanation(session))
        #expect(built.chooser == .neither)
        #expect(built.lines == ["You tapped: patient is awake, T+0:06"])
    }

    @Test func aForcedWalkOutOfTheFlowEndsIt() throws {
        var session = try tappedIn()
        forced(&session, to: "compressions", flow: nil)
        #expect(explanation(session) == nil)
    }

    // MARK: - What it can't vouch for

    @Test func aFlowTheBundleDoesNotHaveExplainsNothing() throws {
        let session = try tappedIn()
        var bundle = session.engine.bundle
        bundle.flows = []
        #expect(FlowExplanation.build(from: session.log.entries, bundle: bundle) == nil)
    }

    @Test func aRuleAlreadyEndingInAStopIsNotDoubled() throws {
        let session = try tappedIn()
        var bundle = session.engine.bundle
        let first = try #require(bundle.flows.indices.first)
        bundle.flows[first].rule = "A rule."
        #expect(FlowExplanation.build(from: session.log.entries, bundle: bundle)?.why == "Why: A rule.")
    }

    @Test func itNeverStatesAConditionOrAClinician() throws {
        for session in [try tappedIn(), try heardIn()] {
            let built = try #require(explanation(session))
            let text = ([built.headline, built.why, built.source] + built.lines).joined(separator: " ").lowercased()
            #expect(text.contains("possible heart attack"))
            #expect(text.contains("not a diagnosis"))
            #expect(TranscriptValidator.check(text, profile: .awake).isEmpty, "\(TranscriptValidator.check(text, profile: .awake))")
        }
    }
}
