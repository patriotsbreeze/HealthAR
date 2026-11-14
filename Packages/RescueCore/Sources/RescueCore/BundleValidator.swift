import Foundation

/// What the loader refuses. A bad core stops the app at the fallback card. A bad module is dropped
/// whole and named, and core runs on as if the file had never shipped.
public enum BundleValidator {
    /// `ProtocolEngine.init` traps on a duplicate state id, and a dangling reference would strand
    /// the flow, so bad data has to stop here.
    public static func isRunnable(_ bundle: ProtocolBundle) -> Bool {
        let definition = bundle.definition
        let stateIDs = Set(definition.states.map(\.id))
        let phraseIDs = Set(bundle.phrases.phrases.map(\.id))
        guard stateIDs.count == definition.states.count, stateIDs.contains(definition.initialState) else { return false }

        return definition.states.allSatisfy { state in
            let targets = state.transitions.map(\.to)
                + [state.timeout?.to, state.timeout?.ifBreathsAtLeast?.to, state.afterPads].compactMap { $0 }
            let phrases = state.entryPhrases + state.repeating.map(\.phrase) + (state.timeout?.phrases ?? [])
                + state.transitions.flatMap { $0.phrases ?? [] }
            // Cues and the locate permission are a module's, on awake steps only. Core's frozen
            // file has none, and only modules have awake steps.
            let cueFree = state.kind.isAwake || (state.cues.isEmpty && !state.locateMaterials)
            return cueFree && targets.allSatisfy(stateIDs.contains) && phrases.allSatisfy(phraseIDs.contains)
        }
    }

    private static let maxPhraseWords = 14
    /// A chip on the camera is read at a glance.
    private static let maxCalloutWords = 4
    private static let flowPrefix = "possible_"
    /// All a module may record. The rest belong to a rescue that really reached CPR, the AED, or EMS,
    /// and `pads_on` also hands the AED the floor for the rest of the rescue.
    private static let stateLogs: Set<LogEntry.Kind> = [.callPrompted, .aspirinAdvised]
    /// `aspirin_advised` only counts on the state, because that's what marks it as `isHumanOnly`.
    private static let edgeLogs: Set<LogEntry.Kind> = [.callPrompted]
    /// Core's phrases coach CPR, so these are all an awake state may borrow.
    private static let sharedPhrases: Set<String> = ["call_911", "assign_helper"]
    /// The one approved dose, word for word, so a bad file can't change the amount and keep the id.
    private static let approvedDose = (id: "aspirin_give", text: "Chew and swallow one 325 mg aspirin, or two 81 mg.")
    private static let humanKeys = Set(HumanAction.allCases.map { "human.\($0.rawValue)" })
    private static let findings = Dictionary(uniqueKeysWithValues: Finding.allCases.map { ("model.\($0.rawValue)", $0) })

