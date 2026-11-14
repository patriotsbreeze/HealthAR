import Foundation
import Testing
@testable import RescueCore

/// The first step when there's an AI: it looks and listens, and nothing is assumed about the patient.
@Suite struct AssessTests {
    private func engine() throws -> ProtocolEngine {
        ProtocolEngine(bundle: try loadMergedBundle().startingWithAssessment())
    }

    /// What the rescuer says routes; what the AI only sees is noted. Heard by default, as routing is.
    private func report(_ finding: Finding, _ confidence: Confidence, source: ObservationSource = .heard, in session: inout Session) {
        session.model(.reportFinding(finding, source: source, confidence: confidence))
    }

    @Test func aRescueWithAnAIOpensOnAssessAndOneWithoutDoesNot() throws {
        let bundle = try loadMergedBundle()
        #expect(bundle.definition.initialState == "intake_responsive")
        #expect(bundle.startingWithAssessment().definition.initialState == "assess")
        // With no triage module there's nothing to open on, so it opens as it always did.
        let core = try loadBundle()
        #expect(core.startingWithAssessment().definition.initialState == "intake_responsive")

        let session = Session(engine: try engine())
        #expect(session.state.stateID == "assess")
        #expect(session.phrases == ["assess_intro"])
        #expect(session.engine.definition(of: "assess")?.kind.liveMode == .awake)
    }

    @Test func itWatchesAtTheSteadyRateAndTalks() throws {
        let session = Session(engine: try engine())
        let policy = session.engine.policy(for: session.state, at: session.now)
        #expect(policy.frameUplink)
        #expect(!policy.frameBurstsOnly, "it's looking for what's wrong, so not only after a trigger")
        #expect(policy.modelSpeechOpen)
    }

    // MARK: - Routing

    @Test(arguments: [
        (Finding.chestPain, "chest_call"), (.otherHeartSigns, "chest_call"),
        (.limbInjury, "limb_start"), (.heavyBleeding, "limb_danger"), (.limbDiscolored, "limb_danger"), (.neckBackInjury, "limb_danger"),
        (.choking, "choking_talk"), (.otherConcern, "general_talk"),
        (.unresponsive, "intake_breathing"), (.notBreathing, "intake_breathing"), (.abnormalBreathing, "intake_breathing"),
    ])
    func aSureReportRoutes(finding: Finding, to target: String) throws {
        var session = Session(engine: try engine())
        report(finding, .medium, in: &session)
        #expect(session.state.stateID == target)
    }

