import Foundation

public struct RescueState: Sendable, Equatable {
    public var stateID: String
    /// Increases on every transition. Model calls must quote the current value.
    public var version = 0
    public var startedAt: TimeInterval
    public var enteredAt: TimeInterval
    public var metronomeOn = false
    public var breathsMarked = 0
    public var callActive = false
    public var dispatcherActive = false
    /// A dispatcher was reported audible. The mic stays closed until this passes.
    public var dispatcherHeardUntil: TimeInterval?
    /// Set on entering AED analysis and kept for the rest of the rescue.
    public var padsOn = false
    /// Set on entering any CPR state and kept for the rest of the rescue.
    public var cprStarted = false
    /// A person said the AED is here, so where one was seen earlier is no use. Kept for the rest of the rescue.
    public var aedArrived = false
    /// The version this run of awake states began at. Nil outside them.
    public var awakeSinceVersion: Int?
    /// On the breathing question, reached from an awake state, or marking breaths after a Yes to it.
    /// Cleared on leaving those.
    public var breathingAskedAwake = false
    /// Set on advising a dose and kept for the rest of the rescue, so there's never a second.
    public var aspirinAdvised = false
    /// The app has said no aspirin, or someone reported a risk. Kept for the rest of the rescue, so a
    /// later answer can't turn that into a dose.
    public var aspirinRuledOut = false
    /// The AI's voice is mid-turn in an awake state, so a re-ask waits. A local phrase would cut it off.
    public var modelTurnActive = false
    /// Flows a person backed out of. A report can't choose one again until a person does.
    public var declinedFlows: Set<String> = []
    public var audioPausedUntil: TimeInterval?
    public var audioPausedFor: AudioKeyword?
    public var lastModelPause: TimeInterval?
    public var modelSpeechHoldUntil: TimeInterval?
    /// Nil while model speech is open.
    public var modelSpeechClosedAt: TimeInterval?
    public var resources: Set<Resource> = []
    public var promptClock: [String: TimeInterval] = [:]
    public var lastSaid: [String: TimeInterval] = [:]
    public var recentlyPlayed: [String] = []
}

public struct ReduceResult: Sendable, Equatable {
    public var state: RescueState
    public var effects: [RescueEffect] = []
    public var log: [LogEntry.Draft] = []
}

/// The on-device protocol. A pure reducer: no clock, I/O, or randomness, so runs replay exactly.
/// The engine alone decides the next instruction. See `SAFETY.md`.
public struct ProtocolEngine: Sendable {
    /// How long past its time a re-ask waits for the AI's turn to end.
    public static let reaskHoldSeconds: TimeInterval = 8
    /// How long past its timeout assess waits while someone is describing what happened, or the AI is
    /// answering them. That's the assessment working, but a turn that never ends can't hold it forever.
    public static let assessHoldSeconds: TimeInterval = 15

    public let bundle: ProtocolBundle
    private let states: [String: StateDefinition]

    public init(bundle: ProtocolBundle) {
        self.bundle = bundle
        states = Dictionary(uniqueKeysWithValues: bundle.definition.states.map { ($0.id, $0) })
    }

    public func definition(of id: String) -> StateDefinition? { states[id] }

    /// Someone on the phone hasn't missed anything, and every awake timer ends in a safer branch, so
    /// an awake step waits for them. The arrest path doesn't.
    public func timersWait(for state: RescueState) -> Bool {
        states[state.stateID]?.kind.isAwake == true && (state.callActive || state.dispatcherActive)
    }

    public func start(at now: TimeInterval) -> ReduceResult {
        let initial = bundle.definition.initialState
        var result = ReduceResult(state: RescueState(stateID: initial, startedAt: now, enteredAt: now))
        result.log.append(.init(kind: .sessionStarted, source: .timer))
        enter(initial, into: &result, at: now)
        return result
    }

