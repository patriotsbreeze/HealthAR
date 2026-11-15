import RescueCore

/// Hands-free buttons: the rescuer's own words, from the mic's transcript and never the AI's, press
/// a button on screen as a tap would. Only when what they said is the button and nothing else, so a
/// button's name inside a longer sentence, the app's own lines coming back through the mic among
/// them, presses nothing. A button that stops CPR or leaves the path takes its hold, never a voice.
/// The one exception is asking for CPR, which starts it from inside a sentence too.
enum VoiceCommands {
    static func action(for utterance: String, among controls: [RescueControl]) -> HumanAction? {
        let said = normalized(utterance)
        guard !said.isEmpty else { return nil }
        if let exact = controls.first(where: { pressable($0) && phrases(for: $0).contains(said) }) {
            return exact.action
        }
        guard asksForCPR(said) else { return nil }
        return controls.first { pressable($0) && ($0.action == .startCpr || $0.action == .resumeCpr) }?.action
    }

    /// "He's not breathing, continue with CPR": a rescuer who asks for CPR gets it, however long the
    /// sentence, since waiting on the exact words costs compressions. A no or a wait in it presses
    /// nothing. The app's own lines that say CPR come back through the mic only while they sound, and
    /// words that overlap the app's speech press nothing.
    static func asksForCPR(_ said: String) -> Bool {
        let words = " \(said) "
        guard cprRequests.contains(where: { words.contains(" \($0) ") }) else { return false }
        return !cprRefusals.contains { words.contains(" \($0) ") }
    }

    private static let cprRequests = [
        "continue with cpr", "continue cpr", "go on with cpr", "go ahead with cpr", "proceed with cpr",
        "go to cpr", "move to cpr", "start cpr", "starting cpr", "begin cpr", "do cpr", "lets do cpr",
        "start compressions", "begin compressions", "start chest compressions",
    ]

    private static let cprRefusals = ["dont", "do not", "not yet", "wait", "stop", "no cpr", "should i", "if"]

    static func pressable(_ control: RescueControl) -> Bool {
        control.role != .stopsCPR && control.role != .holdStep
    }

    static func phrases(for control: RescueControl) -> Set<String> {
        Set(([control.title] + (extra[control.action] ?? [])).map(normalized))
    }

    /// Lowercase words, with no punctuation, and without a leading "um" or "okay" or a trailing "please".
    static func normalized(_ text: String) -> String {
        let letters = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        var words = String(letters).split(separator: " ").map(String.init)
        while let first = words.first, leading.contains(first) { words.removeFirst() }
        while let last = words.last, trailing.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static let leading: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ok", "okay", "so", "and", "alright"]
    private static let trailing: Set<String> = ["please"]

    /// What people say for a button besides its own words.
    private static let extra: [HumanAction: [String]] = [
        .yes: ["yeah", "yep", "yup", "yes they are", "yes he is", "yes she is"],
        .no: ["nope", "nah", "no theyre not", "no hes not", "no shes not"],
        .unsure: ["not sure", "im not sure", "i dont know", "dont know", "unsure"],
        .done: ["done", "next", "finished", "im done", "thats done"],
        .called: ["i called", "ive called", "we called", "called 911", "called them"],
        .startCpr: ["start cpr", "starting cpr", "begin cpr", "start compressions"],
        .resumeCpr: ["resume", "resume cpr", "start cpr again"],
        .back: ["go back"],
        .scan: ["scan", "scan the room"],
        .aedHere: ["the aed is here", "aed is here", "got the aed", "i have the aed"],
        .padsOn: ["pads are on", "the pads are on"],
        .aedSaysCpr: ["aed says cpr", "it says push", "it says cpr"],
        .aedAnalyzing: ["analyzing", "its analyzing", "aed is analyzing"],
        .shockDelivered: ["shock delivered", "shocked", "shock given"],
        .breathMarked: ["breath", "a breath", "they took a breath"],
        .patientUnresponsive: ["not responding", "theyre not responding", "unresponsive"],
        .patientNotBreathing: ["not breathing", "theyre not breathing", "gasping"],
        .patientAwake: ["awake and talking", "theyre awake", "awake"],
        .triageChest: ["chest pain", "heart symptoms", "heart"],
        .triageLimb: ["injured arm", "injured leg", "broken arm", "broken leg", "broken bone"],
        .triageOther: ["something else", "other"],
        .triageChoking: ["choking", "theyre choking"],
        .metronomeOn: ["metronome on", "turn on the metronome"],
        .metronomeOff: ["metronome off", "turn off the metronome"],
    ]
}