    /// A low report shows on screen as what the AI thinks, and moves nothing.
    @Test(arguments: [Finding.chestPain, .limbInjury, .choking, .otherConcern])
    func aLowReportIsOnlyNoted(finding: Finding) throws {
        var session = Session(engine: try engine())
        report(finding, .low, source: .seen, in: &session)
        #expect(session.state.stateID == "assess")
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),seen,low")
    }

    /// A collapse needs no confidence threshold, as on every awake step.
    @Test func aLowCollapseReportStillGoesToTheBreathingQuestion() throws {
        var session = Session(engine: try engine())
        report(.unresponsive, .low, in: &session)
        #expect(session.state.stateID == "intake_breathing")
    }

    /// "They're fine" can never take the rescue anywhere, and only a person's tap says they're awake.
    @Test func noReportCanSayThePatientIsAwake() throws {
        var session = Session(engine: try engine())
        for finding in [Finding.responsive, .breathingNormally, .patientMoving] {
            report(finding, .high, source: .heard, in: &session)
            #expect(session.state.stateID == "assess")
        }
        session.human(.patientAwake)
        #expect(session.state.stateID == "triage")
    }

    @Test func theWayOutIsThereFromTheFirstSecond() throws {
        var session = Session(engine: try engine())
        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")

        var other = Session(engine: try engine())
        other.human(.patientUnresponsive)
        #expect(other.state.stateID == "intake_breathing")
    }

    // MARK: - Silence

    /// Only the rescuer moves the rescue on: silence keeps watching, and Start CPR is one tap.
    @Test func silenceWaitsAndStartCprIsOneTap() throws {
        var session = Session(engine: try engine())
        for _ in 0..<120 { session.advance(1) }
        #expect(session.state.stateID == "assess")
        #expect(!session.state.metronomeOn)
        session.human(.startCpr)
        #expect(session.state.stateID == "compressions")
    }

    /// The AI seeing it, however sure, notes it on the panel and waits for the rescuer.
    @Test(arguments: [Finding.unresponsive, .chestPain, .heavyBleeding])
    func whatTheAIOnlySeesMovesNothing(finding: Finding) throws {
        var session = Session(engine: try engine())
        report(finding, .high, source: .seen, in: &session)
        #expect(session.state.stateID == "assess")
        #expect(session.entries(.observation).last?.detail == "\(finding.rawValue),seen,high")
        session.human(.patientUnresponsive)
        #expect(session.state.stateID == "intake_breathing")
    }

    /// Not breathing, or only gasping, is the second half of the call to start CPR. A person's tap
    /// is the human input the call step needs, so it goes there, as a No at the breathing question does.
    @Test func tappingNotBreathingGoesStraightToTheCall() throws {
        var session = Session(engine: try engine())
        session.human(.patientNotBreathing)
        #expect(session.state.stateID == "call_911")
        #expect(session.phrases.last == "call_911")
    }

    /// Only assess has it: an awake step's patient was already said to be responding.
    @Test func onlyAssessHasTheNotBreathingTap() throws {
        let bundle = try loadMergedBundle().startingWithAssessment()
        let holders = bundle.definition.states.filter { $0.transitions.contains { $0.on == "human.patient_not_breathing" } }
        #expect(holders.map(\.id) == ["assess"])
    }

    @Test func aLongDescriptionNeverPushesItOn() throws {
        var session = Session(engine: try engine())
        session.send(.modelTurn(active: true))
        session.advance(60)
        session.send(.modelTurn(active: false))
        session.advance(5)
        #expect(session.state.stateID == "assess")
    }

    // MARK: - What the loader holds it to

    private func triage(_ change: (inout [String: Any]) -> Void) throws -> ModuleSource {
        let url = repoRoot().appendingPathComponent("clinical/modules/triage.v1.json")
        var module = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var states = try #require(module["states"] as? [[String: Any]])
        let index = try #require(states.firstIndex { $0["id"] as? String == "assess" })
        var assess = states[index]
        change(&assess)
        states[index] = assess
        module["states"] = states
        return ModuleSource(id: "triage.v1", data: try JSONSerialization.data(withJSONObject: module))
    }

    private func refusal(_ source: ModuleSource) throws -> String? {
        try loadBundle().merging(modules: [source], pack: nil).moduleFailures.first { $0.id == source.id }?.reason
    }

    @Test func theShippedOneLoads() throws {
        #expect(try refusal(try triage { _ in }) == nil)
    }

    @Test func itMayNotTimeOut() throws {
        for target in ["intake_responsive", "general_talk"] {
            let timed = try triage { $0["timeout"] = ["seconds": 20, "to": target] }
            #expect(try refusal(timed)?.contains("assess must wait for the rescuer") == true, "\(target)")
        }
    }

    /// No awake step may time out into the arrest path.
    @Test func noOtherAwakeStepMayTimeOutIntoTheArrestPath() throws {
        let url = repoRoot().appendingPathComponent("clinical/modules/triage.v1.json")
        var module = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var states = try #require(module["states"] as? [[String: Any]])
        let index = try #require(states.firstIndex { $0["id"] as? String == "general_talk" })
        states[index]["timeout"] = ["seconds": 20, "to": "intake_responsive"]
        module["states"] = states
        let source = ModuleSource(id: "triage.v1", data: try JSONSerialization.data(withJSONObject: module))
        #expect(try refusal(source)?.contains("timeout into the arrest path") == true)
    }
}
