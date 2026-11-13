import Foundation

/// Decides what a model tool call may do. Pure, so it can be fuzzed.
public enum SafetyGate {
    public static let proposalTTL: TimeInterval = 5
    public static let sayCooldown: TimeInterval = 20
    /// A transcript or audit can land this long after its audio, so a line may have been heard
    /// although model speech has since closed.
    public static let heardGrace: TimeInterval = 5
    /// What a collapse sounds like. An awake state has no timeout into CPR to catch one that gets lost.
    private static let collapses: Set<Finding> = [.unresponsive, .notBreathing, .abnormalBreathing]
    /// These still move the rescue after a person has tapped past or backed out, since neither tap
    /// could have known about them.
    private static let dangers: Set<Finding> = [.heavyBleeding, .limbDiscolored, .neckBackInjury]
    private static let staleWorthy = collapses.union(dangers).union([.aspirinUnsafe])

    public enum RejectReason: String, Sendable, Equatable, Codable, CaseIterable {
        case staleVersion = "stale_version"
        case expired
        case cannotLowerUrgency = "cannot_lower_urgency"
        case phraseNotAllowed = "phrase_not_allowed"
        case speechHeld = "speech_held"
        case cooldown
        case notApplicable = "not_applicable"
        case arrestPathLocked = "arrest_path_locked"
    }

    public enum Outcome: Sendable, Equatable {
        case transition(StateDefinition.Transition, finding: Finding)
        case holdModelSpeech(finding: Finding)
        /// Goes on the record and moves nothing.
        case evidence(Finding, source: ObservationSource, confidence: Confidence)
        case say(String)
        case resources([Resource])
        case locate(LocatableObject)
        case note(ModelNote)
    }

    public enum Decision: Sendable, Equatable {
        case allow(Outcome)
        case reject(RejectReason)
    }

    /// A dispatcher or AED has the floor, or a flagged line was just cut off. The authority order
    /// puts all of those above the model, so nothing it asks for may make the phone talk.
    public static func floorHeld(_ state: RescueState, at now: TimeInterval) -> Bool {
        state.callActive || state.dispatcherActive
            || (state.dispatcherHeardUntil ?? 0) > now
            || (state.modelSpeechHoldUntil ?? 0) > now
            || (state.audioPausedUntil ?? 0) > now
    }

    /// The kind check is needed because `watch_breathing` is only urgency 1, so a flow would count as up.
    public static func refusal(from a: StateDefinition, to b: StateDefinition) -> RejectReason? {
        if b.urgency < a.urgency { return .cannotLowerUrgency }
        if a.kind.isArrestPath && !b.kind.isArrestPath { return .arrestPathLocked }
        return nil
    }

    /// - Parameter reportOnly: Lines that answer a report, such as an AED seen. The model reports, and
    ///   can't play them by asking.
    public static func evaluate(
        _ proposal: ModelProposal,
        state: RescueState,
        definition: StateDefinition,
        lookup: (String) -> StateDefinition?,
        at now: TimeInterval,
        reportOnly: Set<String> = []
    ) -> Decision {
        guard proposal.stateVersion == state.version || isStaleEscalation(proposal, state: state, definition: definition)
        else { return .reject(.staleVersion) }
        guard now - proposal.issuedAt <= proposalTTL else { return .reject(.expired) }
        // The router stamps a report on arrival, so how old a stale one is comes from when its version ended.
        if proposal.stateVersion != state.version, now - state.enteredAt > proposalTTL { return .reject(.expired) }

        switch proposal.action {
        case let .reportFinding(finding, source, confidence):
            if finding.wouldLowerUrgency { return .reject(.cannotLowerUrgency) }
            let evidence = Decision.allow(.evidence(finding, source: source, confidence: confidence))
            // The question stands between a talking patient and CPR, so only a tap or its timeout answers it.
            if state.breathingAskedAwake, collapses.contains(finding) { return evidence }
            if let transition = definition.transition(on: "model.\(finding.rawValue)") {
                guard let target = landing(transition.to, padsOn: state.padsOn, lookup: lookup) else {
                    return .reject(.notApplicable)
                }
                if let reason = refusal(from: definition, to: target) { return .reject(reason) }
                if let threshold = transition.minConfidence, confidence < threshold { return evidence }
                // Back to the same step, all it can do is say its line again, so it keeps say's cooldown.
                if transition.to == definition.id,
                   transition.phrases?.contains(where: { phrase in state.lastSaid[phrase].map { now - $0 < sayCooldown } ?? false }) == true {
                    return evidence
                }
                // A person backed out of this flow, and the same report shouldn't undo that at once.
                if let flow = target.flow, state.declinedFlows.contains(flow), !dangers.contains(finding) { return evidence }
                return .allow(.transition(transition, finding: finding))
            }
            if finding == .dispatcherSpeaking || finding == .aedPrompting {
                return .allow(.holdModelSpeech(finding: finding))
            }
            return definition.kind.isAwake ? evidence : .reject(.notApplicable)

        case let .reportResources(items):
            return .allow(.resources(items))

        case let .say(phraseID):
            guard definition.allowedSay.contains(phraseID), !reportOnly.contains(phraseID) else { return .reject(.phraseNotAllowed) }
            guard !floorHeld(state, at: now) else { return .reject(.speechHeld) }
            if let last = state.lastSaid[phraseID], now - last < sayCooldown { return .reject(.cooldown) }
            return .allow(.say(phraseID))

        case let .locateObject(object):
            guard definition.frameUplink else { return .reject(.notApplicable) }
            return .allow(.locate(object))

        case let .logEvent(note):
            return .allow(.note(note))
        }
    }

    /// A collapse, danger, or aspirin report quoting a version from a few seconds earlier still
    /// stands, unless it predates the tap that said the patient is awake, which outranks it.
    private static func isStaleEscalation(_ proposal: ModelProposal, state: RescueState, definition: StateDefinition) -> Bool {
        guard definition.kind.isAwake, proposal.stateVersion < state.version,
              let awakeSince = state.awakeSinceVersion, proposal.stateVersion >= awakeSince,
              case let .reportFinding(finding, _, _) = proposal.action
        else { return false }
        return staleWorthy.contains(finding)
    }

    /// Where the engine would really end up, since pads can redirect a transition.
    private static func landing(_ id: String, padsOn: Bool, lookup: (String) -> StateDefinition?) -> StateDefinition? {
        guard let requested = lookup(id) else { return nil }
        if padsOn, let redirect = requested.afterPads { return lookup(redirect) }
        return requested
    }
}