    /// What's wrong with the file itself, judged before any of it is merged.
    static func refusal(of module: ScenarioModule, joining base: ProtocolBundle) -> String? {
        if let flow = module.flow {
            guard flow.id.hasPrefix(flowPrefix) else { return "flow id must start with \(flowPrefix): \(flow.id)" }
            // The why panel shows this as written, so it's held to the same word as the id.
            guard flow.title.lowercased().hasPrefix("possible ") else { return "flow title must say possible: \(flow.title)" }
            guard !base.flows.contains(where: { $0.id == flow.id }) else { return "flow id collision: \(flow.id)" }
        }

        let texts = Dictionary(module.phrases.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var stateIDs = Set(base.definition.states.map(\.id))
        for state in module.states {
            guard stateIDs.insert(state.id).inserted else { return "state id collision: \(state.id)" }
            guard state.kind.isAwake else { return "state kind \(state.kind.rawValue): \(state.id)" }
            guard state.metronome == .off, !state.metronomeToggleable else { return "metronome not off: \(state.id)" }
            guard !state.citation.isEmpty else { return "state has no citation: \(state.id)" }
            guard state.flow == nil || state.flow == module.flow?.id else { return "undeclared flow: \(state.id)" }
            if let log = state.logOnEnter, !stateLogs.contains(log) { return "reserved log \(log.rawValue): \(state.id)" }
            // Zero would re-enter on every tick, replaying phrases and making every report stale.
            if let seconds = state.timeout?.seconds, seconds <= 0 { return "timeout not above 0: \(state.id)" }
            guard state.repeating.allSatisfy({ $0.everySeconds > 0 }) else { return "repeat not above 0: \(state.id)" }
            guard !state.allowsPpg else { return "allows_ppg: \(state.id)" }
            guard state.overlay != .padZones else { return "pad zones: \(state.id)" }
            // A repeat Yes goes where this ends, so a second dose has nowhere to come from.
            if state.logOnEnter == .aspirinAdvised, state.timeout == nil { return "aspirin step has no timeout: \(state.id)" }
            if let reason = cueRefusal(of: state, in: module, texts: texts) { return reason }
        }

        var phraseIDs = Set(base.phrases.phrases.map(\.id))
        for phrase in module.phrases {
            guard phraseIDs.insert(phrase.id).inserted else { return "phrase id collision: \(phrase.id)" }
            guard phrase.text.split(separator: " ").count <= maxPhraseWords else { return "phrase over \(maxPhraseWords) words: \(phrase.id)" }
            guard !phrase.citation.isEmpty else { return "phrase has no citation: \(phrase.id)" }
            let approved = phrase.id == approvedDose.id && phrase.text == approvedDose.text
            if !approved, let flag = TranscriptValidator.check(phrase.text, profile: .awake).first {
                return "phrase breaks the \(flag.category.rawValue) rule: \(phrase.id)"
            }
            if !approved, advisesMedicine(phrase.text) { return "phrase advises a medicine: \(phrase.id)" }
        }

        let states = table(base.definition.states + module.states)
        for entry in module.entries {
            guard let state = states[entry.state] else { return "entry on unknown state: \(entry.state)" }
            guard !state.kind.isArrestPath else { return "\(SafetyGate.RejectReason.arrestPathLocked.rawValue): entry on \(state.id)" }
            // A card shows every tap edge as a button, on arrest-only rescues too.
            guard state.kind.isAwake || entry == ScenarioModule.onlyGraftableCoreEntry else { return "core entry can't graft: \(state.id) \(entry.edge.on)" }
        }
        for replaced in module.replacedEdges {
            guard let state = states[replaced.state], state.transition(on: replaced.edge.on) != nil else {
                return "replaces unknown edge: \(replaced.state) \(replaced.edge.on)"
            }
            if state.kind.isAwake {
                guard !ScenarioModule.injectedKeys.contains(replaced.edge.on) else { return "replaces injected edge: \(state.id) \(replaced.edge.on)" }
            } else {
                guard replaced == ScenarioModule.onlyMovableCoreEdge else { return "core edge can't move: \(state.id) \(replaced.edge.on)" }
            }
        }

        // Anything else would let a scenario file open model speech on an arrest state, or reword a correction.
        let owned = Set(module.states.map(\.id))
        if let foreign = module.openStates.first(where: { !owned.contains($0) }) { return "opens speech on a state it doesn't own: \(foreign)" }
        if let taken = module.correctionPhrases.keys.first(where: { base.definition.correctionPhrases[$0] != nil }) {
            return "correction collision: \(taken)"
        }
        if let taken = module.awakeCorrectionPhrases.keys.first(where: { base.awakeCorrectionPhrases[$0] != nil }) {
            return "correction collision: \(taken)"
        }
        let awakeCategories = Set(SentinelFlag.Category.awakeCases.map(\.rawValue))
        if let other = module.awakeCorrectionPhrases.keys.first(where: { !awakeCategories.contains($0) }) {
            return "not an awake category: \(other)"
        }
        let resources = Set(Resource.allCases.map(\.rawValue))
        if let other = module.awakeResourceHints.keys.first(where: { !resources.contains($0) }) { return "not a resource: \(other)" }
        if let taken = module.awakeResourceHints.keys.first(where: { base.awakeResourceHints[$0] != nil }) {
            return "hint collision: \(taken)"
        }
        return nil
    }

    /// What only shows once merged, since the injected edges have to pass as well.
    static func refusal(of module: ScenarioModule, merged: ProtocolBundle, corePhrases: Set<String>) -> String? {
        let states = table(merged.definition.states)
        let phraseIDs = Set(merged.phrases.phrases.map(\.id))
        let owned = module.states.compactMap { states[$0.id] }

        for state in owned {
            let phrases = state.entryPhrases + state.allowedSay + state.repeating.map(\.phrase) + (state.timeout?.phrases ?? [])
            if let missing = phrases.first(where: { !phraseIDs.contains($0) }) { return "dangling phrase \(missing): \(state.id)" }
            // Nobody has said the patient is awake, so silence here has to reach the arrest path, and soon.
            if state.id == ScenarioModule.assessState {
                guard let timeout = state.timeout, timeout.to == ScenarioModule.assessFallback, timeout.ifBreathsAtLeast == nil else {
                    return "assess must time out to \(ScenarioModule.assessFallback): \(state.id)"
                }
                guard timeout.seconds <= ScenarioModule.maxAssessSeconds else {
                    return "assess waits over \(Int(ScenarioModule.maxAssessSeconds)) s: \(state.id)"
                }
            }

            for target in [state.timeout?.to, state.timeout?.ifBreathsAtLeast?.to].compactMap({ $0 }) {
                guard let to = states[target] else { return "dangling timeout to \(target): \(state.id)" }
                if let reason = refusal(from: state, to: to, in: states) { return "\(reason.rawValue): timeout \(state.id) to \(target)" }
                for landing in landings(of: to, in: states) {
                    if state.id == ScenarioModule.assessState, landing.id == ScenarioModule.assessFallback { continue }
                    guard !landing.kind.isArrestPath else { return "timeout into the arrest path: \(state.id) to \(landing.id)" }
                    guard landing.kind.isAwake else { return "timeout onto a card: \(state.id) to \(landing.id)" }
                    guard !isHumanOnly(landing) else { return "timeout into a human-only state: \(state.id) to \(landing.id)" }
                }
            }

            if let target = state.afterPads {
                guard let to = states[target] else { return "dangling after_pads to \(target): \(state.id)" }
                guard !to.kind.isAwake else { return "after_pads stays awake: \(state.id) to \(target)" }
                if let log = to.logOnEnter, !stateLogs.contains(log) { return "after_pads sets \(log.rawValue): \(state.id)" }
            }
        }

        // Taken from the file, not the merged state, since the injected Start CPR edge has to name core's.
        var authored: [String] = (module.entries + module.replacedEdges).flatMap { $0.edge.phrases ?? [] }
        authored += module.awakeResourceHints.values
        // A correction plays on a flag, with no tap, so it's held to the same rules as any other line.
        authored += module.awakeCorrectionPhrases.values
        for state in module.states {
            authored += state.entryPhrases + state.allowedSay + state.repeating.map(\.phrase) + (state.timeout?.phrases ?? [])
            authored += state.transitions.flatMap { $0.phrases ?? [] }
        }
        if let borrowed = authored.first(where: { corePhrases.contains($0) && !sharedPhrases.contains($0) }) { return "core phrase on an awake path: \(borrowed)" }
        // The dose is said once, on entering a state that records it, which only a tap can reach.
        let advised = module.states.filter { $0.logOnEnter == .aspirinAdvised && $0.entryPhrases.contains(approvedDose.id) }.count
        if authored.filter({ $0 == approvedDose.id }).count != advised { return "dose outside an aspirin step: \(approvedDose.id)" }

        let grafted = (module.entries + module.replacedEdges).compactMap { graft in states[graft.state].map { ($0, graft.edge) } }
        for (from, edge) in owned.flatMap({ state in state.transitions.map { (state, $0) } }) + grafted {
            guard humanKeys.contains(edge.on) || findings[edge.on] != nil else { return "unknown event \(edge.on): \(from.id)" }
            guard let to = states[edge.to] else { return "dangling edge \(edge.on) to \(edge.to): \(from.id)" }
            if let missing = edge.phrases?.first(where: { !phraseIDs.contains($0) }) { return "dangling phrase \(missing): \(from.id)" }
            if let log = edge.log, !edgeLogs.contains(log) { return "reserved log \(log.rawValue): \(from.id)" }

            guard let finding = findings[edge.on] else { continue }
            guard !finding.wouldLowerUrgency else { return "\(SafetyGate.RejectReason.cannotLowerUrgency.rawValue): \(edge.on) on \(from.id)" }
            // The gate checks transitions before the hold, so an edge here would replace the hold.
            guard finding != .dispatcherSpeaking, finding != .aedPrompting else { return "model edge in place of a hold: \(edge.on) on \(from.id)" }
            if let reason = refusal(from: from, to: to, in: states) { return "\(reason.rawValue): \(edge.on) from \(from.id) to \(to.id)" }
            // A backstop no file can reach: the only core edges a module may graft or move are taps.
            guard from.kind.isAwake else { return "model edge outside the awake states: \(from.id)" }
            for landing in landings(of: to, in: states) {
                guard modelMayLand(on: landing) else { return "model edge can't land on \(landing.id): \(edge.on) from \(from.id)" }
            }
        }

        // Only the injected edges may leave, or a tap could write the record, as human.done to aed_analyze would.
        for edge in module.states.flatMap(\.transitions) + (module.entries + module.replacedEdges).map(\.edge) where humanKeys.contains(edge.on) {
            guard states[edge.to]?.kind.isAwake == true else { return "human edge leaves the awake states: \(edge.on) to \(edge.to)" }
        }

        // `transition(on:)` takes the first match, so a repeat either does nothing or hides an injected edge.
        for id in Set(owned.map(\.id) + module.entries.map(\.state)) {
            let keys = states[id]?.transitions.map(\.on) ?? []
            if let repeated = keys.first(where: { key in keys.filter { $0 == key }.count > 1 }) { return "repeats edge \(repeated): \(id)" }
        }

        // Every way into the awake states needs the redirect, or a patient with pads on, or who
        // needed CPR, would get aspirin and free AI. `entered` is a backstop no file can reach, since
        // the only core edges a module may graft or move lead to triage, which its own module checks.
        let entered: [StateDefinition] = grafted.filter { !$0.0.kind.isAwake }.compactMap { states[$0.1.to] }.filter(\.kind.isAwake)
        let doors: [StateDefinition] = owned.filter { $0.id == ScenarioModule.triageState } + entered
        if let open = doors.first(where: { $0.afterPads == nil }) { return "no after_pads: \(open.id)" }

        if let missing = module.awakeResourceHints.values.first(where: { !phraseIDs.contains($0) }) { return "dangling hint \(missing)" }
        let corrections = Array(module.correctionPhrases.values) + Array(module.awakeCorrectionPhrases.values)
        if let missing = corrections.first(where: { !phraseIDs.contains($0) }) { return "dangling correction \(missing)" }
        // Core's table also answers arrest states, where an awake correction must never resolve.
        if let key = module.correctionPhrases.keys.first { return "correction outside awake_correction_phrases: \(key)" }
        return isRunnable(merged) ? nil : "not runnable"
    }

    /// Every rule a cue answers to. A cue points from a line the step already says, and its chip only
    /// repeats that line's words, so the camera never adds advice of its own. People follow a mark on
    /// the camera without thinking, so a cue that can't be drawn as meant is refused, not shrugged off.
    private static func cueRefusal(of state: StateDefinition, in module: ScenarioModule, texts: [String: String]) -> String? {
        for cue in state.cues {
            if let unknown = cue.unknownValues.first { return "cue \(unknown) is not known: \(state.id)" }
            guard state.entryPhrases.contains(cue.phrase) || state.allowedSay.contains(cue.phrase) else {
                return "cue phrase is not this step's line \(cue.phrase): \(state.id)"
            }
            // Its words are checked against the text, so the text has to ship in the same file.
            guard let text = texts[cue.phrase] else { return "cue on a phrase the module doesn't own \(cue.phrase): \(state.id)" }
            let said = Set(words(in: text))
            // Both body parts hang off the pin, so a step with no pin has nothing to draw them on.
            if cue.body != nil, state.overlay != .injurySite { return "cue body without the pin: \(state.id)" }
            if cue.placement != nil, cue.body == nil { return "cue placement with no body: \(state.id)" }
            if let material = cue.material, said.isDisjoint(with: material.calloutNouns) {
                return "cue phrase doesn't name the \(material.rawValue) \(cue.phrase): \(state.id)"
            }

            guard let callout = cue.callout else { continue }
            guard let material = cue.material else { return "callout with no material: \(state.id)" }
            let shown = words(in: callout)
            guard (1...maxCalloutWords).contains(shown.count) else { return "callout not 1 to \(maxCalloutWords) words \"\(callout)\": \(state.id)" }
            if let extra = shown.first(where: { !said.contains($0) }) { return "callout word not in its phrase \(extra): \(state.id)" }
            if Set(shown).isDisjoint(with: material.calloutNouns) { return "callout doesn't name the \(material.rawValue) \"\(callout)\": \(state.id)" }
            // Words from a clean line can still drop its "don't".
            if !TranscriptValidator.check(callout, profile: .awake).isEmpty || advisesMedicine(callout) {
                return "callout breaks a phrase rule \"\(callout)\": \(state.id)"
            }
        }
        if state.locateMaterials, StateDefinition.materials(cuedIn: state.flowmates(in: module.states)).isEmpty {
            return "locate_materials with nothing to find: \(state.id)"
        }
        return nil
    }

    /// Lowercased with punctuation gone, so "Pad under · Towel" is pad, under, towel and "it:" is it.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    /// Stricter than the transcript check, which lets a hedge through: "they may chew an aspirin now"
    /// on a step a timer reaches would be a dose nothing records. Only a negation of the verb itself
    /// takes it back, so "Don't wait to give aspirin" and "If not allergic, chew aspirin" still advise.
    static func advisesMedicine(_ text: String) -> Bool {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let clauses = normalized.split(whereSeparator: { ".?!,;:".contains($0) }).map(String.init)
        return clauses.contains { clause in
            clause.replacingOccurrences(of: negatedMedicine, with: " ", options: .regularExpression)
                .range(of: medicineAdvice, options: .regularExpression) != nil
        }
    }

    private static let medicineVerb = #"\b(give[ns]?|giving|gave|take[ns]?|taking|took|chew(s|ed|ing)?|swallow(s|ed|ing)?|have|has|having|had|offer(s|ed|ing)?|use[sd]?|using|administer(s|ed|ing)?|hand(s|ed|ing)?)\b"#
    private static let medicineForm = #"\b(aspirins?|pills?|tablets?|capsules?|caplets?|doses?|mg|milligrams?|medicines?|medications?|epinephrine|epi-?pens?|auto-?injectors?|nitro|nitroglycerin|naloxone|narcan|inhalers?|ibuprofen|acetaminophen|tylenol|insulin)\b"#
    private static let medicineAdvice = "\(medicineVerb).{0,30}\(medicineForm)|\(medicineForm).{0,30}\(medicineVerb)"
    /// Only words that leave the negation on the verb may sit between them: "Never let them take
    /// aspirin", "Tell them not to take aspirin", "Aspirin must not be given".
    private static let between = #"((to|be|him|her|them|they|you|anyone|anybody|someone|any|ever|yet|the patient|the person)\s+){0,2}"#
    private static let negatedMedicine = #"\b(not|never|no|cannot|don't|doesn't|didn't|can't|shouldn't|mustn't|won't|wouldn't|couldn't)\s+\#(between)(\#(medicineVerb)|\b(let|make)\b)(\s+\#(between)\#(medicineVerb))?|\bno\s+((more|further|other)\s+)?\#(medicineForm)(?!\s+allerg)"#

    /// Checks where the engine could really land, since pads can redirect a transition.
    private static func refusal(from: StateDefinition, to: StateDefinition, in states: [String: StateDefinition]) -> SafetyGate.RejectReason? {
        if let reason = SafetyGate.refusal(from: from, to: to) { return reason }
        return to.afterPads.flatMap { states[$0] }.flatMap { SafetyGate.refusal(from: from, to: $0) }
    }

    private static func landings(of state: StateDefinition, in states: [String: StateDefinition]) -> [StateDefinition] {
        [state] + [state.afterPads.flatMap { states[$0] }].compactMap { $0 }
    }

    /// One report may move the rescue among the awake states or to the breathing question, where a
    /// person gets the next word. Everywhere else it would write the record or start compressions.
    private static func modelMayLand(on state: StateDefinition) -> Bool {
        state.id == ScenarioModule.breathingQuestion || (state.kind.isAwake && !isHumanOnly(state))
    }

    /// Only a tap gets here. A report or a silence must never choose triage or a dose. Assess is only
    /// ever the first step, so nothing may lead back to it.
    private static func isHumanOnly(_ state: StateDefinition) -> Bool {
        state.id == ScenarioModule.triageState || state.id == ScenarioModule.assessState || state.logOnEnter == .aspirinAdvised
    }

    /// Never `uniqueKeysWithValues`, because this can run on data that hasn't passed yet.
    private static func table(_ states: [StateDefinition]) -> [String: StateDefinition] {
        Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
