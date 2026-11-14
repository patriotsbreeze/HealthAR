import Testing
@testable import RescueCore

@Suite struct CardTests {
    private func engine() throws -> ProtocolEngine { ProtocolEngine(bundle: try loadBundle()) }

    private func value(_ label: String, _ card: HandoffCard) -> HandoffCard.Item? {
        card.items.first { $0.label == label }
    }

    @Test func tappedFactsAreTaggedBystanderAndTimelineDoesNotRepeat() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.human(.scan)
        session.human(.done) // back in compressions, which logs coaching again
        session.human(.aedHere)
        session.human(.padsOn)
        session.human(.aedSaysCpr)
        session.human(.aedAnalyzing) // back in analysis, which logs pads again
        session.human(.shockDelivered)
        session.human(.shockDelivered)
        session.human(.emsArrived)

        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("AED arrived", card)?.source == .bystander)
        #expect(value("Pads on", card)?.source == .bystander)
        #expect(value("Coaching started", card)?.source == .timer)
        #expect(card.timeline.filter { $0.label == "Coaching started" }.count == 1)
        #expect(card.timeline.filter { $0.label == "Pads on" }.count == 1)
        #expect(card.timeline.filter { $0.label == "Shock marked" }.count == 2)
        #expect(card.timeline.filter { $0.label == "EMS arrived" }.first?.source == .bystander)
    }

    @Test func missingFactsSayNotRecordedNeverZero() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.advance(30)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Shocks marked", card)?.value == "not recorded")
        #expect(value("Shocks marked", card)?.source == nil)
        #expect(value("Pads on", card)?.value == "not recorded")
        #expect(!card.readout.contains("Shocks marked: 0"))
    }

    @Test func cardNeverClaimsCprStarted() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Coaching started", card)?.value == "T+0:00")
        let text = (card.items + card.timeline).map(\.label).joined(separator: " ") + card.readout
        #expect(!text.contains("CPR started"))
    }

    @Test func itemsCarrySourceTagsAndMatchTheLog() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.now += 4
        session.modelFinding(.abnormalBreathing)
        session.now += 3
        session.human(.called)
        session.human(.done)
        session.human(.done)
        session.now += 20
        session.human(.aedHere)
        session.human(.padsOn)
        session.human(.shockDelivered)
        session.human(.shockDelivered)

        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Responding", card)?.value == "no")
        #expect(value("Responding", card)?.source == .bystander)
        #expect(value("Breathing normally", card)?.value == "no, abnormal")
        #expect(value("Breathing normally", card)?.source == .aiInferred)
        #expect(value("Coaching started", card)?.value == "T+0:07")
        #expect(value("Coaching started", card)?.source == .timer)
        #expect(value("Pads on", card)?.value == "T+0:27")
        #expect(value("Shocks marked", card)?.value == "2")
        #expect(value("Shocks marked", card)?.source == .bystander)
    }

    /// The question waits for the rescuer, so silence isn't an answer and the card guesses nothing.
    @Test func noReplyRecordsNoAnswer() throws {
        var session = Session(engine: try engine())
        session.advance(60)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Responding", card)?.source != .timer)
        #expect(session.state.stateID == "intake_responsive")
    }

    @Test func readoutFitsThirtySeconds() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.human(.aedHere)
        session.human(.padsOn)
        session.human(.shockDelivered)
        let readout = HandoffBuilder.build(from: session.log.entries).readout
        // About 150 spoken words per minute.
        #expect(readout.split(separator: " ").count <= 75)
    }

    @Test func unconfirmedAddressIsLabeledAndNeverSpoken() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.no)
        let location = CallerLocation(address: "123 Main St", accuracyMeters: 65, confirmed: false)
        let script = CallerScriptBuilder.build(from: session.log.entries, location: location, resources: [.aed])
        #expect(script.locationLine.hasPrefix("Approximate, confirm"))
        #expect(script.locationLine.contains("65 m"))
        #expect(!script.readAloud.contains("123 Main St"))
        #expect(script.readAloud.contains("will confirm the location"))
        #expect(script.readAloud.hasPrefix("I am an AI assistant"))
        #expect(script.situation.contains("not breathing normally"))
        #expect(script.resources == ["aed"])
    }

    @Test func confirmedAddressIsSpoken() throws {
        let session = Session(engine: try engine())
        let location = CallerLocation(address: "123 Main St", accuracyMeters: 65, confirmed: true)
        let script = CallerScriptBuilder.build(from: session.log.entries, location: location, resources: [])
        #expect(script.locationLine == "123 Main St")
        #expect(script.readAloud.contains("The address is 123 Main St."))
    }

    @Test func missingLocationAsksForAddress() throws {
        let session = Session(engine: try engine())
        let script = CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: [])
        #expect(script.locationLine.contains("Location unknown"))
    }

    // MARK: - Only what the log supports

    private func session(_ walk: (inout Session) -> Void) throws -> Session {
        var session = Session(engine: try engine())
        walk(&session)
        return session
    }

    private func situation(_ session: Session) -> String {
        CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: session.state.resources).situation
    }

    @Test func theSituationSaysOnlyWhatTheLogSupports() throws {
        let rows: [(String, (inout Session) -> Void, [String], [String])] = [
            ("not adult", { $0.human(.notAdult) }, ["Child, infant, drowning, or pregnant"], ["Adult"]),
            ("not adult, then back", { $0.human(.notAdult); $0.human(.back) }, ["Adult"], ["Child"]),
            ("yes, then start cpr", { $0.human(.yes); $0.human(.startCpr) }, ["responded earlier"], ["responding."]),
            ("yes only", { $0.human(.yes) }, ["unwell, responding"], ["collapsed"]),
            ("yes, then not responding", { $0.human(.yes); $0.human(.patientUnresponsive) }, ["not responding"], ["unwell"]),
            ("start cpr with nothing asked", { $0.human(.startCpr) }, ["responsiveness not recorded"], ["not responding"]),
            ("not sure on responding", { $0.human(.unsure) }, ["responsiveness not confirmed"], ["not responding"]),
            ("no, no", { $0.human(.no); $0.human(.no) }, ["not responding", "not breathing normally"], ["confirmed"]),
            ("no, not sure", { $0.human(.no); $0.human(.unsure) }, ["breathing not confirmed"], ["not breathing normally"]),
            ("no, yes", { $0.human(.no); $0.human(.yes) }, ["breathing reported"], ["not confirmed"]),
            ("no, yes, no breaths", { $0.human(.no); $0.human(.yes); $0.advance(10) }, ["breathing not confirmed"], ["breathing reported"]),
            ("no, yes, start cpr", { $0.human(.no); $0.human(.yes); $0.human(.startCpr) }, ["breathing reported earlier"], ["not breathing normally"]),
            ("ai heard gasping", { $0.modelFinding(.abnormalBreathing) }, ["not breathing normally"], ["confirmed"]),
        ]
        for (name, walk, says, avoids) in rows {
            let line = situation(try session(walk))
            for words in says { #expect(line.contains(words), "\(name): \(line)") }
            for words in avoids { #expect(!line.contains(words), "\(name): \(line)") }
        }
    }

    @Test func aModelReportedResourceIsTaggedAndATappedOneIsNot() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.model(.reportResources([.gloves, .aed]))
        session.human(.secondPerson)
        var script = CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: session.state.resources)
        #expect(script.resources == ["aed (AI-inferred)", "gloves (AI-inferred)", "second person"])

        // A person saying so outranks the earlier report.
        session.human(.aedHere)
        script = CallerScriptBuilder.build(from: session.log.entries, location: nil, resources: session.state.resources)
        #expect(script.resources == ["aed", "gloves (AI-inferred)", "second person"])
    }

    @Test func aedHereAddsTheResourceWithNoHint() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        session.human(.aedHere)
        #expect(session.state.resources.contains(.aed))
        #expect(session.phrases == ["aed_on"])
        #expect(session.entries(.resourceSeen).last?.source == .bystander)
    }

    @Test func notRespondingNowOverridesAnEarlierYesOnTheCard() throws {
        var session = Session(engine: try engine())
        session.human(.yes)
        session.now += 30
        session.human(.patientUnresponsive)
        session.human(.no)
        session.human(.called)
        session.human(.done)
        session.human(.done)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Responding", card)?.value == "no")
        #expect(value("Responding", card)?.source == .bystander)
        #expect(value("Responding", card)?.time == "T+0:30")
        #expect(value("Breathing normally", card)?.value == "no")
        #expect(card.readout.contains("Responding: no at T+0:30."))
        #expect(!card.readout.contains("Responding: yes"))
    }

    @Test func patientAwakeCountsAsRespondingWhenItHappened() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes)
        session.now += 5
        session.human(.patientAwake)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Responding", card)?.value == "yes")
        #expect(value("Responding", card)?.source == .bystander)
        #expect(value("Responding", card)?.time == "T+0:05")
        #expect(situation(session).contains("unwell, responding"))
    }

    @Test func aWatchThatTimedOutSaysNoBreathsMarked() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.now += 2
        session.human(.yes)
        session.advance(10)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Breathing normally", card)?.value == "no breaths marked")
        #expect(value("Breathing normally", card)?.source == .timer)
        #expect(value("Breathing normally", card)?.time == "T+0:12")
    }

    @Test func theNewestAnswerOutranksAnOlderFindingAndTheCardShowsWhen() throws {
        var session = Session(engine: try engine())
        session.modelFinding(.abnormalBreathing)
        session.now += 40
        session.human(.called)
        session.human(.done)
        session.human(.done)
        session.human(.patientMoving)
        #expect(session.state.stateID == "watch_breathing")
        session.human(.breathMarked)
        session.human(.breathMarked)
        session.advance(10)
        #expect(session.state.stateID == "watch_reask")
        session.human(.yes)

        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Breathing normally", card)?.value == "yes")
        #expect(value("Breathing normally", card)?.source == .bystander)
        #expect(value("Breathing normally", card)?.time == "T+0:50")
    }

    @Test func aFindingNewerThanAnAnswerWinsToo() throws {
        var session = Session(engine: try engine())
        session.human(.no)
        session.human(.yes) // breathing=yes
        session.now += 3
        session.modelFinding(.notBreathing)
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("Breathing normally", card)?.value == "no")
        #expect(value("Breathing normally", card)?.source == .aiInferred)
        #expect(value("Breathing normally", card)?.time == "T+0:03")
    }

    @Test func aStartCprMeansTheCardShows911Prompted() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("911 prompted", card)?.value == "T+0:00")
        #expect(value("911 prompted", card)?.source == .timer)
    }

    @Test func theSpecialCardCountsAs911Prompted() throws {
        var session = Session(engine: try engine())
        session.human(.notAdult)
        #expect(session.phrases == ["special_card"])
        let card = HandoffBuilder.build(from: session.log.entries)
        #expect(value("911 prompted", card)?.value == "T+0:00")
    }

    @Test func eventLogSerializes() throws {
        var session = Session(engine: try engine())
        session.goToCompressions()
        let lines = try session.log.ndjson().split(separator: "\n")
        #expect(lines.count == session.log.entries.count)
        #expect(lines[0].contains("session_started"))
    }
}