    public func policy(for state: RescueState, at now: TimeInterval) -> RuntimePolicy {
        let gateOpen = bundle.definition.speechGate.openStates.contains(state.stateID)
        let definition = states[state.stateID]
        let dispatcherHeard = (state.dispatcherHeardUntil ?? 0) > now
        return RuntimePolicy(
            modelSpeechOpen: gateOpen && !SafetyGate.floorHeld(state, at: now),
            micUplink: !state.callActive && !state.dispatcherActive && !dispatcherHeard,
            frameUplink: (definition?.frameUplink ?? false) && !state.callActive,
            audioMode: state.callActive ? .playbackOnly : .full,
            // Assess is looking for what's wrong, so it sends at the steady rate and not just in bursts.
            frameBurstsOnly: definition?.kind.isAwake == true && state.stateID != ScenarioModule.assessState,
            modelAudioWaitsForPhrases: definition?.kind.isAwake == true,
            aedFindsCarry: definition?.kind.isAwake == true,
            showsCarriedAED: state.stateID == ScenarioModule.carriedAEDState && !state.aedArrived,
            // Closed on a call like the uplink, so nothing leaves the phone while someone else is on it.
            frameLocate: (definition?.locateMaterials ?? false) && !state.callActive
        )
    }

    /// What the app may look for in the room right now: every material the flow's cues name, so a
    /// scan started at the flow's first step covers the later ones. Empty unless the step allows it.
    public func materialsToLocate(for state: RescueState, at now: TimeInterval) -> [Material] {
        guard policy(for: state, at: now).frameLocate, let definition = states[state.stateID] else { return [] }
        return bundle.materials(inFlowOf: definition)
    }

    public func reduce(_ state: RescueState, _ event: RescueEvent, at now: TimeInterval) -> ReduceResult {
        var result = ReduceResult(state: state)
        guard let definition = states[state.stateID] else { return result }

        switch event {
        case let .human(action):
            handle(human: action, definition: definition, into: &result, at: now)
        case let .model(proposal):
            handle(proposal: proposal, definition: definition, into: &result, at: now)
        case .tick:
            handleTick(definition: definition, into: &result, at: now)
        case let .callChanged(active):
            guard result.state.callActive != active else { break }
            result.state.callActive = active
            result.log.append(.init(kind: .callChanged, source: .sensor, detail: active ? "active" : "ended"))
            if active { result.effects.append(.flushModelAudio) } else { restartAwakeClocks(definition, into: &result, at: now) }
            publishPolicy(into: &result, at: now)
        case let .keyword(keyword):
            // Pauses audio only. A keyword can never change state.
            if keyword == .dispatcherTalking { closeMicForDispatcher(into: &result, at: now) }
            pauseAudio(for: keyword, source: .sensor, into: &result, at: now)
            publishPolicy(into: &result, at: now)
        case let .sentinelFlag(flag):
            result.log.append(.init(kind: .sentinelFlag, source: .aiInferred, detail: flag.category.rawValue))
            let correction = correctionPhrase(for: flag, definition: definition, state: result.state, at: now)
            result.state.modelSpeechHoldUntil = now + bundle.definition.modelSpeechHoldSeconds
            result.effects.append(.flushModelAudio)
            if let correction {
                result.state.lastSaid[correction] = now
                result.effects.append(.playPhrase(correction))
            }
            publishPolicy(into: &result, at: now)
        case let .phrasePlayed(id):
            result.state.recentlyPlayed = Array((result.state.recentlyPlayed + [id]).suffix(3))
            result.log.append(.init(kind: .phrasePlayed, source: .system, detail: id))
        case let .modelTurn(active):
            result.state.modelTurnActive = active && definition.kind.isAwake
        }
        return result
    }

    // MARK: - Human

