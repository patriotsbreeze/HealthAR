import Foundation
import Observation
import RescueAudio
import RescueCore
import RescueLive
import RescueVision
import UIKit

struct LiveStack: Sendable {
    var session: LiveSession
    var auditor: Auditor?
    var assessor: SituationAssessor? = nil
}

/// Owns the engine's state and log, feeds it every event, and applies every effect it emits. The
/// model reports and the engine decides, so nothing here chooses a step. Audio, Live, and vision can
/// each be missing or failing, and guidance carries on regardless.
@MainActor
@Observable
final class AppCoordinator {
    /// Spoken only by the seeded beat. It has no clip, so on-device speech says it.
    nonisolated static let seededPhraseID = "seeded_bad_line"
    nonisolated static let seededLine = "Seeded test line. Check his pulse first."
    /// The same beat for an awake state, where the bad line is a different one.
    nonisolated static let seededAwakePhraseID = "seeded_bad_line_awake"
    nonisolated static let seededAwakeLine = "Seeded test line. It's definitely a heart attack."

    private static let tickInterval: Duration = .milliseconds(200)
    private static let promptVisibleSeconds: TimeInterval = 8
    private static let stepSettleSeconds: TimeInterval = 0.6
    private static let questionSettleSeconds: TimeInterval = 2
    private static let primarySettleSeconds: TimeInterval = 0.4
    private static let locateRetrySeconds: TimeInterval = 2
    /// A callout shows from the second sighting at about one spot, so a material is asked for until then.
    private static let sightingsToShow = 2
    private static let handsGuideSeconds = VisionSession.handsGuideSeconds
    /// The pads diagram stays away this long after the pads were last drawn in the band.
    static let padsGuideHold: TimeInterval = 1
    private static let pinMessageSeconds: TimeInterval = 3
    private static let aiQuietSeconds: TimeInterval = 4
    private static let cutFollowsSpeechSeconds: TimeInterval = 1
    /// The line on each step that asks what's going on, after which the AI gets its cue to speak.
    private static let kickFollowsPhrase = [ScenarioModule.assessState: "assess_intro", ScenarioModule.triageState: "triage_ask"]
    private static let maxVoiceRows = 40
    private static let maxTranscriptCharacters = 400
    /// The least gap between quick looks. The key is shared with the voice, the checker and the AED
    /// finder, so this leaves them room.
    private static let quickLookGap: TimeInterval = 1.5
    /// A live scene report this recent stands in for a quick look.
    private static let liveSceneFresh: TimeInterval = 5
    /// After a failure the quick look waits twice as long as last time, up to this, and resets on a success.
    private static let assessBackoffCap: TimeInterval = 16
    /// How many of the voice model's latest tool calls ride with a quick look.
    private static let assessedToolCalls = 4
    private static let snapshotSeconds: TimeInterval = 1.5
    /// The live log keeps this many lines, newest first.
    private static let maxLogEntries = 40

    /// One line of the live log: what the voice AI saw, did, heard or said, as it happened.
    struct AssessmentLogEntry: Identifiable, Equatable {
        enum Kind: Equatable { case alert, saw, tool, heard, said, look, call }
        var id: Int
        var at: TimeInterval
        var kind: Kind
        var text: String
        /// The voice AI's own line on why it matters, for a scene report.
        var detail: String?
    }

    struct ModelCall: Identifiable, Equatable {
        var id: Int
        var at: TimeInterval
        var summary: String
        var seeded: Bool
    }

    struct Prompt: Equatable {
        var text: String
        var expiresAt: TimeInterval
    }

    enum AudioHealth: Equatable {
        case starting, ok, outputLost, voiceFailed
    }

    private enum Inbox: Sendable {
        case phraseFinished(String)
        case callChanged(Bool)
        case audioStatus(AudioStatus)
        case speech(started: Bool)
        // Tagged, because a swap can end their session while they wait in here.
        case live(LiveEvent, session: Int)
        case modelVoice(session: Int)
        case auditFlag(SentinelFlag, session: Int)
        case quickLook(AssessmentOutcome, startedAt: TimeInterval, session: Int, round: Int)
    }

    // MARK: - Fixed parts

    let engine: ProtocolEngine
    let location: LocationService
    @ObservationIgnored let audio: any AudioPort
    @ObservationIgnored let vision: any VisionPort
    @ObservationIgnored let clock: @Sendable () -> TimeInterval
    @ObservationIgnored private let gate: UplinkGate
    @ObservationIgnored private let canLocate: Bool
    @ObservationIgnored private let makeLive: @MainActor (LiveMode) -> LiveStack?
    @ObservationIgnored private let cameraAllowed: @MainActor () -> Bool
    @ObservationIgnored private let runsTickLoop: Bool
    @ObservationIgnored private let inbox: AsyncStream<Inbox>.Continuation
    @ObservationIgnored private let inboxStream: AsyncStream<Inbox>

    // MARK: - What the screens read

    private(set) var state: RescueState
    private(set) var log = EventLog()
    private(set) var overlayTarget: OverlayTarget?
    /// What the step points at on the camera, from its entry. Empty on a step with none.
    private(set) var cues: [Cue] = []
    /// When the chest zone at the start of compressions goes, on this clock. Nil when it isn't up.
    private(set) var handsGuideUntil: TimeInterval?
    private(set) var prompt: Prompt?
    /// A tap on the camera that couldn't place a pin, so it doesn't look ignored.
    private(set) var pinMessage: Prompt?
    private(set) var hasBegun = false
    private(set) var showsCamera = false
    private(set) var liveConnected = false
    /// One mode's session has stopped and the next isn't up, so nothing is hearing for now.
    private(set) var liveSwapping = false
    private(set) var aiQuiet = false
    /// The AI's voice is coming out of the speaker right now.
    private(set) var aiTalking = false
    private(set) var lastDisconnect: String?
    private(set) var audioHealth = AudioHealth.starting
    private(set) var micProblem: String?
    private(set) var visionStatus = VisionStatus.stopped
    private(set) var timings: [LiveTimingMetric: [TimeInterval]] = [:]
    private(set) var usage: LiveUsage?
    private(set) var modelCalls: [ModelCall] = []
    private(set) var heardTranscript = ""
    private(set) var saidTranscript = ""
    private(set) var seededSequences: Set<Int> = []
    private(set) var operatorUsed = false
    private(set) var dispatcherOpen = false
    /// The latest read of the scene. It only informs, and goes when the session or the rescue does.
    private(set) var sceneRead: SituationAssessment?
    /// On assess, the voice AI's sense of a collapse, held as a suggestion: core moves nothing on it
    /// there, and a person taps the ringed button or says "confirm".
    private(set) var voiceSuggestion: SituationAssessment.Suggestion?

    /// The one button the AI points to on assess, from the voice AI's report first, else the scene read
    /// at medium or high confidence. It only ever rings a button; nothing moves until a person acts.
    var assessSuggestion: SituationAssessment.Suggestion? {
        guard state.stateID == ScenarioModule.assessState else { return nil }
        if let voiceSuggestion { return voiceSuggestion }
        guard let read = sceneRead, read.confidence != .low else { return nil }
        return read.suggests
    }
    /// Everything the voice AI saw, did, heard and said, newest first, for the drop-down under the read.
    private(set) var assessmentLog: [AssessmentLogEntry] = []
    private(set) var assessing = false
    /// The last try failed and there's no read yet to keep, so the chip says so rather than vanish.
    private(set) var assessmentFailed = false
    /// Who made the scene lines on screen.
    private(set) var assessmentSource: AssessmentSource?

    enum AssessmentSource: String {
        case live = "Seen live by the voice AI"
        case quickLook = "Quick look at one frame, while the voice AI was quiet"
    }
    /// For the latency display: how long quick looks take, how often the voice AI reports, and why
    /// the last look failed.
    private(set) var assessmentStats = AssessmentStats()

