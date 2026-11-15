import Foundation
import Testing
@testable import RescueCore

/// The choking module as it ships, through the real engine.
@Suite struct ChokingFlowTests {
    private func engine(_ bundle: ProtocolBundle? = nil) throws -> ProtocolEngine { ProtocolEngine(bundle: try bundle ?? loadMergedBundle()) }

    private func inTriage(_ bundle: ProtocolBundle? = nil) throws -> Session {
        var session = Session(engine: try engine(bundle))
        session.human(.yes)
        return session
    }

    private func inCheck() throws -> Session {
        var session = try inTriage()
        session.human(.triageChoking)
        return session
    }

    // MARK: - Getting in

    @Test func aTapFromTriageAsksIfTheyCanCough() throws {
        let session = try inCheck()
        #expect(session.state.stateID == "choke_check")
        #expect(session.phrases == ["choke_ask"])
        #expect(session.entries(.flowEntered).map(\.detail) == ["possible_choking"])
        #expect(session.entries(.flowEntered).last?.source != .aiInferred)
    }

    @Test func somethingElseStillOffersChoking() throws {
        var session = try inTriage()
        session.human(.triageOther)
        session.human(.triageChoking)
        #expect(session.state.stateID == "choke_check")
    }

    @Test(arguments: ["assess", "triage", "general_talk"])
    func aSureReportOpensTheCheck(from: String) throws {
        var session: Session
        if from == "assess" {
            session = Session(engine: try engine(try loadMergedBundle().startingWithAssessment()))
        } else {
            session = try inTriage()
            if from == "general_talk" { session.human(.triageOther) }
        }
        #expect(session.state.stateID == from)
        session.model(.reportFinding(.choking, source: .heard, confidence: .medium))
        #expect(session.state.stateID == "choke_check")
        #expect(session.entries(.flowEntered).last?.source == .aiInferred)
    }

    @Test func aLowReportMovesNothing() throws {
        var session = try inTriage()
        session.model(.reportFinding(.choking, source: .heard, confidence: .low))
        #expect(session.state.stateID == "triage")
    }

    // MARK: - The question

    @Test func canCoughKeepsThemCoughing() throws {
        var session = try inCheck()
        session.human(.yes)
        #expect(session.state.stateID == "choke_cough")
        #expect(session.phrases == ["choke_keep_coughing"])
        #expect(session.entries(.callPrompted).isEmpty, "a cough that works is not yet the severe branch")
        session.human(.cantCough)
        #expect(session.state.stateID == "choke_back_blows")
    }

    @Test(arguments: [HumanAction.no, .unsure])
    func cannotCoughOrNotSureStartsBackBlowsAndTheCall(answer: HumanAction) throws {
        var session = try inCheck()
        session.human(answer)
        #expect(session.state.stateID == "choke_back_blows")
        #expect(session.phrases == ["choke_calling", "choke_blows"])
        #expect(session.entries(.callPrompted).count == 1)
        #expect(session.entries(.answer).last?.detail == "can_cough_or_speak=\(answer.rawValue)")
    }

    /// The AI can only take the check, or a working cough, toward back blows.
    @Test(arguments: ["choke_check", "choke_cough", "choke_out"])
    func aSureReportOfChokingGoesToBackBlows(from: String) throws {
        var session = try inCheck()
        if from == "choke_cough" { session.human(.yes) }
        if from == "choke_out" {
            session.human(.no)
            session.human(.objectOut)
        }
        #expect(session.state.stateID == from)
        session.model(.reportFinding(.choking, source: .heard, confidence: .medium))
        #expect(session.state.stateID == "choke_back_blows")
    }

    @Test func noReplyKeepsAskingAndNeverLeaves() throws {
        var session = try inCheck()
        session.advance(8)
        #expect(session.phrases == ["choke_ask"])
        session.advance(600)
        #expect(session.state.stateID == "choke_check", "only a tap or a sure report answers it")
    }

    // MARK: - Back blows and thrusts

    @Test func blowsAndThrustsAlternateUntilItIsOut() throws {
        var session = try inCheck()
        session.human(.no)
        let blows = try #require(session.engine.definition(of: "choke_back_blows"))
        #expect(blows.overlay == .upperBack)
        #expect(blows.guide == .backBlows)

        session.human(.done)
        #expect(session.state.stateID == "choke_thrusts")
        #expect(session.phrases == ["choke_thrusts_line"])
        let thrusts = try #require(session.engine.definition(of: "choke_thrusts"))
        #expect(thrusts.overlay == .upperAbdomen)
        #expect(thrusts.guide == .abdominalThrusts)

        session.human(.done)
        #expect(session.state.stateID == "choke_back_blows")
        #expect(session.phrases == ["choke_blows"], "911 is said once, on the way in")
        #expect(session.entries(.callPrompted).count == 1)

        session.human(.done)
        session.human(.objectOut)
        #expect(session.state.stateID == "choke_out")
        #expect(session.phrases == ["choke_after"])
    }