    private func handle(human action: HumanAction, definition: StateDefinition, into result: inout ReduceResult, at now: TimeInterval) {
        switch action {
        case .breathMarked:
            guard definition.timeout?.ifBreathsAtLeast != nil else { return }
            result.state.breathsMarked += 1
            result.log.append(.init(kind: .breathMarked, source: .bystander))
            return
        case .shockDelivered:
            guard definition.id == "aed_analyze" || definition.id == "compressions_aed" else { return }
            result.log.append(.init(kind: .shockMarked, source: .bystander))
            return
        case .metronomeOn, .metronomeOff:
            guard definition.metronomeToggleable else { return }
            let on = action == .metronomeOn
            guard result.state.metronomeOn != on else { return }
            result.state.metronomeOn = on
            result.effects.append(.metronome(on: on))
            return
        case .dispatcherOn, .dispatcherOff:
            result.state.dispatcherActive = action == .dispatcherOn
            if action == .dispatcherOn { result.effects.append(.flushModelAudio) } else { restartAwakeClocks(definition, into: &result, at: now) }
            publishPolicy(into: &result, at: now)
            return
        case .secondPerson:
            let added = noteResources([.secondPerson], source: .bystander, into: &result)
            // A person asked, so the model's allowlist doesn't apply on the arrest path. The AED still
            // has the floor. "Find an AED" means nothing on a broken arm, so an awake step has to list it.
            if !added.isEmpty, !definition.aedHasAuthority, let hint = bundle.definition.resourceHints[Resource.secondPerson.rawValue],
               !definition.kind.isAwake || definition.allowedSay.contains(hint) {
                result.effects.append(.playPhrase(hint))
            }
            return
        default:
            break
        }

        guard let transition = definition.transition(on: "human.\(action.rawValue)") else { return }
        if let answer = answerDetail(for: action, definition: definition) {
            result.log.append(.init(kind: .answer, source: .bystander, detail: answer))
        }
        if action == .patientMoving || action == .patientAwake {
            result.log.append(.init(kind: .patientMoved, source: .bystander))
        }
        if action == .aedHere {
            _ = noteResources([.aed], source: .bystander, into: &result)
        }
        if action == .notThis, let flow = definition.flow { result.state.declinedFlows.insert(flow) }
        enter(
            transition.to,
            via: transition,
            keepingQueued: keptPhrases(after: action, on: definition),
            by: .bystander,
            into: &result,
            at: now
        )
    }

    /// Tapping on means what was still waiting to be said is stale. The call prompt stays, unless this
    /// tap is the person answering it. Called always is, and Done only on a step that opens with the
    /// call prompt, since on any other it can land before the prompt was heard. A step's other lines
    /// are required steps of their own, so answering the call doesn't take them.
    /// Said on the way, never asked for: no step waits on them, and the deck never shows them as the
    /// instruction. "Calling 911 for you" is said while the 911 agent calls in the background.
    public static let announcementPhrases: Set<String> = ["calling_911"]

    private func keptPhrases(after action: HumanAction, on definition: StateDefinition) -> [String] {
        let keep = bundle.definition.keepQueuedPhrases
        guard definition.logOnEnter == .callPrompted, action == .called || action == .done,
              // A step that only announces the call, as positioning does while the 911 agent calls,
              // asks nothing of the rescuer about it: Done there answers the step's own line.
              !definition.entryPhrases.contains(where: Self.announcementPhrases.contains)
        else { return keep }
        let others = definition.entryPhrases.filter { !keep.contains($0) }
        let answered = action == .called || definition.entryPhrases.first.map(keep.contains) == true
        return answered ? others : keep + others
    }

    private func answerDetail(for action: HumanAction, definition: StateDefinition) -> String? {
        switch action {
        case .yes, .no, .unsure: definition.question.map { "\($0.rawValue)=\(action.rawValue)" }
        case .notAdult: "adult=no"
        case .back: "adult=back"
        case .patientUnresponsive: "responsive=no"
        case .patientNotBreathing: "breathing=no"
        case .patientAwake: "responsive=yes"
        default: nil
        }
    }

    // MARK: - Model