    struct AssessmentStats: Equatable {
        var quick: [TimeInterval] = []
        /// Seconds between one live scene report and the next.
        var liveGaps: [TimeInterval] = []
        var failures = 0
        var lastProblem: String?
    }

    // MARK: - Working state

    @ObservationIgnored private var live: LiveStack?
    /// What the current state needs. A card has no say, so this keeps what was running.
    @ObservationIgnored private var liveMode = LiveMode.arrest
    @ObservationIgnored private var liveSession: Int?
    @ObservationIgnored private var lastLiveSession = 0
    @ObservationIgnored private var swapStartedAt: TimeInterval?
    @ObservationIgnored private var kickSent = false
    @ObservationIgnored private var kickPhraseDone = false
    @ObservationIgnored private var personSpeaking = false
    /// The client VAD closes 300 ms after speech, so a short question can end before the server's cut lands.
    @ObservationIgnored private var lastSpeechEnd: TimeInterval?
    @ObservationIgnored private var quietSince: TimeInterval?
    /// `modelTurnActive` is only holding for an answer someone may be about to get, with no voice yet.
    @ObservationIgnored private var awaitingAnswer = false
    @ObservationIgnored private var liveRouter: Task<Void, Never>?
    @ObservationIgnored private var liveUplink: Task<Void, Never>?
    @ObservationIgnored private var tickLoop: Task<Void, Never>?
    @ObservationIgnored private var lastPhraseID: String?
    @ObservationIgnored private var latestBrief: StateBrief?
    @ObservationIgnored private var transcriptBuffer = TranscriptBuffer()
    @ObservationIgnored private var turnText = ""
    @ObservationIgnored private var turnFlags: Set<SentinelFlag.Category> = []
    @ObservationIgnored private var lastLocateAt = -TimeInterval.infinity
    @ObservationIgnored private var lastMaterialScanAt = -TimeInterval.infinity
    /// When both pads were last drawn in the band, so a pose dropout doesn't blink the diagram back.
    @ObservationIgnored var padsInBandAt: TimeInterval?
    @ObservationIgnored private var nextModelCallID = 0
    /// Bumped on every reset and swap, so a read for an older scene lands nowhere.
    @ObservationIgnored private var assessRound = 0
    @ObservationIgnored private var quickInFlight = false
    @ObservationIgnored private var lastQuickAt = -TimeInterval.infinity
    @ObservationIgnored private var quickBackoff: TimeInterval = 0
    @ObservationIgnored private var lastLookReason = ""
    @ObservationIgnored private var lastLiveSceneAt = -TimeInterval.infinity
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var lastEmergency: String?
    /// The simulated 911 agent's call, played into the log once a rescue. Cancelled on reset.
    @ObservationIgnored private var callerAgentTask: Task<Void, Never>?
    @ObservationIgnored private var callerAgentRan = false
    private(set) var callerAgentStatus = CallerAgentStatus.idle
    /// What the rescuer said since the log last took it, so it goes in as one line and not word by word.
    @ObservationIgnored private var heardPending = ""
    /// When the read behind the scene lines on screen started, so an older reply can't overwrite them.
    @ObservationIgnored private var sceneStartedAt = -TimeInterval.infinity

    init(
        engine: ProtocolEngine,
        audio: any AudioPort,
        vision: any VisionPort,
        gate: UplinkGate = UplinkGate(),
        canLocate: Bool,
        makeLive: @escaping @MainActor (LiveMode) -> LiveStack?,
        clock: @escaping @Sendable () -> TimeInterval = MonotonicClock.now,
        cameraAllowed: @escaping @MainActor () -> Bool = { Permissions.cameraGranted },
        location: LocationService? = nil,
        runsTickLoop: Bool = true
    ) {
        self.engine = engine
        self.audio = audio
        self.vision = vision
        self.gate = gate
        self.canLocate = canLocate
        self.makeLive = makeLive
        self.clock = clock
        self.cameraAllowed = cameraAllowed
        self.location = location ?? LocationService()
        self.runsTickLoop = runsTickLoop
        (inboxStream, inbox) = AsyncStream.makeStream(of: Inbox.self, bufferingPolicy: .bufferingNewest(1024))
        state = engine.start(at: clock()).state
        wireAudio()
        startPumps()
    }

    deinit {
        inbox.finish()
    }

    // MARK: - Starting and restarting

    /// Starts the flow once. Onboarding is over by now, so nothing from here on may prompt.
    func beginRescue() {
        guard !hasBegun else { return }
        hasBegun = true

        // Before the first effects, so its first connection is seeded with the first brief.
        liveMode = engine.definition(of: engine.bundle.definition.initialState)?.kind.liveMode ?? .arrest
        startLive()
        let callActive = state.callActive
        let now = clock()
        let result = engine.start(at: now)
        state = result.state
        log = EventLog()
        commit(result, at: now)
        // Audio only reports a call when it changes, so a restart mustn't forget one in progress.
        if callActive { dispatch(.callChanged(active: true)) }
        gate.send(.start)

        audio.start()
        // The AR session would raise the camera prompt itself, and this must never prompt.
        showsCamera = vision.isARSupported && cameraAllowed()
        if showsCamera { vision.start() }
        visionStatus = vision.status
        location.refresh()
        // A rescuer with busy hands can't keep the screen awake by touching it.
        UIApplication.shared.isIdleTimerDisabled = true
        startTickLoop()
    }

    func restartRescue() {
        // An awake step's lines, the dose among them, would otherwise play on ahead of the new rescue's
        // first question. Read from the old log, so an arrest-only restart goes as it always has.
        if enteredAwake { audio.cutPhrases() }
        stopLive()
        if showsCamera { vision.stop() }
        audio.setMetronome(on: false)
        vision.setGhostBeat(on: false)
        gripReminderUntil = nil
        metronomeOn = false
        vision.clearPracticePatient()
        practicePatientPlaced = false
        audio.flushModelAudio()
        audio.resume()
        overlayTarget = nil
        cues = []
        handsGuideUntil = nil
        prompt = nil
        pinMessage = nil
        lastPhraseID = nil
        latestBrief = nil
        location.reset()
        lastLocateAt = -.infinity
        lastMaterialScanAt = -.infinity
        kickSent = false
        kickPhraseDone = false
        personSpeaking = false
        lastSpeechEnd = nil
        modelCalls = []
        heardTranscript = ""
        saidTranscript = ""
        clearAssessment()
        seededSequences = []
        timings = [:]
        usage = nil
        lastDisconnect = nil
        operatorUsed = false
        dispatcherOpen = false
        hasBegun = false
        beginRescue()
    }

    // MARK: - Reading the current state

    var definition: StateDefinition? { engine.definition(of: state.stateID) }

    var controls: [RescueControl] {
        definition.map {
            RescueControls.derive(
                definition: $0,
                engine: engine,
                metronomeOn: state.metronomeOn,
                awakeLocked: awakeLocked,
                noCPRToResume: !state.cprStarted && enteredAwake
            )
        } ?? []
    }

    /// The engine's redirect: pads on or CPR started keeps the patient on the static card.
    var awakeLocked: Bool { state.padsOn || state.cprStarted }

    /// From the log, like the card, so it can't go stale after the operator panel. A rescue that never
    /// did this looks as it always has.
    private var enteredAwake: Bool {
        log.entries.contains { $0.kind == .stateEntered && engine.definition(of: $0.detail)?.kind.isAwake == true }
    }

    /// AR can stop mid-rescue, for heat or a failure, and then there's nothing to aim at.
    var cameraLive: Bool { showsCamera && visionStatus == .running }

    /// Only a step with the pin takes a tap on the camera, so nowhere else can a stray one land.
    var acceptsInjuryTap: Bool { cameraLive && overlayTarget == .injurySite }

