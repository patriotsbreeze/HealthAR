import RescueCore

struct RescueControl: Identifiable, Equatable {
    enum Role: Equatable {
        /// Red, and full width on the arrest path. The fastest way into CPR.
        case primary
        /// Yes, No, and Not sure, side by side.
        case answer
        case step
        /// One to a row. It picks the flow, and shows only where the state has the edge, so a dropped
        /// flow takes its button with it.
        case triage
        /// Beside Start CPR and outside the scroll view in an awake state, so a collapse never takes a search.
        case collapse
        /// Leaves the adult path or the flow with one action, and where it lands has no timeout, so
        /// it takes a 2 s hold. In an awake state so does EMS arrived, which nothing on screen can undo.
        case holdStep
        /// Leaves CPR, so it takes a 2 s hold and a confirmation.
        case stopsCPR
    }

    var action: HumanAction
    var title: String
    var role: Role
    var id: HumanAction { action }

    var confirmationTitle: String {
        switch action {
        case .emsArrived: "EMS has taken over?"
        case .patientMoving: "The patient is moving?"
        default: "Stop CPR?"
        }
    }
}

/// Which buttons a state shows. Everything comes from the state's own transitions in the bundle,
/// and the few actions that change no state follow the same facts the engine's guards check, so the
/// screen can't offer something the engine would ignore, or miss something it would accept.
enum RescueControls {
    /// `awakeLocked` is the engine's redirect: pads on or CPR started keeps the patient on the static card.
    /// `noCPRToResume` is a patient who was awake and never had CPR, so "Resume" would say they had.
    static func derive(
        definition: StateDefinition,
        engine: ProtocolEngine,
        metronomeOn: Bool,
        awakeLocked: Bool = false,
        noCPRToResume: Bool = false
    ) -> [RescueControl] {
        var actions: [(HumanAction, stopsCPR: Bool)] = definition.transitions.compactMap { transition in
            guard transition.on.hasPrefix(humanPrefix),
                  let action = HumanAction(rawValue: String(transition.on.dropFirst(humanPrefix.count)))
            else { return nil }
            // Landing back on this step, a button would only say it again.
            let target = engine.definition(of: transition.to)
            let redirect = awakeLocked && target?.kind.isAwake == true ? target?.afterPads : nil
            if (redirect ?? transition.to) == definition.id { return nil }
            let leavesCPR = definition.kind == .cpr && engine.definition(of: transition.to)?.kind != .cpr
            return (action, leavesCPR)
        }
        if definition.timeout?.ifBreathsAtLeast != nil {
            actions.append((.breathMarked, false))
        }
        if definition.transition(on: "\(humanPrefix)\(HumanAction.aedSaysCpr.rawValue)") != nil
            || definition.transition(on: "\(humanPrefix)\(HumanAction.aedAnalyzing.rawValue)") != nil {
            actions.append((.shockDelivered, false))
        }
        if definition.metronomeToggleable {
            actions.append((metronomeOn ? .metronomeOff : .metronomeOn, false))
        }

        var seen: Set<HumanAction> = []
        return actions.compactMap { action, stopsCPR in
            guard seen.insert(action).inserted else { return nil }
            return RescueControl(
                action: action,
                title: title(for: action == .resumeCpr && noCPRToResume ? .startCpr : action),
                role: role(for: action, stopsCPR: stopsCPR, awake: definition.kind.isAwake)
            )
        }
    }

    /// Fixed, because each button's edge comes from its own module, and load order isn't reading order.
    static func triageGroup(_ controls: [RescueControl]) -> [RescueControl] {
        [HumanAction.triageChest, .triageLimb, .triageOther, .triageChoking].compactMap { action in
            controls.first { $0.action == action }
        }
    }

    /// Where each control sits in the awake panel. A control left out of all of these wouldn't be on
    /// screen at all, which is what a test holds this to.
    struct AwakeLayout: Equatable {
        var answers: [RescueControl]
        var triage: [RescueControl]
        var steps: [RescueControl]
        var holds: [RescueControl]
        /// In the small row, beside the dispatcher, so holding it doesn't take a row of its own.
        var emsArrived: [RescueControl]
        var primary: [RescueControl]
        var collapse: [RescueControl]

        var all: [RescueControl] { answers + triage + steps + holds + emsArrived + primary + collapse }
    }

    static func awakeLayout(_ controls: [RescueControl]) -> AwakeLayout {
        AwakeLayout(
            answers: [HumanAction.yes, .no, .unsure].compactMap { answer in controls.first { $0.action == answer } },
            triage: triageGroup(controls),
            steps: controls.filter { $0.role == .step },
            holds: controls.filter { $0.role == .holdStep && $0.action != .emsArrived },
            emsArrived: controls.filter { $0.action == .emsArrived },
            primary: controls.filter { $0.role == .primary },
            collapse: controls.filter { $0.role == .collapse }
        )
    }

    private static let humanPrefix = "human."

    private static func role(for action: HumanAction, stopsCPR: Bool, awake: Bool) -> RescueControl.Role {
        if stopsCPR { return .stopsCPR }
        switch action {
        case .startCpr, .resumeCpr: return .primary
        case .yes, .no, .unsure: return .answer
        case .triageChest, .triageLimb, .triageOther, .triageChoking: return .triage
        case .notAdult, .notThis: return .holdStep
        case .emsArrived where awake: return .holdStep
        case .patientUnresponsive where awake, .patientNotBreathing where awake: return .collapse
        default: return .step
        }
    }

    /// No default, so a new action can't ship without a label.
    static func title(for action: HumanAction) -> String {
        switch action {
        case .yes: "Yes"
        case .no: "No"
        case .unsure: "Not sure"
        case .back: "Back"
        case .called: "Called"
        case .done: "Done, next"
        case .scan: "Scan room"
        case .startCpr: "Start CPR"
        case .notAdult: "Child, infant, drowning, or pregnant"
        case .aedHere: "AED here"
        case .padsOn: "Pads on"
        case .aedSaysCpr: "AED says push"
        case .aedAnalyzing: "AED analyzing"
        case .emsArrived: "EMS arrived"
        case .patientMoving: "Patient moved"
        case .patientAwake: "Patient awake"
        case .patientUnresponsive: "Not responding now"
        case .patientNotBreathing: "Not breathing or only gasping"
        case .resumeCpr: "Resume CPR"
        case .triageChest: "Chest pain or heart symptoms"
        case .triageLimb: "Injured arm or leg"
        case .triageOther: "Something else"
        case .triageChoking: "Choking"
        case .triageOpen: "What's going on?"
        case .notThis: "Not this, go back"
        case .breathMarked: "Mark breath"
        case .shockDelivered: "Shock marked"
        case .metronomeOn: "Metronome on"
        case .metronomeOff: "Metronome off"
        case .dispatcherOn: "Open dispatcher"
        case .dispatcherOff: "Close dispatcher"
        case .secondPerson: "Someone is with me"
        }
    }
}