    private func handle(proposal: ModelProposal, definition: StateDefinition, into result: inout ReduceResult, at now: TimeInterval) {
        let decision = SafetyGate.evaluate(
            proposal,
            state: result.state,
            definition: definition,
            lookup: self.definition(of:),
            at: now,
            reportOnly: reportOnlyLines(in: definition)
        )
        // At any confidence and on any step: all this can do is take aspirin away.
        if case .allow = decision, case .reportFinding(.aspirinUnsafe, _, _) = proposal.action {
            result.state.aspirinRuledOut = true
        }
        switch decision {
        case let .reject(reason):
            result.log.append(.init(kind: .proposalRejected, source: .aiInferred, detail: "\(proposal.summary): \(reason.rawValue)"))
            // On a question the bystander can still answer for themselves. Elsewhere it only shows on the panel.
            if reason == .cannotLowerUrgency,
               case let .reportFinding(finding, _, _) = proposal.action,
               let phrase = promptAfterRejectedLowering(finding, definition: definition, state: result.state),
               !SafetyGate.floorHeld(result.state, at: now),
               result.state.lastSaid[phrase].map({ now - $0 >= SafetyGate.sayCooldown }) ?? true {
                result.state.lastSaid[phrase] = now
                result.effects.append(.playPhrase(phrase))
            }
        case let .allow(.transition(transition, finding)):
            result.log.append(.init(kind: .finding, source: .aiInferred, detail: finding.rawValue))
            if definition.kind.isAwake, case let .reportFinding(_, source, confidence) = proposal.action {
                result.log.append(observation(finding, source: source, confidence: confidence))
            }
            enter(transition.to, via: transition, keepingQueued: bundle.definition.keepQueuedPhrases, by: .aiInferred, into: &result, at: now)
        case let .allow(.evidence(finding, source, confidence)):
            result.log.append(observation(finding, source: source, confidence: confidence))
        case let .allow(.holdModelSpeech(finding)):
            result.state.modelSpeechHoldUntil = now + bundle.definition.modelSpeechHoldSeconds
            result.effects.append(.flushModelAudio)
            result.log.append(.init(kind: .finding, source: .aiInferred, detail: finding.rawValue))
            if finding == .dispatcherSpeaking { closeMicForDispatcher(into: &result, at: now) }
            if finding == .aedPrompting { pauseForModelReport(definition: definition, into: &result, at: now) }
            publishPolicy(into: &result, at: now)
        case let .allow(.say(phrase)):
            result.state.lastSaid[phrase] = now
            result.effects.append(.playPhrase(phrase))
        case let .allow(.resources(items)):
            for item in noteResources(items, source: .aiInferred, into: &result) {
                // A hint is the model making the phone talk, so it follows the same rules as say.
                guard let hint = resourceHint(for: item, in: definition),
                      definition.allowedSay.contains(hint),
                      !SafetyGate.floorHeld(result.state, at: now)
                else { continue }
                result.state.lastSaid[hint] = now
                result.effects.append(.playPhrase(hint))
            }
        case let .allow(.locate(object)):
            result.effects.append(.locate(object))
        case let .allow(.note(note)):
            result.log.append(.init(kind: .modelNote, source: .aiInferred, detail: note.rawValue))
        }
    }

    /// An awake step lists its resource lines in `allowed_say` to say where they play. They answer a report,
    /// so a say can't play one, and neither can a line listed only for a cue to point from. Core's lines
    /// stay as they were.
    private func reportOnlyLines(in definition: StateDefinition) -> Set<String> {
        definition.kind.isAwake ? Set(bundle.awakeResourceHints.values).union(definition.cueOnlyLines) : []
    }

    /// Core's AED line says "Keep pushing", which is no line for someone awake.
    private func resourceHint(for item: Resource, in definition: StateDefinition) -> String? {
        let awake = definition.kind.isAwake ? bundle.awakeResourceHints[item.rawValue] : nil
        return awake ?? bundle.definition.resourceHints[item.rawValue]
    }

    private func observation(_ finding: Finding, source: ObservationSource, confidence: Confidence) -> LogEntry.Draft {
        .init(kind: .observation, source: .aiInferred, detail: "\(finding.rawValue),\(source.rawValue),\(confidence.rawValue)")
    }

    /// Yes on a question asks the bystander to lower urgency, so that prompt is only for a report
    /// that answers the question on screen. Otherwise Yes would mean something they didn't say,
    /// and the most to do is ask again, once the question has been heard.
    private func promptAfterRejectedLowering(_ finding: Finding, definition: StateDefinition, state: RescueState) -> String? {
        // "If you are sure, tap yes. If not, we start CPR" is no answer to anything asked of someone awake.
        guard definition.kind.isArrestPath, let question = definition.question else { return nil }
        let answersQuestion = (question == .responsive && finding == .responsive)
            || (question == .breathing && finding == .breathingNormally)
        if answersQuestion { return bundle.definition.loweringReportPhrase }
        guard let asked = definition.entryPhrases.first, state.recentlyPlayed.last == asked else { return nil }
        return asked
    }