    /// A step drawing on the camera. The panels give up room here, so there's something to aim at: every
    /// awake step with a target, and on the arrest path the hands and the pads on the body. With no camera
    /// there's nothing to see, so the step keeps the full screen.
    var leavesRoomForCamera: Bool {
        guard cameraLive else { return false }
        if definition?.kind.isAwake == true { return overlayTarget != nil }
        return drawsOnBody
    }

    /// The arrest steps that light a part of the body: the hands on the chest, both pads, and the hands
    /// again for the first seconds of compressions. The arrest scan's arrow needs no room of its own.
    var drawsOnBody: Bool {
        overlayTarget == .chestCenter || overlayTarget == .padZones || showsHandsGuide
    }

    /// The chest zone and ghost hands at the start of compressions, entered from Start CPR, which never
    /// shows `place_hands`. Pose only, nothing sent, and it gates nothing.
    var showsHandsGuide: Bool { handsGuideUntil != nil }

    /// The metronome is on, so the ghost rescuer, if it has a place, is pushing on its beat.
    private(set) var metronomeOn = false
    /// A practice patient lies on the floor for the ghost to kneel beside.
    private(set) var practicePatientPlaced = false
    /// The ghost is on screen pushing on the beat, read each tick.
    private(set) var ghostShowsBeat = false
    /// The grip reminder's window after the beat starts.
    private(set) var gripReminderUntil: TimeInterval?
    nonisolated static let gripReminderSeconds: TimeInterval = 8

    /// The looping grip in the corner: on place_hands, and for the first seconds after the beat
    /// starts, whichever way compressions were reached and with or without a camera. It only shows.
    var showsGripReminder: Bool { overlayTarget == .chestCenter || gripReminderUntil != nil }

    /// The Push pulse, unless the ghost is up to follow instead. Whenever the ghost can't show, for no
    /// camera, lost tracking, nothing placed or the AED talking, the pulse comes straight back, so
    /// compressions always have a beat on screen.
    var showsBeatPulse: Bool { showsPulse && !ghostShowsBeat }

    /// Compressions with the camera up: the ghost can kneel by an imaginary patient when nobody is
    /// lying down. It draws only, sends nothing and gates nothing.
    var offersPracticePatient: Bool {
        cameraLive && metronomeOn && overlayTarget == nil && definition?.kind == .cpr
    }

    /// At a point in the camera view, in global points, which are the camera view's.
    func placePracticePatient(at point: CGPoint) {
        Task {
            let placed = await vision.placePracticePatient(atViewPoint: point)
            if placed { practicePatientPlaced = true }
        }
    }

    func clearPracticePatient() {
        vision.clearPracticePatient()
        practicePatientPlaced = false
    }

    /// Someone's hands belong on the wound here, not on the screen, and the limb isn't to be kept as found.
    private var handsOnInjury: Bool { state.stateID == ScenarioModule.handsOnInjuryState }

    var pinLabel: String { handsOnInjury ? "Possible break" : "Possible break. Keep as found" }

    /// A tap still works where this is false. Nothing asks for one.
    var invitesInjuryTap: Bool { !handsOnInjury }

    /// The engine and vision hold the real rule. This only stops the overlay redrawing for nothing on an
    /// arrest-only rescue, where it can never have anything to draw here.
    var mayShowCarriedAED: Bool { state.stateID == ScenarioModule.carriedAEDState && enteredAwake && !state.aedArrived }

    /// What's behind a panel can't be seen or aimed at, so a mark stays in the band between them.
    var marksKeepToFreeArea: Bool { leavesRoomForCamera || mayShowCarriedAED }

    /// The step on screen, always from the phrase file. A state with no phrase of its own keeps
    /// showing the last thing said, so the screen is never blank if audio is down.
    /// The step's own lines, less what's only said on the way, like "Calling 911 for you".
    private var instructionLines: [String] {
        (definition?.entryPhrases ?? []).filter { !Self.announcementPhraseIDs.contains($0) }
    }

    var instruction: String {
        let id = instructionLines.first ?? lastPhraseID ?? definition?.allowedSay.first
        return id.flatMap(engine.bundle.text(forPhrase:)) ?? ""
    }