    @Test(arguments: ["choke_back_blows", "choke_thrusts"])
    func aCollapseGoesToTheBreathingQuestion(from: String) throws {
        var session = try inCheck()
        session.human(.no)
        if from == "choke_thrusts" { session.human(.done) }
        session.human(.patientUnresponsive)
        #expect(session.state.stateID == "intake_breathing")
    }

    @Test func noTimerLeavesTheHandsOnSteps() throws {
        var session = try inCheck()
        session.human(.no)
        session.advance(600)
        #expect(session.state.stateID == "choke_back_blows")
    }

    // MARK: - The AI

    /// The rescuer saying they've finished moves the step on, the same as Done, and the record says the AI did it.
    @Test func aSureStepDoneMovesBlowsAndThrustsOn() throws {
        var session = try inCheck()
        session.human(.no)
        session.model(.reportFinding(.stepDone, source: .heard, confidence: .medium))
        #expect(session.state.stateID == "choke_thrusts")
        #expect(session.entries(.finding).last?.detail == "step_done")
        session.model(.reportFinding(.stepDone, source: .heard, confidence: .high))
        #expect(session.state.stateID == "choke_back_blows")
        #expect(session.phrases == ["choke_blows"])
    }

    @Test func stepDoneSeenOrUnsureMovesNothing() throws {
        var session = try inCheck()
        session.human(.no)
        session.model(.reportFinding(.stepDone, source: .heard, confidence: .low))
        #expect(session.state.stateID == "choke_back_blows")
        session.model(.reportFinding(.stepDone, source: .seen, confidence: .high))
        #expect(session.state.stateID == "choke_back_blows", "only what the rescuer said")
    }

    /// Off back blows only by a person: the gate refuses these, and the app rings the button instead.
    @Test(arguments: [(Finding.canCough, "choke_check"), (.objectOut, "choke_back_blows"), (.objectOut, "choke_thrusts"), (.objectOut, "choke_cough")])
    func aLoweringReportNeverMoves(finding: Finding, from: String) throws {
        var session = try inCheck()
        if from == "choke_cough" { session.human(.yes) }
        if from == "choke_back_blows" || from == "choke_thrusts" { session.human(.no) }
        if from == "choke_thrusts" { session.human(.done) }
        #expect(session.state.stateID == from)
        session.model(.reportFinding(finding, source: .heard, confidence: .high))
        #expect(session.state.stateID == from)
        #expect(session.entries(.proposalRejected).last?.detail.contains("cannot_lower_urgency") == true)
    }

    @Test func stepDoneMovesNothingOffTheHandsOnSteps() throws {
        for from in ["choke_check", "choke_cough"] {
            var session = try inCheck()
            if from == "choke_cough" { session.human(.yes) }
            session.model(.reportFinding(.stepDone, source: .heard, confidence: .high))
            #expect(session.state.stateID == from)
        }
    }

    // MARK: - Without the module

    /// A refused choking file takes its button and its routes with it, like any other flow, and
    /// leaves Something else and the collapse.
    @Test func aRefusedModuleTakesChokingWithIt() throws {
        let clinical = repoRoot().appendingPathComponent("clinical")
        let modules = ScenarioModule.manifest.map { id in
            ModuleSource(id: id, data: id == "possible_choking.v1" ? nil : try? Data(contentsOf: clinical.appendingPathComponent("modules/\(id).json")))
        }
        let pack = try Data(contentsOf: clinical.appendingPathComponent("\(KnowledgePack.id).json"))
        let bundle = try loadBundle().merging(modules: modules, pack: pack)
        #expect(bundle.moduleFailures == [ModuleFailure(id: "possible_choking.v1", reason: "missing")])
        #expect(!bundle.definition.states.contains { $0.transitions.contains { $0.on == "human.triage_choking" } })

        var heard = try inTriage(bundle)
        heard.modelFinding(.choking)
        #expect(heard.state.stateID == "triage", "on the record only")
        heard.human(.patientUnresponsive)
        #expect(heard.state.stateID == "intake_breathing")
    }
}