    /// Returns the ones not already known. A person saying so is logged again, since it outranks
    /// an earlier AI report.
    private func noteResources(_ items: [Resource], source: EvidenceSource, into result: inout ReduceResult) -> [Resource] {
        var added: [Resource] = []
        for item in items {
            let isNew = result.state.resources.insert(item).inserted
            if isNew { added.append(item) }
            if isNew || source == .bystander {
                result.log.append(.init(kind: .resourceSeen, source: source, detail: item.rawValue))
            }
        }
        return added
    }

    // MARK: - Audio and mic

    private func pauseAudio(for reason: AudioKeyword, source: EvidenceSource, into result: inout ReduceResult, at now: TimeInterval) {
        let seconds = bundle.definition.audioPauseSeconds
        result.state.audioPausedUntil = now + seconds
        result.state.audioPausedFor = reason
        result.effects.append(.pauseAudio(seconds: seconds))
        result.log.append(.init(kind: .audioPaused, source: source, detail: reason.rawValue))
    }

    /// The AED outranks the protocol, so a report of it talking quiets the phone without leaving
    /// the step. Output only, and rate limited, so a model stuck on this can't take the beat away.
    private func pauseForModelReport(definition: StateDefinition, into result: inout ReduceResult, at now: TimeInterval) {
        guard definition.kind == .cpr,
              result.state.lastModelPause.map({ now - $0 >= SafetyGate.sayCooldown }) ?? true
        else { return }
        result.state.lastModelPause = now
        pauseAudio(for: .aedTalking, source: .aiInferred, into: &result, at: now)
    }

    /// Bounded, because the model can't report the dispatcher stopping once it can't hear them.
    private func closeMicForDispatcher(into result: inout ReduceResult, at now: TimeInterval) {
        result.state.dispatcherHeardUntil = now + bundle.definition.dispatcherMicHoldSeconds
    }

    /// A correction answers a line someone could have heard. Audio dropped behind a closed gate
    /// needs none, a hold means this one was cut off and the last correction is still landing,
    /// and a state with nothing to say and no model voice stays quiet: AED analysis and the cards.
    private func correctionPhrase(for flag: SentinelFlag, definition: StateDefinition, state: RescueState, at now: TimeInterval) -> String? {
        guard let phrase = correctionID(for: flag.category, in: definition) else { return nil }
        let gateOpen = bundle.definition.speechGate.openStates.contains(state.stateID)
        // A flow closes the voice on entry, right after the AI line that routed here may have been heard.
        if definition.allowedSay.isEmpty, !gateOpen, !definition.kind.isAwake { return nil }
        if SafetyGate.floorHeld(state, at: now) { return nil }
        if let closedAt = state.modelSpeechClosedAt, now - closedAt >= SafetyGate.heardGrace { return nil }
        if let last = state.lastSaid[phrase], now - last < SafetyGate.sayCooldown { return nil }
        return phrase
    }

    /// In an awake state an arrest-only line is still cut, but "treat it as not breathing" is no
    /// answer to it with the patient talking, so it gets no spoken correction.
    private func correctionID(for category: SentinelFlag.Category, in definition: StateDefinition) -> String? {
        let raw = category.rawValue
        guard definition.kind.isAwake else { return bundle.definition.correctionPhrases[raw] }
        guard SentinelFlag.Category.awakeCases.contains(category) else { return nil }
        return bundle.awakeCorrectionPhrases[raw] ?? bundle.definition.correctionPhrases[raw]
    }

    // MARK: - Time