    /// The rest of this step's own lines. They stay up as long as the step, because an open state
    /// has no timer to move it on, and the audio can be down.
    var stepDetail: String? {
        let lines = instructionLines.dropFirst().compactMap(engine.bundle.text(forPhrase:))
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    var flowExplanation: FlowExplanation? { FlowExplanation.build(from: log.entries, bundle: engine.bundle) }

    /// A report that moved nothing, so someone can see it was heard, and Not this is still theirs to use.
    var observationNote: String? { FlowExplanation.note(from: log.entries) }

    /// Long enough to catch a double tap or a tap as the timer moves on, too short to read a new step.
    /// A question waits longer, because the tap it might catch was aimed at the button that sat there
    /// before, and answers it unheard.
    var stepIsSettling: Bool {
        clock() - state.enteredAt < (definition?.question == nil ? Self.stepSettleSeconds : Self.questionSettleSeconds)
    }

    /// Hands are on the chest in these states, so the beat stays on screen even with the audio off.
    /// Never during AED analysis, when the AED is the authority and nobody should be touching.
    /// Nor while the AED is talking, because it may be saying the opposite.
    var showsPulse: Bool {
        guard let definition, definition.kind == .cpr, !aedTalking else { return false }
        return definition.metronome == .on || definition.metronomeToggleable
    }

    var aedTalking: Bool { state.audioPausedFor == .aedTalking }

    /// The link is up, but the AI can't hear. "Live" alone would say it can.
    var aiCannotHear: Bool { liveConnected && micProblem != nil && !state.callActive }

    /// The engine closes the mic and the voice for any call. Only awake states talk about it.
    var aiPausedForCall: Bool { liveConnected && state.callActive && definition?.kind.isAwake == true }

    var micClosedForDispatcher: Bool { state.dispatcherHeardUntil != nil }

    /// The AED finder needs a key to ask with and a camera to look through.
    var aedFinderAvailable: Bool { canLocate && showsCamera }

    /// The AI is up and the mic is open to it, so anything said now is heard.
    var aiListening: Bool { liveConnected && micProblem == nil && !state.callActive && !micClosedForDispatcher }

    var isHandoff: Bool { definition?.logOnEnter == .emsArrived }

    // MARK: - Assessing

    /// The opening step when there's an AI: all camera, and the AI works out what's going on.
    var isAssessing: Bool { state.stateID == ScenarioModule.assessState }

    /// What the AI has reported since assess opened, from the log, so it's only what the gate let through.
    var assessment: [AssessmentNote] { AssessmentNote.notes(from: log.entries) }

    /// The AI's latest sentence, which the person has already heard. Shown apart from the notes, since
    /// it's the AI's own words and the notes are fixed ones.
    var lastAISentence: String? { AssessmentNote.lastSentence(of: saidTranscript) }

    var assessStatus: String {
        if liveConnected { return cameraLive ? "Watching and listening" : "Listening. The camera is off." }
        if live == nil || lastDisconnect != nil { return "AI offline. Tap below to say what's happening." }
        return "Connecting to the AI"
    }

    var secondsUntilTimeout: TimeInterval? {
        guard let timeout = definition?.timeout, !engine.timersWait(for: state) else { return nil }
        return max(0, timeout.seconds - (clock() - state.enteredAt))
    }

    var elapsedSeconds: TimeInterval { max(0, clock() - state.startedAt) }

    var linkLabel: String {
        if liveConnected { return "Live" }
        return liveSwapping ? "AI switching, can't hear" : "Offline protocol"
    }

    var callerScript: CallerScript {
        CallerScriptBuilder.build(from: log.entries, location: location.current, resources: state.resources)
    }

    var handoffCard: HandoffCard { HandoffBuilder.build(from: log.entries) }

    var shocksMarked: Int { log.entries.filter { $0.kind == .shockMarked }.count }

    var canSeedBadLine: Bool { definition?.overlay == .chestCenter || canSeedAwakeLine }

    /// A closed step has no AI voice to correct, so the beat would show nothing true.
    private var canSeedAwakeLine: Bool {
        definition?.kind.isAwake == true && engine.bundle.definition.speechGate.openStates.contains(state.stateID)
    }

    // MARK: - Things people do

    func perform(_ action: HumanAction) {
        dispatch(.human(action))
    }

    /// A new step puts different buttons where the last one's were, so a tap aimed at those could answer this.
    func performStep(_ action: HumanAction) {
        if !stepIsSettling { perform(action) }
    }

    /// The arrest panel has no settle window, except on the question a report may have just thrown up
    /// under a finger aimed at an awake step's button. Start CPR doesn't come through here.
    func performAnswer(_ action: HumanAction) {
        if state.breathingAskedAwake { performStep(action) } else { perform(action) }
    }

    /// Start CPR never waits, except just after that same flip. The arrest panel puts it where the awake
    /// panel had a step's rows or the camera band, and a tap already on its way can't have read it.
    func performPrimary(_ action: HumanAction) {
        if state.breathingAskedAwake, clock() - state.enteredAt < Self.primarySettleSeconds { return }
        perform(action)
    }

    /// Mic uplink and model speech both close while the dispatcher is up, by the engine's policy.
    func setDispatcher(open: Bool) {
        guard open != dispatcherOpen else { return }
        dispatcherOpen = open
        dispatch(.human(open ? .dispatcherOn : .dispatcherOff))
        if open { location.refresh() }
    }

    func readAloud(_ text: String) {
        audio.speak(text: text)
    }

    /// Goes no further than vision, and nothing waits on it. The band grows when a step's rows go, so a tap
    /// aimed at those can land here, and it waits like they do.
    func tapCamera(at point: CGPoint) {
        guard acceptsInjuryTap, !stepIsSettling else { return }
        let vision = vision
        Task { [weak self] in
            let result = await vision.placeInjuryPin(atViewPoint: point)
            self?.note(result)
        }
    }

    private func note(_ result: InjuryPinResult) {
        switch result {
        case .placed:
            pinMessage = nil
        case .notPlaced:
            guard acceptsInjuryTap else { return }
            pinMessage = Prompt(text: "Couldn't place the pin. Tap again.", expiresAt: clock() + Self.pinMessageSeconds)
        case .superseded:
            break
        }
    }

    // MARK: - Operator

    func forceHandPlacement() {
        guard let id = engine.bundle.definition.states.first(where: { $0.overlay == .chestCenter })?.id else { return }
        force(stateID: id)
    }

    /// Goes through the real speech lane and the real validator, so only the trigger is staged. The
    /// lane plays in order, so the correction always follows the line it corrects.
    func seedBadLine() {
        guard canSeedBadLine else { return }
        operatorUsed = true
        let (id, line) = canSeedAwakeLine ? (Self.seededAwakePhraseID, Self.seededAwakeLine) : (Self.seededPhraseID, Self.seededLine)
        audio.play(phraseID: id)
        saidTranscript = trimmed("\(saidTranscript) [SEEDED] \(line)")
        var buffer = TranscriptBuffer()
        for flag in buffer.feed(line, profile: liveMode.profile) {
            dispatch(.sentinelFlag(flag), seeded: true)
        }
    }

    /// A real proposal, so the real gate rejects it.
    func seedStopReport() {
        operatorUsed = true
        let proposal = ModelProposal(
            action: .reportFinding(.breathingNormally, source: .seen, confidence: .high),
            stateVersion: state.version,
            issuedAt: clock()
        )
        noteModelCall(proposal, seeded: true)
        dispatch(.model(proposal), seeded: true)
    }

    func seedKeyword(_ keyword: AudioKeyword) {
        operatorUsed = true
        dispatch(.keyword(keyword), seeded: true)
    }

    func force(stateID: String) {
        let now = clock()
        guard let result = OperatorForce.walk(engine: engine, from: state, to: stateID, at: now) else { return }
        operatorUsed = true
        commit(result, at: now, seeded: true)
    }

    // MARK: - The engine

    func dispatch(_ event: RescueEvent, seeded: Bool = false) {
        let now = clock()
        commit(engine.reduce(state, event, at: now), at: now, seeded: seeded)
        if case let .model(proposal) = event { holdAsSuggestion(proposal) }
    }

    /// Runs the time-based rules. The loop calls this, and so do the tests with their own clock.
    func tick() {
        dispatch(.tick)
        let now = clock()
        if let prompt, now >= prompt.expiresAt { self.prompt = nil }
        if let pinMessage, now >= pinMessage.expiresAt { self.pinMessage = nil }
        let status = vision.status
        if status != visionStatus { visionStatus = status }
        if let until = handsGuideUntil, now >= until { handsGuideUntil = nil }
        if let until = gripReminderUntil, now >= until { gripReminderUntil = nil }
        if case let .done(at) = callerAgentStatus, now - at >= Self.callerAgentDoneSeconds { callerAgentStatus = .idle }
        let ghost = showsPulse && cameraLive && metronomeOn && vision.showsGhost
        if ghost != ghostShowsBeat { ghostShowsBeat = ghost }
        let talking = liveConnected && audio.modelAudioPending
        if talking != aiTalking { aiTalking = talking }
        retryLocate(at: now)
        watchAIVoice(at: now)
        assessIfDue(at: now)
        startCallerAgentIfDue()
    }

    private func commit(_ result: ReduceResult, at now: TimeInterval, seeded: Bool = false) {
        // A line about an awake step, like "No aspirin", has no place under the breathing question,
        // on triage, or in another flow.
        let next = engine.definition(of: result.state.stateID)
        if definition?.kind.isAwake == true, next?.kind.isAwake != true || next?.flow != definition?.flow {
            prompt = nil
        }
        let enters = result.effects.contains { if case .overlay = $0 { true } else { false } }
        if result.state.stateID != state.stateID {
            kickPhraseDone = false
            quietSince = nil
            if aiQuiet { aiQuiet = false }
        }
        if result.state != state { state = result.state }
        if !result.log.isEmpty {
            let first = log.entries.count
            log.append(result.log, at: now)
            if seeded { seededSequences.formUnion(first..<log.entries.count) }
        }
        // First, so that no callback thread can send on the old policy while effects run.
        gate.setPolicy(sessionPolicy(engine.policy(for: state, at: now), mode: definition?.kind.liveMode ?? liveMode))
        // Next, so that this state's policy and brief go to the session that will use them.
        let swapped = swapLiveIfNeeded(at: now)

        let wasScanning = overlayTarget == .aedDevice
        var prompted: [String] = []
        for effect in result.effects { apply(effect, prompted: &prompted) }
        if overlayTarget == .aedDevice, !wasScanning {
            // An awake state sends frames on speech alone.
            if definition?.kind.isAwake != true { vision.beginFrameBurst() }
            locateAED(at: now)
        }
        if enters {
            voiceSuggestion = nil
            // The moment the CPR path begins, so the call shows with the step, not a tick later.
            startCallerAgentIfDue()
            // Vision ends its guide on every overlay change, so this follows it.
            handsGuideUntil = nil
            if opensHandsGuide(result.effects) { beginHandsGuide(at: now) }
            // At once on each new step, rather than at the next retry.
            scanMaterials(at: now, waiting: false)
        }
        // Last, so its first connection is seeded with this state's brief.
        if swapped { gate.send(.start) }
    }

    private func apply(_ effect: RescueEffect, prompted: inout [String]) {
        vision.apply(effect)
        switch effect {
        case let .playPhrase(id):
            notePhrase(id, prompted: &prompted)
            audio.play(phraseID: id)
        case let .metronome(on):
            audio.setMetronome(on: on)
            vision.setGhostBeat(on: on)
            // The beat starting is compressions starting, so the grip shows for its first seconds.
            if on, !metronomeOn { gripReminderUntil = clock() + Self.gripReminderSeconds }
            if !on { gripReminderUntil = nil }
            metronomeOn = on
        case let .overlay(target):
            overlayTarget = target
            if target != .injurySite, pinMessage != nil { pinMessage = nil }
        case let .cues(cues):
            self.cues = cues
        case .flushModelAudio:
            audio.flushModelAudio()
        case let .dropQueuedPhrases(keeping):
            audio.dropQueuedPhrases(keeping: keeping)
        case .cutPhrases:
            audio.cutPhrases()
        case let .pauseAudio(seconds):
            audio.pause(seconds: seconds)
        case .resumeAudio:
            audio.resume()
        case .locate:
            lastLocateAt = clock()
        case let .policyChanged(policy):
            audio.setPolicy(audioPolicy(from: sessionPolicy(policy, mode: liveMode)))
            gate.send(.policy(policy))
        case var .sendStateBrief(brief):
            // A card's entry in the table can't know this session has nothing to say.
            if awakeVoiceUnheard { brief.modelSpeechOpen = false }
            latestBrief = brief
            gate.send(.brief(brief))
        }
    }

    /// An awake session with no approved text is never let through to the speaker.
    private var awakeVoiceUnheard: Bool { liveMode == .awake && engine.bundle.knowledgePack == nil }

    /// No approved text, no free speech. The awake states are closed in the table, but a card's entry
    /// there can't know which session is up, and a card keeps whichever was running.
    private func sessionPolicy(_ policy: RuntimePolicy, mode: LiveMode) -> RuntimePolicy {
        guard mode == .awake, engine.bundle.knowledgePack == nil else { return policy }
        var closed = policy
        closed.modelSpeechOpen = false
        return closed
    }

    /// With no model there is nobody to hear the mic, so it stays off and the phone doesn't show the
    /// recording indicator. Voice processing also changes how the beat sounds.
    private func audioPolicy(from policy: RuntimePolicy) -> RuntimePolicy {
        guard live == nil else { return policy }
        var local = policy
        local.audioMode = .playbackOnly
        return local
    }

    /// `prompted` is what one step has said so far, since it can say several things at once and
    /// the screen has to show them all.
    private func notePhrase(_ id: String, prompted: inout [String]) {
        guard let text = engine.bundle.text(forPhrase: id) else { return }
        lastPhraseID = id
        // `instruction` and `stepDetail` already show a step's own lines.
        if definition?.entryPhrases.contains(id) != true {
            prompted.append(text)
            prompt = Prompt(text: prompted.joined(separator: " "), expiresAt: clock() + Self.promptVisibleSeconds)
        }
    }

    // MARK: - Locating things in the room

    /// The first frame of a scan rarely shows what's wanted, and there is no need to wait for the model
    /// to ask. One in flight answers for itself, so this only asks again once the last one has ended.
    /// While the step's timer waits on the dispatcher, so do these, or they'd go on without end.
    private func retryLocate(at now: TimeInterval) {
        scanMaterials(at: now, waiting: true)
        guard overlayTarget == .aedDevice, now - lastLocateAt >= Self.locateRetrySeconds, !engine.timersWait(for: state) else { return }
        switch vision.aedStatus {
        case .locating, .located: break
        case .idle, .notFound, .noSurface, .unreliablePose: locateAED(at: now)
        }
    }

    private func locateAED(at now: TimeInterval) {
        guard canLocate else { return }
        lastLocateAt = now
        vision.apply(.locate(.aed))
    }

    /// The step's cued materials, and from the flow's first step every material the flow points at, so
    /// a locate that takes seconds is in by the step that needs it. Only where the step allows frozen
    /// frames to the locator, and never the AED, which has its own scan.
    func materialsToScan(at now: TimeInterval) -> Set<Material> {
        guard engine.policy(for: state, at: now).frameLocate else { return [] }
        let flow = engine.materialsToLocate(for: state, at: now)
        return Set(flow + cues.compactMap(\.material)).subtracting([.aed])
    }

    /// Like the AED's retries: each material is asked for again until it has been seen twice at about
    /// one spot, and again once a movable one's point runs out.
    private func scanMaterials(at now: TimeInterval, waiting: Bool) {
        guard canLocate, showsCamera, !engine.timersWait(for: state) else { return }
        if waiting, now - lastMaterialScanAt < Self.locateRetrySeconds { return }
        let due = materialsToScan(at: now).filter(needsLocating)
        guard !due.isEmpty else { return }
        lastMaterialScanAt = now
        vision.requestLocate(due)
    }

    private func needsLocating(_ material: Material) -> Bool {
        switch vision.locateStatus(material) {
        case .locating: false
        case .located: vision.sightings(of: material) < Self.sightingsToShow
        case .idle, .notFound, .noSurface, .unreliablePose: true
        }
    }

    // MARK: - The hands at the start of compressions

    /// The phrase the hands step says, which a Start CPR edge carries on into compressions instead.
    private var handsPhraseID: String? {
        engine.bundle.definition.states.first { $0.overlay == .chestCenter }?.entryPhrases.first
    }

    /// Compressions entered on an edge that says where the hands go, with no overlay of its own.
    private func opensHandsGuide(_ effects: [RescueEffect]) -> Bool {
        guard cameraLive, let definition, definition.kind == .cpr, definition.overlay == nil, let handsPhraseID else { return false }
        return effects.contains(.playPhrase(handsPhraseID))
    }

    private func beginHandsGuide(at now: TimeInterval) {
        vision.beginHandsGuide(seconds: Self.handsGuideSeconds)
        handsGuideUntil = now + Self.handsGuideSeconds
    }

    // MARK: - Callback threads into the main actor

    private func wireAudio() {
        let gate = gate
        let inbox = inbox
        let audio = audio
        let vision = vision
        audio.onUplinkPCM = { pcm in gate.sendMicAudio(pcm) }
        audio.onSpeechStarted = { [weak audio] in
            if gate.noteSpeechOnset() { audio?.flushModelAudio() }
            vision.beginFrameBurst()
            inbox.yield(.speech(started: true))
        }
        audio.onSpeechEnded = {
            gate.setBargeIn(false)
            gate.sendAudioEnd()
            inbox.yield(.speech(started: false))
        }
        audio.onPhraseFinished = { inbox.yield(.phraseFinished($0)) }
        audio.onCallChanged = { inbox.yield(.callChanged($0)) }
        audio.onStatus = { inbox.yield(.audioStatus($0)) }
    }

    private func startPumps() {
        let stream = inboxStream
        Task { [weak self] in
            for await item in stream {
                self?.handle(item)
            }
        }
        // The session re-checks too. This is the sender's half of "check on every send".
        let frames = vision.uplinkFrames
        let gate = gate
        Task.detached(priority: .utility) {
            for await frame in frames {
                gate.sendFrame(frame.jpeg)
            }
        }
    }

    private func startTickLoop() {
        guard runsTickLoop, tickLoop == nil else { return }
        tickLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func handle(_ item: Inbox) {
        switch item {
        case let .phraseFinished(id):
            // A voice just worked, so one failure earlier needn't warn for the rest of the run.
            if audioHealth == .voiceFailed { audioHealth = .ok }
            // The seeded line isn't something the protocol said, so the model isn't told it was.
            if id != Self.seededPhraseID, id != Self.seededAwakePhraseID { dispatch(.phrasePlayed(id)) }
            if Self.kickFollowsPhrase[state.stateID] == id {
                kickPhraseDone = true
                kickIfDue()
            }
        case let .callChanged(active):
            dispatch(.callChanged(active: active))
        case let .audioStatus(status):
            note(status)
        case let .speech(started):
            noteSpeech(started: started)
        case let .live(event, session):
            if session == liveSession { handle(event) }
        case let .modelVoice(session):
            if session == liveSession { noteModelVoice() }
        case let .auditFlag(flag, session):
            guard session == liveSession else { break }
            // Awake, it only keeps the record: a correction after a right answer sounds worse than a miss.
            if liveMode == .awake {
                log.append([LogEntry.Draft(kind: .sentinelFlag, source: .aiInferred, detail: flag.category.rawValue)], at: clock())
            } else {
                dispatchFlag(flag)
            }
        case let .quickLook(outcome, startedAt, session, round):
            guard session == liveSession, round == assessRound else { break }
            noteQuickLook(outcome, startedAt: startedAt)
        }
    }

    private func note(_ status: AudioStatus) {
        switch status {
        case let .running(mode):
            audioHealth = .ok
            if mode == .full { micProblem = nil }
        case .outputLost:
            audioHealth = .outputLost
        case let .micUnavailable(reason):
            micProblem = reason
        case .phraseFailed, .readAloudFailed:
            audioHealth = .voiceFailed
        case .phraseUsingSpeech, .runawayTurnStopped:
            break
        }
    }

    // MARK: - Live

    /// The caller sends `.start` once the session's policy and first brief are queued.
    private func startLive() {
        guard let stack = makeLive(liveMode) else { return }
        live = stack
        lastLiveSession += 1
        liveSession = lastLiveSession
        gate.setCurrentSession(lastLiveSession, mode: liveMode)

        let (commands, continuation) = AsyncStream.makeStream(of: LiveCommand.self, bufferingPolicy: .bufferingNewest(512))
        gate.setCommands(continuation)
        liveUplink = Self.runUplink(session: stack.session, commands: commands, gate: gate)
        liveRouter = Self.runRouter(session: stack.session, id: lastLiveSession, audio: audio, gate: gate, inbox: inbox)
    }

    private func stopLive() {
        gate.send(.stop)
        gate.setCommands(nil)
        gate.setBargeIn(false)
        gate.setCurrentSession(nil)
        liveSession = nil
        // The next mode is another scene, and a read of this one would sit over it.
        clearAssessment()
        // Lets the uplink drain the stop, then finish on its own.
        liveUplink = nil
        liveRouter?.cancel()
        liveRouter = nil
        live = nil
        liveConnected = false
        liveSwapping = false
        swapStartedAt = nil
        // What the last session said is judged by its own rules or not at all. A flag still waiting on
        // its last word goes on the record, with no correction, since the state has already moved.
        let unsettled = transcriptBuffer.endTurn()
        if !unsettled.isEmpty {
            log.append(unsettled.map { LogEntry.Draft(kind: .sentinelFlag, source: .aiInferred, detail: $0.category.rawValue) }, at: clock())
        }
        transcriptBuffer = TranscriptBuffer()
        turnText = ""
        turnFlags = []
        quietSince = nil
        awaitingAnswer = false
        if aiQuiet { aiQuiet = false }
    }

    /// A prompt and a contract are set at connect, so a new mode takes a new session, with no handle
    /// from the old one. This runs on every commit, so whatever the current state needs wins however
    /// fast the taps come, and each session that loses is stopped by its own uplink. Local guidance
    /// and taps don't pass through here.
    private func swapLiveIfNeeded(at now: TimeInterval) -> Bool {
        guard hasBegun, let wanted = definition?.kind.liveMode, wanted != liveMode else { return false }
        liveMode = wanted
        stopLive()
        audio.flushModelAudio()
        audio.modelTurnEnded()
        startLive()
        guard live != nil else { return false }
        liveSwapping = true
        swapStartedAt = now
        return true
    }

    /// Each send checks the policy again, since a command can wait here while the policy closes.
    private nonisolated static func runUplink(
        session: LiveSession,
        commands: AsyncStream<LiveCommand>,
        gate: UplinkGate
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            for await command in commands {
                switch command {
                case .start:
                    await session.start()
                case .stop:
                    await session.stop()
                    return
                case let .audio(pcm):
                    if gate.micOpen { await session.sendAudio(pcm) }
                case .audioEnd:
                    if gate.micOpen { await session.sendAudioStreamEnd() }
                case let .frame(jpeg):
                    if gate.framesOpen { await session.sendFrame(jpeg) }
                case let .brief(brief):
                    await session.sendStateBrief(brief)
                case let .policy(policy):
                    await session.applyPolicy(policy)
                case .kick:
                    await session.sendKick()
                }
            }
        }
    }

    /// Model audio goes straight from here to the audio controller, so a busy main actor can't make
    /// the voice stutter. Everything else keeps its order through the inbox. Every path to the audio
    /// asks the gate whether this session is still the current one.
    private nonisolated static func runRouter(
        session: LiveSession,
        id: Int,
        audio: any AudioPort,
        gate: UplinkGate,
        inbox: AsyncStream<Inbox>.Continuation
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var voiceNoted = false
            for await event in session.events {
                switch event {
                case let .modelAudio(pcm):
                    switch gate.admitModelAudio(session: id, play: { audio.enqueueModelAudio(pcm) }) {
                    case .stale:
                        return
                    case .closed:
                        break
                    case .played:
                        if !voiceNoted {
                            voiceNoted = true
                            inbox.yield(.modelVoice(session: id))
                        }
                    }
                case .turnComplete:
                    voiceNoted = false
                    guard gate.endModelTurn(session: id, apply: { audio.modelTurnEnded() }) else { return }
                    inbox.yield(.live(event, session: id))
                case .interrupted:
                    voiceNoted = false
                    guard gate.endModelTurn(session: id, apply: {
                        audio.flushModelAudio()
                        audio.modelTurnEnded()
                    }) else { return }
                    inbox.yield(.live(event, session: id))
                case .disconnected:
                    voiceNoted = false
                    inbox.yield(.live(event, session: id))
                default:
                    inbox.yield(.live(event, session: id))
                }
            }
        }
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .connected:
            liveConnected = true
            liveSwapping = false
            if let swapStartedAt {
                timings[.modeSwap, default: []].append(clock() - swapStartedAt)
                self.swapStartedAt = nil
            }
            kickIfDue()
        case let .disconnected(reason):
            liveConnected = false
            // The attempt failed, so "switching" stops being the honest word. The swap still times
            // through to whichever retry gets there.
            liveSwapping = false
            lastDisconnect = reason.description
            // No turnComplete is coming for this turn, and the next one must start with a clean
            // slate, or a repeat of the same bad line goes unflagged.
            gate.setBargeIn(false)
            audio.modelTurnEnded()
            finishModelTurn()
        case let .scene(report):
            noteScene(report)
        case let .proposal(proposal):
            noteModelCall(proposal, seeded: false)
            let before = log.entries.count
            dispatch(.model(proposal))
            // It's told to report and say nothing when it's only told something, so that's no silence.
            // An accepted call can log nothing at all, so only this call's own entries say how it went.
            if !log.entries[before...].contains(where: { $0.kind == .proposalRejected }) {
                quietSince = nil
                if aiQuiet { aiQuiet = false }
            }
        case .modelAudio:
            break
        case .interrupted:
            finishModelTurn(cut: true)
        case .turnComplete:
            finishModelTurn()
        case let .inputTranscript(text):
            heardTranscript = trimmed(heardTranscript + text)
            heardPending += text
            confirmIfSaid()
        case let .outputTranscript(text):
            saidTranscript = trimmed(saidTranscript + text)
            // The AI answering closes what the rescuer said, so the log keeps the order they spoke in.
            if turnText.isEmpty { flushHeard() }
            turnText += text
            for flag in transcriptBuffer.feed(text, profile: liveMode.profile) {
                turnFlags.insert(flag.category)
                dispatchFlag(flag)
            }
        case let .usage(usage):
            self.usage = usage
        case let .timing(metric, seconds):
            timings[metric, default: []].append(seconds)
        }
    }

    /// The auditor only flags, and nothing waits for it. Its answer lands whenever it lands, or not
    /// at all. A category the validators already caught in this turn isn't corrected twice.
    private func finishModelTurn(cut: Bool = false) {
        // Someone who talked over the answer is owed the next one, so the hold that would have started
        // with their speech starts now. The cut is the server hearing them, so a short question that
        // ended here just before it arrived counts too, and its wait runs from when it ended.
        let spokeJustNow = cut && lastSpeechEnd.map { clock() - $0 <= Self.cutFollowsSpeechSeconds } == true
        if personSpeaking || spokeJustNow, liveConnected, definition?.kind.isAwake == true, gate.micOpen, gate.modelAudioOpen {
            awaitingAnswer = true
            if !personSpeaking, quietSince == nil { quietSince = lastSpeechEnd }
            if !state.modelTurnActive { dispatch(.modelTurn(active: true)) }
        } else {
            awaitingAnswer = false
            if state.modelTurnActive { dispatch(.modelTurn(active: false)) }
        }
        for flag in transcriptBuffer.endTurn() {
            turnFlags.insert(flag.category)
            dispatchFlag(flag)
        }
        let spoken = turnText
        flushHeard()
        appendLog(.said, spoken)
        let flagged = turnFlags
        turnText = ""
        turnFlags = []
        guard let auditor = live?.auditor, let brief = latestBrief, let session = liveSession, !spoken.isEmpty else { return }
        let inbox = inbox
        let profile = liveMode.profile
        Task.detached(priority: .utility) {
            guard let flag = await auditor.audit(transcript: spoken, brief: brief, profile: profile),
                  !flagged.contains(flag.category)
            else { return }
            inbox.yield(.auditFlag(flag, session: session))
        }
    }

    // MARK: - Reading the scene

    /// The voice AI describes the camera itself, live, with `report_scene`. A quick look at one frame
    /// only fills in while it's been quiet, on a step that lets a frame leave the phone. Neither feeds
    /// the engine, so a slow or failed read changes nothing but the chip.
    private func assessIfDue(at now: TimeInterval) {
        guard liveConnected, let assessor = live?.assessor, let brief = latestBrief, let session = liveSession else { return }
        // Every step while the camera is up, so the log runs the whole rescue, but never while
        // someone else is on the line.
        let looks = cameraLive && gate.sceneReadOpen
        let why = "state=\(state.stateID) camera=\(showsCamera) vision=\(visionStatus.rawValue) sceneRead=\(gate.sceneReadOpen)"
        if why != lastLookReason {
            lastLookReason = why
            SituationAssessor.log("looks=\(looks) \(why)")
        }
        // While the voice model is describing the view itself, a second look would only cost quota.
        let liveSees = now - lastLiveSceneAt < Self.liveSceneFresh
        guard looks, !liveSees, !quickInFlight, now - lastQuickAt >= max(Self.quickLookGap, quickBackoff) else { return }
        quickInFlight = true
        lastQuickAt = now
        assessing = true
        let toolCalls = Array(modelCalls.filter { !$0.seeded }.suffix(Self.assessedToolCalls).map(\.summary))
        let input = AssessmentInput(brief: brief, heard: heardTranscript, said: saidTranscript, toolCalls: toolCalls)
        let mode = liveMode
        let round = assessRound
        let inbox = inbox
        let vision = vision
        let gate = gate
        let snapshotSeconds = Self.snapshotSeconds
        Task.detached(priority: .userInitiated) {
            var input = input
            let asked = Date()
            if let jpeg = await vision.snapshot(timeout: snapshotSeconds), gate.sceneReadOpen {
                input.jpeg = jpeg
                SituationAssessor.log("quick snapshot \(jpeg.count)B in \(Int(Date().timeIntervalSince(asked) * 1000))ms")
            } else {
                SituationAssessor.log("quick snapshot NONE after \(Int(Date().timeIntervalSince(asked) * 1000))ms")
            }
            // A quick look with no picture has nothing to look at.
            let outcome = input.jpeg == nil
                ? AssessmentOutcome(assessment: nil, problem: "no camera frame")
                : await assessor.quickLook(input, mode: mode)
            inbox.yield(.quickLook(outcome, startedAt: now, session: session, round: round))
        }
    }

    private func noteQuickLook(_ outcome: AssessmentOutcome, startedAt: TimeInterval) {
        quickInFlight = false
        assessing = false
        if let result = outcome.assessment {
            quickBackoff = 0
            assessmentStats.quick = Array((assessmentStats.quick + [clock() - startedAt]).suffix(20))
            // A live report that landed while this was out is newer, and keeps the screen.
            guard startedAt >= sceneStartedAt else { return }
            sceneRead = merged(result, startedAt: startedAt, source: .quickLook)
            noteEmergency(result.emergency)
            appendLog(.look, result.sees ?? result.headline, detail: result.prediction)
        } else if outcome.problem != "no camera frame" {
            // Waiting longer each time is what lets a rate limit or an overload clear.
            quickBackoff = min(Self.assessBackoffCap, max(2, quickBackoff * 2))
            assessmentStats.failures += 1
            assessmentStats.lastProblem = outcome.problem
            SituationAssessor.log("quick backing off \(Int(quickBackoff))s after \(outcome.problem ?? "?")")
            if sceneRead == nil { assessmentFailed = true }
        }
    }

    /// The voice model said what the camera shows. It lands at once, over any older read.
    private func noteScene(_ report: SceneReport) {
        guard let screened = SituationAssessor.screen(report, mode: liveMode) else {
            SituationAssessor.log("live scene dropped by the validators: \(report.headline) | \(report.prediction)")
            return
        }
        let now = clock()
        if lastLiveSceneAt.isFinite {
            assessmentStats.liveGaps = Array((assessmentStats.liveGaps + [now - lastLiveSceneAt]).suffix(20))
        }
        lastLiveSceneAt = now
        SituationAssessor.log("live scene: \(screened.sees ?? "-") | \(screened.headline) | \(screened.prediction) (\(screened.confidence.rawValue)) note=\(report.note)")
        sceneRead = merged(screened, startedAt: now, source: .live)
        noteEmergency(screened.emergency)
        let note = SituationAssessor.screenNote(report.note, mode: liveMode)
        appendLog(.saw, screened.sees ?? screened.headline, detail: [note, screened.prediction].compactMap { $0 }.joined(separator: " · "))
    }

    // MARK: - The 911 agent, simulated

    static let callerAgentStepSeconds: TimeInterval = 2.5
    /// The CPR path's steps. Entering any of them starts the call once, in the background, so the
    /// rescuer is never stopped to dial: "Calling 911 for you" is said on the way, not asked for.
    static let callerAgentStates: Set<String> = ["position_patient", "place_hands", "compressions"]
    /// How long "911 notified" stays up after the call ends.
    static let callerAgentDoneSeconds: TimeInterval = 15

    /// The background 911 call, for the pill on screen.
    enum CallerAgentStatus: Equatable {
        case idle
        case calling
        case done(at: TimeInterval)
    }

    /// A scripted call between an AI agent and a mock dispatcher, built from the caller script, so the
    /// log shows what an agent would say. Nothing is dialed, it's labeled a simulation, and it moves
    /// no step: the rescuer still taps Called.
    static func callerAgentLines(_ script: CallerScript) -> [String] {
        let done = script.actions.isEmpty ? "The caller is getting ready to start CPR, coached by the app." : script.actions.joined(separator: ", ") + "."
        return [
            "911 agent: calling the mock dispatcher. Simulation, no real call is placed.",
            "Dispatcher: 911, what's the address of your emergency?",
            "Agent: I'm an AI assistant calling for a bystander. \(script.locationLine)",
            "Dispatcher: Tell me exactly what happened.",
            "Agent: \(script.situation)",
            "Dispatcher: Is anyone helping the patient right now?",
            "Agent: \(done)",
            "Dispatcher: Help is on the way. Stay with them and keep following the app.",
            "911 agent: call ended. Help dispatched (simulated).",
        ]
    }

    private func startCallerAgentIfDue() {
        guard Self.callerAgentStates.contains(state.stateID), !callerAgentRan else { return }
        spawnCallerAgent()
    }

    /// Starts the simulated 911 agent's call now, from the Spawn 911 agent button or on the way to
    /// CPR. One at a time; it moves no step, and nothing is dialed.
    func spawnCallerAgent() {
        guard callerAgentStatus != .calling else { return }
        callerAgentRan = true
        callerAgentStatus = .calling
        let lines = Self.callerAgentLines(callerScript)
        let round = assessRound
        callerAgentTask = Task { [weak self] in
            for line in lines {
                guard let self, !Task.isCancelled, round == self.assessRound else { return }
                self.appendLog(.call, line)
                try? await Task.sleep(for: .seconds(Self.callerAgentStepSeconds))
            }
            guard let self, !Task.isCancelled, round == self.assessRound else { return }
            self.callerAgentStatus = .done(at: self.clock())
        }
    }

    /// A red line in the log when an emergency first shows, or changes, and not on every read of it.
    private func noteEmergency(_ emergency: String?) {
        defer { lastEmergency = emergency }
        guard let emergency, emergency.lowercased() != lastEmergency?.lowercased() else { return }
        appendLog(.alert, emergency)
    }

    /// The newest scene lines over whatever is on screen.
    private func merged(_ result: SituationAssessment, startedAt: TimeInterval, source: AssessmentSource) -> SituationAssessment {
        assessmentFailed = false
        sceneStartedAt = startedAt
        assessmentSource = source
        return result
    }

    /// Words go in as the voice AI or the rescuer finishes, so the log reads as turns.
    private func appendLog(_ kind: AssessmentLogEntry.Kind, _ text: String, detail: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nextLogID += 1
        assessmentLog.insert(AssessmentLogEntry(id: nextLogID, at: elapsedSeconds, kind: kind, text: trimmed, detail: detail?.isEmpty == true ? nil : detail), at: 0)
        if assessmentLog.count > Self.maxLogEntries { assessmentLog.removeLast(assessmentLog.count - Self.maxLogEntries) }
    }

    /// A collapse report on assess, which core held, becomes the ringed button.
    private func holdAsSuggestion(_ proposal: ModelProposal) {
        guard state.stateID == ScenarioModule.assessState,
              case let .reportFinding(finding, _, confidence) = proposal.action, confidence != .low else { return }
        switch finding {
        case .unresponsive: voiceSuggestion = .notResponding
        case .notBreathing, .abnormalBreathing: voiceSuggestion = .notBreathing
        default: break
        }
    }

    /// "Confirm" from the rescuer presses the ringed button, as a tap would. Their own words, from the
    /// live transcript of the mic: the AI's speech is a separate transcript and can't confirm anything.
    private func confirmIfSaid() {
        guard let suggestion = assessSuggestion, let action = suggestion.confirmAction,
              heardPending.range(of: #"\bconfirm(ed)?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return }
        flushHeard()
        appendLog(.heard, "Confirmed by voice: \(suggestion.rawValue.replacingOccurrences(of: "_", with: " "))")
        perform(action)
    }

    private func flushHeard() {
        appendLog(.heard, heardPending)
        heardPending = ""
    }

    private func clearAssessment() {
        assessRound += 1
        sceneRead = nil
        voiceSuggestion = nil
        assessmentLog = []
        assessmentFailed = false
        assessing = false
        quickInFlight = false
        heardPending = ""
        lastEmergency = nil
        callerAgentTask?.cancel()
        callerAgentTask = nil
        callerAgentStatus = .idle
        callerAgentRan = false
        lastQuickAt = -.infinity
        lastLiveSceneAt = -.infinity
        assessmentSource = nil
        sceneStartedAt = -.infinity
        quickBackoff = 0
    }

    /// A flag from the model's own words. Where none of them could be heard, it goes on the record and
    /// nobody is corrected for words the gate dropped.
    private func dispatchFlag(_ flag: SentinelFlag) {
        let now = clock()
        var result = engine.reduce(state, .sentinelFlag(flag), at: now)
        if awakeVoiceUnheard {
            result.effects.removeAll { if case .playPhrase = $0 { true } else { false } }
        }
        commit(result, at: now)
    }

    // MARK: - The AI's voice, awake

    /// Nothing prompts the model to speak first, so it gets one cue a rescue, once `triage_ask` is
    /// out of the way. Not over someone talking, or while waiting on the answer to them, since
    /// client content can interrupt a turn.
    private func kickIfDue() {
        guard !kickSent, kickPhraseDone, liveConnected, gate.modelAudioOpen, !personSpeaking, quietSince == nil,
              !state.modelTurnActive, Self.kickFollowsPhrase[state.stateID] != nil
        else { return }
        kickSent = true
        gate.send(.kick)
        // A cue that gets no reply is the AI going quiet too.
        quietSince = clock()
    }

    /// Only speech the AI could have heard and answered starts the wait. A re-ask holds from its start,
    /// since it would say its line over them, and the answer they're about to get would have to wait.
    private func noteSpeech(started: Bool) {
        personSpeaking = started
        if !started { lastSpeechEnd = clock() }
        quietSince = nil
        if started, aiQuiet { aiQuiet = false }
        guard liveConnected, definition?.kind.isAwake == true, gate.micOpen, gate.modelAudioOpen else { return }
        if started {
            if !state.modelTurnActive {
                awaitingAnswer = true
                dispatch(.modelTurn(active: true))
            }
            return
        }
        // They've had their say, and a cue now could land on the answer. Speech that ended while
        // `triage_ask` played may only be that phrase coming back through the mic, so it doesn't count.
        if kickPhraseDone { kickSent = true }
        // A noise while the AI talks isn't a question it has left waiting.
        if !state.modelTurnActive || awaitingAnswer { quietSince = clock() }
    }

    private func noteModelVoice() {
        // Its first audio just played, so this shows without waiting for the next tick.
        if liveConnected { aiTalking = true }
        quietSince = nil
        awaitingAnswer = false
        if aiQuiet { aiQuiet = false }
        guard definition?.kind.isAwake == true else { return }
        // It has already talked, so a cue could only cut it off, or have it introduce itself again.
        kickSent = true
        dispatch(.modelTurn(active: true))
    }

    private func endAnswerWait() {
        guard awaitingAnswer else { return }
        awaitingAnswer = false
        if state.modelTurnActive { dispatch(.modelTurn(active: false)) }
    }

    private func watchAIVoice(at now: TimeInterval) {
        guard liveConnected, gate.modelAudioOpen, definition?.kind.isAwake == true else {
            quietSince = nil
            if aiQuiet { aiQuiet = false }
            endAnswerWait()
            return
        }
        if let quietSince, now - quietSince >= Self.aiQuietSeconds {
            self.quietSince = nil
            aiQuiet = true
        }
        if !personSpeaking, quietSince == nil { endAnswerWait() }
        kickIfDue()
    }

    private func noteModelCall(_ proposal: ModelProposal, seeded: Bool) {
        flushHeard()
        appendLog(.tool, seeded ? "[seeded] \(proposal.summary)" : proposal.summary)
        nextModelCallID += 1
        modelCalls.append(ModelCall(
            id: nextModelCallID,
            at: clock(),
            summary: proposal.summary,
            seeded: seeded
        ))
        if modelCalls.count > Self.maxVoiceRows { modelCalls.removeFirst(modelCalls.count - Self.maxVoiceRows) }
    }

    private func trimmed(_ text: String) -> String {
        String(text.suffix(Self.maxTranscriptCharacters))
    }
}

extension SituationAssessment.Suggestion {
    /// The tap "confirm" stands in for. None for the 911 agent, which starts a simulated call rather than a step.
    var confirmAction: HumanAction? {
        switch self {
        case .startCpr: .startCpr
        case .notResponding: .patientUnresponsive
        case .notBreathing: .patientNotBreathing
        case .awake: .patientAwake
        case .callForHelp: nil
        }
    }
}
