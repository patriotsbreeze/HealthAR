import RescueCore
import RescueVision
import SwiftUI

enum AppSheet: String, Identifiable {
    case dispatcher, sentinel, operatorPanel, agents
    var id: String { rawValue }
}

/// Strip, rail, band, deck. The band is a slot in the same stack as the deck, so it is all of the
/// camera that can be seen and tapped, and nothing in it can overlap a button.
struct MainScreen: View {
    let coordinator: AppCoordinator
    @State private var sheet: AppSheet?
    @State private var showsHUD = false
    @State private var pendingStop: RescueControl?
    @State private var freeArea = CGRect.zero
    @State private var guideHeight: CGFloat = 0
    /// The whole screen's height, for the assess panel's cap.
    @State private var screenHeight: CGFloat = 0

    var body: some View {
        ZStack {
            // Dusk, not flat black, so the glass has something to sit on when no camera is up. The
            // camera covers it whenever one is.
            LinearGradient(colors: [DS.Glass.backdropTop, DS.Glass.backdropBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            cameraLayer
            VStack(spacing: 0) {
                StatusRail(
                    coordinator: coordinator, showsHUD: $showsHUD,
                    onAgents: { present(.agents) }, onDispatcher: { present(.dispatcher) }, onSentinel: { present(.sentinel) },
                    onOperator: { present(.operatorPanel) }
                )
                if showsHUD { LatencyHUD(coordinator: coordinator) }
                if coordinator.isHandoff {
                    HandoffCardView(coordinator: coordinator)
                        .padding(.horizontal, DS.Space.deckInset)
                        .padding(.bottom, DS.Space.s)
                } else {
                    band
                        // Read straight off the band, then published. A GeometryReader's preference
                        // could miss the last change when the deck settles its height a pass after a
                        // step changes, and the marks would stay inside a band that has since grown.
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { freeArea = $0 }
                        .preference(key: FreeCameraArea.self, value: freeArea)
                }
                // Sized first, so the band gets what's left, and never less than its least.
                if coordinator.isAssessing {
                    AssessPanel(coordinator: coordinator, screenHeight: screenHeight)
                        .layoutPriority(1)
                } else {
                    CommandDeck(coordinator: coordinator, onStopRequested: { pendingStop = $0 })
                        .layoutPriority(1)
                }
            }
            // Above the panels, or a chest outside the band would hide behind them. The marks themselves
            // stay inside the band.
            if coordinator.showsCamera {
                OverlayLayer(coordinator: coordinator, band: freeArea)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if let control = pendingStop {
                StopConfirmation(
                    control: control,
                    showsPulse: coordinator.showsPulse,
                    operatorUsed: coordinator.operatorUsed,
                    // The operator can restart or force a state from there, and this question was
                    // about the step it was raised in.
                    onOperator: {
                        pendingStop = nil
                        present(.operatorPanel)
                    }
                ) {
                    coordinator.perform(control.action)
                    pendingStop = nil
                } onCancel: {
                    pendingStop = nil
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { screenHeight = $0 }
        // Past this the step alone would fill the screen and push the way out off it.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sensoryFeedback(DS.Haptics.compressions, trigger: coordinator.state.stateID) { _, new in new == "compressions" }
        // A confirmation never outlives the state it was raised in, so "Yes, stop CPR" can't act on another.
        .onChange(of: coordinator.state.stateID) { pendingStop = nil }
        #if DEBUG
        .task {
            // After the staged walk, so what opens sits over the step it was asked for.
            try? await Task.sleep(for: .milliseconds(600))
            if StagedLaunch.showsHUD { showsHUD = true }
            if StagedLaunch.showsStop { pendingStop = coordinator.controls.first { $0.role == .stopsCPR } }
            if let staged = StagedLaunch.sheet { present(staged) }
        }
        #endif
        .sheet(item: sheetBinding) { current in
            switch current {
            case .dispatcher:
                DispatcherSheet(coordinator: coordinator, onClose: { present(nil) }, onOperator: { present(.operatorPanel) })
            case .sentinel: SentinelPanel(coordinator: coordinator) { present(.operatorPanel) }
            case .agents: AgentsSheet(coordinator: coordinator) { present(.operatorPanel) }
            case .operatorPanel:
                OperatorPanel(coordinator: coordinator, showsHUD: $showsHUD) { present(.sentinel) }
            }
        }
    }

    /// Fills the same frame as the overlay, so normalized overlay points land on the camera image.
    @ViewBuilder private var cameraLayer: some View {
        if coordinator.showsCamera, let session = coordinator.vision as? VisionSession {
            ARCameraView(session: session).ignoresSafeArea()
        }
        #if DEBUG
        if coordinator.showsCamera, coordinator.vision is StagedVision {
            StagedBackdrop().ignoresSafeArea()
        }
        #endif
    }

    private var awake: Bool { coordinator.definition?.kind.isAwake == true }

    private var band: some View {
        ZStack(alignment: .bottomLeading) {
            if coordinator.acceptsInjuryTap {
                // Between the panels by construction, so a tap here can't be aimed at a button. The camera
                // view fills the window, so global points are its points.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .global) { coordinator.tapCamera(at: $0) }
            } else {
                Color.clear
            }
            if coordinator.showsBeatPulse {
                // The AR is the beat to follow. This dot is the fallback for when the ghost can't show.
                BeatPulse(diameter: DS.Pulse.docked, showsLabel: false)
                    .padding(DS.Pulse.dockedInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
            if coordinator.showsGripReminder {
                // Trailing, level with the camera's middle, below the beat's dot and the read at the top.
                GripReminderCard()
                    .padding(.trailing, DS.Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if showsVoice || showsAssessment || showsCallerAgent {
                // Top-leading is the one corner nothing else in the band uses. A tap goes through the
                // orb; the read beside it opens on one. The 911 call sits under them, so the two stack
                // rather than overlap while the rescuer gets on with CPR.
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    if showsVoice {
                        ListeningBubble(mode: coordinator.aiTalking ? .talking : .listening)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    if showsAssessment && coordinator.isAssessing {
                        // On assess, the read is the point, so it goes big and the log waits for later.
                        SituationHero(
                            assessment: coordinator.sceneRead,
                            assessing: coordinator.assessing,
                            failed: coordinator.assessmentFailed,
                            confirmedEmergency: coordinator.confirmedEmergency,
                            confirmTitle: coordinator.assessSuggestion.flatMap { $0.confirmAction == nil ? nil : $0.buttonTitle },
                            onConfirm: { coordinator.confirmEmergency() }
                        )
                        .transition(.opacity)
                    } else if showsAssessment {
                        AssessmentChip(
                            assessment: coordinator.sceneRead,
                            log: coordinator.assessmentLog,
                            source: coordinator.assessmentSource?.rawValue,
                            assessing: coordinator.assessing,
                            failed: coordinator.assessmentFailed
                        )
                        // Level with the orb's middle, and it opens downward from there.
                        .padding(.top, showsVoice ? (DS.Listening.frame - DS.Height.control) / 2 : 0)
                        .transition(.opacity)
                    }
                }
                if showsCallerAgent {
                    CallerAgentPill(status: coordinator.callerAgentStatus) { present(.dispatcher) }
                        .transition(.opacity)
                }
                }
                .padding(DS.Space.m)
                // Out to the right edge, but clear of whatever holds the other corner: the beat's dot, or the
                // grip reminder while it shows.
                .padding(.trailing, assessmentTrailingClearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if coordinator.overlayTarget == .padZones {
                // Vision finds the body some frames in, and nothing here would redraw when it does.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    if !coordinator.arDrawsPads {
                        PadZonesGuide()
                            .padding(DS.Space.m)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            if let guide = coordinator.definition?.guide {
                // On a camera step it sits in the corner, and a tap on it counts as a tap on the camera.
                GuideCard(guide: guide, bundle: coordinator.engine.bundle, pictureOnly: coordinator.leavesRoomForCamera)
                    .padding(coordinator.leavesRoomForCamera ? DS.Space.m : DS.Space.s)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { guideHeight = $0 }
                    .rowTypeCap()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(!coordinator.leavesRoomForCamera)
            }
        }
        .frame(maxWidth: .infinity, minHeight: bandMinimum, maxHeight: .infinity)
        .animation(DS.Motion.alert, value: showsVoice)
        .animation(DS.Motion.alert, value: showsAssessment)
    }

    private var showsVoice: Bool { coordinator.aiTalking || coordinator.aiListening }

    /// A read only with the AI up, since one from a session that's gone would be about another scene.
    private var showsCallerAgent: Bool { coordinator.callerAgentStatus != .idle }

    private var assessmentTrailingClearance: CGFloat {
        if coordinator.showsBeatPulse { return DS.Pulse.docked + DS.Pulse.dockedInset }
        return 0
    }

    private var showsAssessment: Bool {
        // The log shows on its own too, so the 911 agent's call is seen even with the AI offline.
        !coordinator.assessmentLog.isEmpty
            || coordinator.liveConnected && (coordinator.assessing || coordinator.sceneRead != nil || coordinator.assessmentFailed)
    }

    /// Only a camera step's is a promise to someone aiming, the arrest path's hands and pads among
    /// them. An awake step's empty band needs nothing.
    private var bandMinimum: CGFloat {
        if coordinator.leavesRoomForCamera { return DS.Band.camera }
        // A guide card keeps its whole height, which grows with the text size.
        if awake { return coordinator.definition?.guide == nil ? 0 : max(DS.Band.guide, guideHeight) }
        return DS.Band.arrest
    }

    private var sheetBinding: Binding<AppSheet?> {
        Binding(get: { sheet }, set: { present($0) })
    }

    /// Every way a sheet closes comes through here, so a swipe still ends the dispatcher state.
    private func present(_ next: AppSheet?) {
        coordinator.setDispatcher(open: next == .dispatcher)
        sheet = next
    }
}