    private func handleTick(definition: StateDefinition, into result: inout ReduceResult, at now: TimeInterval) {
        if let until = result.state.audioPausedUntil, now >= until {
            result.state.audioPausedUntil = nil
            result.state.audioPausedFor = nil
            result.effects.append(.resumeAudio)
            publishPolicy(into: &result, at: now)
        }
        if let until = result.state.modelSpeechHoldUntil, now >= until {
            result.state.modelSpeechHoldUntil = nil
            publishPolicy(into: &result, at: now)
        }
        if let until = result.state.dispatcherHeardUntil, now >= until {
            result.state.dispatcherHeardUntil = nil
            publishPolicy(into: &result, at: now)
        }
        if timersWait(for: result.state) { return }

        let describing = definition.id == ScenarioModule.assessState && result.state.modelTurnActive
            && now - result.state.enteredAt < (definition.timeout?.seconds ?? 0) + Self.assessHoldSeconds
        if let timeout = definition.timeout, now - result.state.enteredAt >= timeout.seconds, !describing {
            var target = timeout.to
            if let guardRule = timeout.ifBreathsAtLeast, result.state.breathsMarked >= guardRule.count {
                target = guardRule.to
            }
            if let question = definition.question {
                result.log.append(.init(kind: .answer, source: .timer, detail: "\(question.rawValue)=no_reply"))
            } else if timeout.ifBreathsAtLeast != nil, target == timeout.to {
                result.log.append(.init(kind: .answer, source: .timer, detail: "breathing=no_breaths_marked"))
            }
            // Nobody tapped past anything, so queued steps still play. This is the no-touch path.
            enter(target, via: timeout.phrases.map { .init(on: "timeout", to: target, phrases: $0) }, into: &result, at: now)
            return
        }

        for prompt in definition.repeating {
            let last = result.state.promptClock[prompt.phrase] ?? result.state.enteredAt
            if now - last >= prompt.everySeconds {
                if result.state.modelTurnActive, now - last < prompt.everySeconds + Self.reaskHoldSeconds { continue }
                result.state.promptClock[prompt.phrase] = now
                result.effects.append(.playPhrase(prompt.phrase))
            }
        }
    }

    /// The step waited for the call, so its clocks start over rather than firing the moment it ends.
    private func restartAwakeClocks(_ definition: StateDefinition, into result: inout ReduceResult, at now: TimeInterval) {
        guard definition.kind.isAwake else { return }
        result.state.enteredAt = now
        for prompt in definition.repeating { result.state.promptClock[prompt.phrase] = now }
    }

    // MARK: - Entering a state

    /// `keepingQueued` nil leaves queued phrases alone. Otherwise the rest are stale and go first.
    private func enter(
        _ requested: String,
        via transition: StateDefinition.Transition? = nil,
        keepingQueued: [String]? = nil,
        by source: EvidenceSource = .timer,
        into result: inout ReduceResult,
        at now: TimeInterval
    ) {
        // A dose is advised once, so reaching it again goes on to where the step would have ended. Once
        // aspirin is ruled out, it goes the way a report on that step would, and says no again.
        let dose = states[requested]?.logOnEnter == .aspirinAdvised ? states[requested] : nil
        let refused = result.state.aspirinRuledOut ? dose?.transition(on: "model.\(Finding.aspirinUnsafe.rawValue)") : nil
        let doseGiven = result.state.aspirinAdvised ? dose?.timeout?.to : nil
        let destination = refused?.to ?? doseGiven ?? requested
        let transition = refused ?? transition
        // Pads stay on, so the AED stays the authority and the setup steps are long past. A patient
        // who woke after CPR stays on the static card too, with no aspirin or free AI.
        let target = states[destination]
        let redirects = result.state.padsOn || (result.state.cprStarted && target?.kind.isAwake == true)
        let afterPads = redirects ? target?.afterPads : nil
        guard let definition = states[afterPads ?? destination] else { return }
        let previous = states[result.state.stateID]

        result.state.stateID = definition.id
        result.state.version += 1
        result.state.enteredAt = now
        result.state.breathsMarked = 0
        if definition.aedHasAuthority { result.state.padsOn = true }
        if definition.kind == .cpr { result.state.cprStarted = true }
        if definition.logOnEnter == .aedArrived { result.state.aedArrived = true }
        result.state.awakeSinceVersion = definition.kind.isAwake ? result.state.awakeSinceVersion ?? result.state.version : nil
        // A Yes to that question keeps it standing in the watch states, or the next report there is CPR.
        result.state.breathingAskedAwake = (definition.id == ScenarioModule.breathingQuestion && previous?.kind.isAwake == true)
            || (result.state.breathingAskedAwake && definition.kind == .watch)
        // Ids from an awake step mean nothing to whichever session comes next.
        if previous?.kind.isAwake == true, !definition.kind.isAwake { result.state.recentlyPlayed = [] }
        if !definition.kind.isAwake { result.state.modelTurnActive = false }
        if definition.logOnEnter == .aspirinAdvised { result.state.aspirinAdvised = true }
        if transition?.phrases?.contains(where: ScenarioModule.noAspirinPhrases.contains) == true { result.state.aspirinRuledOut = true }
        // The gate holds a self-edge to this, so one report can't be made to say its line over and over.
        if definition.kind.isAwake {
            for phrase in transition?.phrases ?? [] { result.state.lastSaid[phrase] = now }
        }
        if source == .bystander, let flow = definition.flow { result.state.declinedFlows.remove(flow) }

        // A prompt runs on across states that share it. One starting up here hasn't just been said.
        let running = Set(previous?.repeating.map(\.phrase) ?? [])
        for prompt in definition.repeating
        where !running.contains(prompt.phrase) || result.state.promptClock[prompt.phrase] == nil {
            result.state.promptClock[prompt.phrase] = now
        }

        let shouldClick = definition.metronome == .on
        if result.state.metronomeOn != shouldClick {
            result.state.metronomeOn = shouldClick
            result.effects.append(.metronome(on: shouldClick))
        }

        // A local phrase always wins over model audio.
        result.effects.append(.flushModelAudio)
        result.effects.append(.overlay(definition.overlay))
        // Every entry, so a step with none clears what the last one pointed at.
        result.effects.append(.cues(definition.cues))
        publishPolicy(into: &result, at: now)

        if definition.aedHasAuthority || transition?.cutsPhrases == true {
            result.effects.append(.cutPhrases)
        } else if let keepingQueued {
            result.effects.append(.dropQueuedPhrases(keeping: keepingQueued))
        }
        if afterPads == nil {
            result.effects.append(contentsOf: (transition?.phrases ?? []).map(RescueEffect.playPhrase))
        }
        result.effects.append(contentsOf: definition.entryPhrases.map(RescueEffect.playPhrase))

        result.log.append(.init(kind: .stateEntered, source: .system, detail: definition.id))
        if let flow = definition.flow, flow != previous?.flow {
            result.log.append(.init(kind: .flowEntered, source: source, detail: flow))
        }
        if afterPads == nil, let kind = transition?.log {
            result.log.append(.init(kind: kind, source: .timer))
        }
        if let kind = definition.logOnEnter {
            // Some of these only happen because a person tapped, so they aren't timer facts.
            let tapped: Set<LogEntry.Kind> = [.aedArrived, .padsOn, .emsArrived, .aspirinAdvised]
            result.log.append(.init(kind: kind, source: tapped.contains(kind) ? .bystander : .timer))
        }
        result.effects.append(.sendStateBrief(brief(for: result.state, definition: definition, at: now)))
    }

    private func publishPolicy(into result: inout ReduceResult, at now: TimeInterval) {
        let current = policy(for: result.state, at: now)
        if current.modelSpeechOpen {
            result.state.modelSpeechClosedAt = nil
        } else if result.state.modelSpeechClosedAt == nil {
            result.state.modelSpeechClosedAt = now
        }
        result.effects.append(.policyChanged(current))
    }

    public func brief(for state: RescueState, definition: StateDefinition, at now: TimeInterval) -> StateBrief {
        var brief = StateBrief(
            version: state.version,
            stateID: state.stateID,
            allowedSay: definition.allowedSay,
            modelSpeechOpen: policy(for: state, at: now).modelSpeechOpen,
            recentlyPlayed: state.recentlyPlayed,
            resources: state.resources.map(\.rawValue).sorted(),
            elapsedSeconds: Int(now - state.startedAt)
        )
        guard definition.kind.isAwake else { return brief }
        brief.mode = .awake
        brief.flow = definition.flow
        brief.allowedSay = definition.allowedSay.filter { !reportOnlyLines(in: definition).contains($0) }
        // Never the dose line, which the model must not learn to repeat. `aspirin` says it was given.
        if definition.logOnEnter != .aspirinAdvised {
            brief.stepText = definition.entryPhrases.compactMap(bundle.text(forPhrase:)).joined(separator: " ")
        }
        brief.aspirin = state.aspirinRuledOut ? .ruledOut : state.aspirinAdvised ? .advised : .notAsked
        return brief
    }
}
