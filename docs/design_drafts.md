# Design drafts

Three independent drafts. The approved plan in `plan.md` merges them and overrides them where they differ.

=== DRAFT: fastest-demo ===
# Fastest credible demo plan: AI + AR emergency guide

**Pitch:** one iPhone and one 3-minute scripted adult cardiac arrest. The phone owns every safety-critical behaviour. Gemini Live acts as ears and eyes that report what it perceives, and it never makes decisions.

**Assumptions to confirm:** this is a private demo, iPhone only, 2-3 people, about 5 working days (my estimate). If it becomes a public product, the terms and FDA blockers in the brief come first, and most of the cuts below need revisiting.

**Local state checked:**
- The folder is empty and is not a git repo.
- `gh` has one account logged in, `patriotsbreeze`. `somenerdbrendan` is not logged in on this machine.
- The global git identity is the `patriotsbreeze` noreply address, and `patriotsbreeze/HealthAI` does not exist yet.
- I could not confirm the account's email is blobrendan422@gmail.com, because `gh api user/emails` needs the `user` scope. The Apple Development certificate does use that address.
- iPhone 15 Pro Max "ninja" is paired but currently unavailable. `xcodegen` and `uv` are installed.

## 1. The single scripted scenario

**Cast:**
- Rescuer and Helper (both holding roles on stage)
- A lying adult volunteer
- A CPR manikin and an AED trainer
- A table with gloves and a towel
- A "paramedic" teammate

| Time | Beat | Real or mocked |
|---|---|---|
| 0:00 | Volunteer collapses. One tap opens the app, and a local voice asks "Is the person responding?" | Real, works with no network |
| 0:10 | Rescuer says "No, he's just gasping." Live calls `report_finding`, the engine advances and says gasping is not normal breathing. | Real AI hearing, deterministic decision |
| 0:15 | Call 911 button opens a **mock dispatcher sheet** with a live caller script card. | **Mocked dial**, real card |
| 0:25 | AR ring appears on the volunteer's chest. Rescuer moves to the manikin ("we never compress a real person"). A local 110/min metronome starts and the first-compression timer stops. | Real on-device AR and metronome |
| 0:50 | Rescuer asks mid-compression, "Should I check his pulse?" Live picks `say(no_pulse_check)`. The metronome never wavers. | Real |
| 1:10 | Operator fires a labelled **seeded hallucination** ("you can stop compressions"). Sentinel flags it and plays a correction. | **Seeded trigger**, real detection path |
| 1:30 | Helper pans the room. Chips appear for AED, gloves and towel. An arrow locks onto the AED and holds after Helper walks away and returns. | Real, one-shot cloud plus local anchor |
| 2:00 | AED steps with coarse pad zones. The app goes quiet while the trainer talks, and "shock delivered" is logged. | Real logic, **trainer prop** |
| 2:30 | Airplane mode on stage. Metronome, phrases and overlays continue, with an "Offline protocol" banner. | Real |
| 2:50 | Paramedic arrives. One-screen handoff card with a source-tagged timeline, read aloud. | Real |

**Cut order if behind:** pad zones, then the AED arrow (voice only), then the LLM auditor (keep validators).

**Never cut:** offline protocol, ring, metronome, Live intake, handoff card.

## 2. Feature triage

| Idea item | Verdict | Reason |
|---|---|---|
| Phone camera input | **Build** | Everything else depends on it |
| AR: CPR hand position | **Build** | Headline moment. Coarse palm-sized ring before compressions only, because a rescuer cannot watch a screen while compressing |
| AR: point at tools (AED) | **Build** | One-shot box plus world anchor. AED is static, so seconds of latency are fine |
| AR: AED pad zones | **Build** | About 2 hours on the same torso map. Voice defers to the pad pictures |
| How to use AED | **Build** | Deterministic steps |
| What resources you have | **Build** | Best showcase of real VLM value |
| Step-by-step guidance | **Build** | State machine with pre-rendered phrases, because LLM omissions dominate published failures |
| Gemini Live | **Build** | Only documented continuous frame input, GA model |
| Low latency | **Build, by split** | Local loop for anything rhythmic. Cloud is about 1-2 s, shown honestly on a HUD |
| Voice agent, hears and sees | **Build** | Real hearing and tool calls. Model voice is muted in critical states |
| Sentinel | **Build** (layered), **fake** the trigger | Cannot un-say audio, so pitch it as containment, not prevention |
| CPR beat | **Build** metronome | Local double-click at 110/min, 545 ms per beat |
| CPR beat as a commercial song | **Cut** | App Store 4.5.2(ii) names this exact use and requires rights-holder permission |
| EMS report | **Build** | Built from the app's event log, never model transcripts. Cheap and memorable |
| EMS transmission, NEMSIS export | **Cut** | No route for a bystander app, so on-screen only |
| 911 agent | **Fake** | Mock sheet, because iOS has no autonomous path and a real call may interrupt app audio |
| Autonomous AI 911 call | **Cut, permanently** | Blocked by platform and carrier routing, and legally risky |
| SOS signal | **Cut** | No public API. A static line teaches the side button |
| PPG to the VLM to decide | **Cut, permanently** | A false pulse could stop CPR, and AHA has lay rescuers skip pulse checks |
| PPG, awake patient | **Cut**, last-day stretch only | Absent from the arrest scenario, and a finger on the lens blocks AR. If added, it only feeds the EMS card |
| Compression rate or depth score | **Cut, do not fake** | Cloud cannot sample it, Class II software, and a fake number would mislead |
| OpenAI Realtime | **Cut** | Snapshots only, and about a day for a second integration. The offline floor covers failure |
| Fine-tuned medical models, MedGemma | **Cut** | Cannot enter the realtime loop, wrong image domain |
| Open source models | **Cut** | Gemma 4 benchmarks are text only, with a multi-GB download |
| Backend, ephemeral tokens | **Cut** | One less failure domain. See rules in section 6 |
| Agent framework | **Cut** | One Live session, one async auditor and one engine are enough |
| ARKit body tracking, YOLO, LiDAR body lock, gravity patient selection | **Cut** | Staged framing removes the need. YOLO returns only if Vision fails M2 |

## 3. Architecture

**Core rule:** the model reports and the engine decides. There are no `show_overlay` or `start_metronome` tools.

**Components:**
- **ProtocolEngine** (pure Swift): states are `intakeResponsive → intakeBreathing → call911 → placeHands → compressions → aedScan → aedOn → pads → analyze → compressions → handoff`. Uncertainty defaults to CPR. A "Start CPR" button is always visible. Only a human tap can leave CPR.
- **AR:** RealityKit `ARView` with `ARWorldTrackingConfiguration` and plane detection. Avoid `ARSCNView`, which Apple now marks deprecated.
- **Pose:** Vision `DetectHumanBodyPoseRequest` (iOS 18+, returns multiple observations), latest frame wins. Keypoints go to `TorsoMap`, which is bilinear in the shoulder-hip quad at u=0.5, v≈0.22 (the brief's unvalidated derivation). Map to screen with `displayTransform`. Draw in one 2D overlay, and project the AED world point onto the same layer.
- **Ring states:** TRACKING or STALE only. When hands cover the torso, the ring fades and voice takes over.
- **Audio:** one `AVAudioEngine` with voice processing on. It mixes the metronome (`AVAudioSourceNode`), `PhrasePlayer` and `ModelAudioPlayer`. Echo and ducking behaviour needs a device test.
- **Live:** raw `URLSessionWebSocketTask` to `BidiGenerateContent?key=…` with `models/gemini-3.8-live`. Firebase is skipped because the brief says its model list omits this model.
- **Setup fields:** audio modality, `MEDIA_RESOLUTION_LOW`, `contextWindowCompression`, `sessionResumption`, and input and output transcription. Compression is mandatory, because audio plus video otherwise dies at 2 minutes.
- **Tools** (`NON_BLOCKING`, responses sent `SILENT`, with `status` fields): `report_finding`, `report_resources`, `say(phrase_id)`, `locate_object`, `log_event`.
- **Sentinel layers:**
  1. Engine invariants.
  2. `SpeechGate` drops model audio in `placeHands`, `compressions`, `pads` and `analyze`.
  3. Regex validators on `outputTranscription` for pulse checks, stopping CPR, doses and death statements.
  4. Async `gemini-3.5-flash-lite` auditor that flags only and never gates.
- **AEDLocator:** frozen JPEG plus ledger pose, `gemini-3.8-flash` returns `box_2d`, then a ray goes through `ARRaycastQuery(origin:direction:…)` to a world point.

**Data flow:**
```
ARSession frames ─┬─ PoseTracker → TorsoMap → OverlayCanvas           (local)
                  ├─ FrameUplink: 1 per 5-10 s, 1 FPS during scan → LiveClient
                  └─ FrameLedger: frameId → camera transform, intrinsics
Mic → voice-processed input → 16 kHz PCM → LiveClient
LiveClient toolCall → ProtocolEngine → phrases, metronome, overlay target, EventLog
LiveClient audio → SpeechGate → speaker (open states only)
LiveClient transcript → validators + async auditor → SentinelPanel, correction phrase
EventLog → CallerCard, HandoffCard (items tagged timer / sensor / bystander / AI)
```

## 4. Repo structure (`patriotsbreeze/HealthAI`, private)

```
HealthAI/
  README.md                 # simulation only, run steps
  project.yml               # XcodeGen; .xcodeproj gitignored
  Config/                   # Demo.xcconfig, Secrets.example.xcconfig; Secrets.xcconfig gitignored
  Packages/EmergencyCore/   # testable with `swift test`, no device
    Sources/ ProtocolEngine, EventLog, TorsoMap, Validators, HandoffBuilder, LiveMessages
    Tests/
  App/
    UI/       EmergencyView, OverlayCanvas, CallerCard, MockDispatcherSheet,
              SentinelPanel, HandoffCard, OperatorPanel, LatencyHUD
    AR/       ARSessionController, PoseTracker, FrameLedger, AEDLocator
    Audio/    AudioEngine, Metronome, PhrasePlayer, ModelAudioPlayer, SpeechGate
    Live/     LiveClient, FrameUplink, Auditor
    Resources/ protocol_cpr_aed.json, phrases/*.wav, system_prompt.md
  tools/      render_phrases.py (macOS `say` first), eval_scene.py, check_no_911.sh
  docs/       demo_script.md, research_brief.md, safety_limits.md
```

Phrases say "centre of the chest", because the sources conflict on lower half versus lower third of the sternum. `check_no_911.sh` runs as an Xcode build phase rather than CI, because it is stronger and needs no runner.

## 5. Milestones

Thresholds are my proposals. The app is demoable from the end of M1 onward.

| # | When | Deliverable | Verification |
|---|---|---|---|
| M0 | Day 1 am | Private repo, XcodeGen project on the iPhone, paid API key, props secured | `gh repo view patriotsbreeze/HealthAI --json visibility,owner` shows PRIVATE. Hello-world runs on "ninja". **Risk:** phone iOS version unknown, and Xcode 26.4.1 may not deploy if it runs a newer iOS (unverified) |
| M1 | Day 1 | Engine, phrases, metronome, event log, tap-only flow | `swift test` covers all transitions and "no model event leaves CPR". Full run in airplane mode. Recorded click interval 545 ms ±5. App open to metronome ≤ 15 s |
| M2 | Day 1-2 | Ring on a real lying volunteer, manikin test | Tape placed by a CPR-trained person. In 30 sampled frames, ring covers tape in ≥ 27. Acquire ≤ 2 s. 10 min without `thermalState` serious. **Fail path:** try `yolo26n-pose` (license unverified), then a disclosed tap-to-place. If the manikin is not detected, keep the volunteer for AR |
| M3 | Day 2 | Live voice, tools, frames | See the M3 checks below. **Go/no-go at end of Day 2** |
| M4 | Day 3 am | SpeechGate and Sentinel | Validator unit tests. Seeded line flagged ≤ 3 s. Auditor killed mid-run and guidance unaffected. Model audio is silent in critical states |
| M5 | Day 3 | Scene scan, AED arrow, AED flow, pad zones | 20 photos across spots and lighting: AED box IoU ≥ 0.5 in ≥ 16. Arrow holds on the AED after a 2 m walk away and back. App silent in `analyze` |
| M6 | Day 4 am | Caller card, mock dispatcher, handoff card, HUD | `strings` on the Demo binary finds no `tel:911`. Card matches the event log line by line. Readout ≤ 30 s |
| M7 | Day 4-5 | Rehearse, freeze | 10 consecutive runs on venue network: ≥ 9 without OperatorPanel. First compression ≤ 30 s every run. Backup video recorded. Tag `demo-v1`. iOS updates off |

**M3 checks:**
- 20 scripted utterances produce the correct tool call in ≥ 18.
- Median end of speech to tool call ≤ 2.5 s, logged.
- 5-minute soak with frames survives past the 2-minute limit, plus a `goAway` resume.
- Metronome on speaker with someone counting aloud does not stall the session. Muted playback makes false barge-ins cheap, but missed tool calls still count against the 18 of 20.
- Audio keeps flowing during tool calls with no 1008 close.
- Test which path forces a scan turn: `clientContent` with `turnComplete` or `realtimeInput.text`.

**If M3 fails:** Live moves to scene scan only, and intake uses big buttons. Disclose this on stage.

## 6. Stage and safety rules

- **Demo build never holds 911.** The emergency number is set by build config, and the build phase fails if 911 appears outside Release.
- **API key stays on one device.** No TestFlight or distribution, restrict the key, never log the URL, rotate after the demo. The docs show `key` as a query parameter, so the risk is real if the build leaves the team.
- **Paid tier only.** Free-tier content is used to improve products, and the volunteer is on camera.
- **Volunteers:** adults, with written consent. No compressions on anyone. App splash reads "SIMULATION".
- **Have a CPR instructor read the phrase list.** AHA full text was blocked for the researchers.
- **OperatorPanel** (hidden gesture) can force any state. Say so on stage if it is used.
- **Decision for you:** Gemini API terms bar "medical advice" and I found no demo carve-out. Low risk privately, but settle it before any public release or public video. This is not legal advice.
- **Budget:** about $1.50 per 10 minutes (brief's estimate), roughly $40 for rehearsals (my estimate).

**State plainly that the demo does not prove:**
- sternum accuracy on real people, or across bodies and clothing
- time-to-first-compression against dispatcher-only coaching, which matters given AHA's cognitive-aid warning
- coexistence with a real cellular call
- clinical validity of any kind

## 7. Flags on the brief

- **Scheduling value:** the capabilities page says `INTERRUPTED` and the tools page says `INTERRUPT`. This plan sends `SILENT`, so it avoids the question.
- **Tool status fields:** the brief says they are needed, but the migration doc only recommends them. Include them anyway.
- **`768x768`:** the brief attributes this to the capabilities page, which does not state a size. Harmless, keep it.
- **Mid-session `send_client_content`:** the migration doc describes it only for history seeding, while a search extract of the capabilities guide says it works all session. Hence the M3 test.
- **New risk not in the brief:** a community report says audio sent during a tool call can close the socket with 1008. It is not official, so M3 tests it.
- **Muting the model client-side is my design, not documented.** Delivered audio stays in session history, so the model believes it spoke. Watch for odd follow-ups in M3.
- **Doubtful:** the brief's `show_overlay` and `start_metronome` tools. I removed them, so the model cannot drive safety-relevant actions.

### Critical Files for Implementation
All are to be created, since the repo is empty.
- /Users/brendanlo/Documents/GitHub/HealthAI/Packages/EmergencyCore/Sources/EmergencyCore/ProtocolEngine.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/App/Live/LiveClient.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/App/Audio/AudioEngine.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/App/AR/PoseTracker.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/docs/demo_script.md

### Sources
- [Live API capabilities](https://aistudio.google.com/docs/live-api/capabilities)
- [Live API tools](https://aistudio.google.com/docs/live-api/tools)
- [Session management](https://aistudio.google.com/docs/live-api/session-management)
- [Ephemeral tokens](https://aistudio.google.com/docs/live-api/ephemeral-tokens)
- [Live WebSocket reference](https://aistudio.google.com/api-reference/live)
- [Get started with WebSockets](https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket)
- [Live capabilities guide, on `send_client_content`](https://ai.google.dev/gemini-api/docs/live-guide)
- [Gemini 2.5 to 3.8 Live migration](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/migrate-from-gemini-2-5-to-gemini-3-8-live)
- [Model deprecations](https://aistudio.google.com/docs/deprecations)
- [Gemini pricing](https://aistudio.google.com/docs/pricing)
- [Image understanding, `box_2d`](https://aistudio.google.com/docs/image-understanding)
- [Gemini API terms](https://aistudio.google.com/docs/terms)
- [Community report on 1008 during tool calls](https://discuss.ai.google.dev/t/gemini-live-api-issues-1008-1011-disconnects-per-session-cost-function-calling-api-logs/116509)
- [`ARRaycastQuery`](https://developer.apple.com/tutorials/data/documentation/arkit/arraycastquery.json)
- [`DetectHumanBodyPoseRequest`](https://developer.apple.com/tutorials/data/documentation/vision/detecthumanbodyposerequest.json)
- [`setVoiceProcessingEnabled`](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:).json)
- [WWDC20 Vision body pose](https://developer.apple.com/videos/play/wwdc2020/10653/)
- [WWDC21 Vision, ARKit frames](https://developer.apple.com/videos/play/wwdc2021/10040/)
- [App Store guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Ultralytics pose](https://docs.ultralytics.com/tasks/pose)
- Clinical, FDA and 911 claims come from the research brief's cited sources, including [AHA 2025 Part 7](https://www.ahajournals.org/doi/10.1161/CIR.0000000000001369), [AHA 2025 Part 12](https://www.ahajournals.org/doi/10.1161/CIR.0000000000001374) and [21 CFR 870.5210](https://www.law.cornell.edu/cfr/text/21/870.5210). I did not re-verify those.

=== DRAFT: safety-first ===
# HealthAI implementation plan: real bystander, real patient

## Bottom line
"Never worse than 911 plus the dispatcher" cannot be guaranteed by architecture. It can only be tested as non-inferiority in simulation, using time to call, time to first compression, and compression quality. No small study can show a survival effect.

The idea as written fails that test, because AHA 2025 says interactive aids delayed calling EMS and starting compressions by 30-70 seconds.

So there are two builds:
- **Emergency build:** works with all AI removed.
- **Demo build:** holds the cloud models and AR until each passes a gate. In both builds, models can only perceive and suggest.

One consequence affects the pitch. A lone rescuer on one phone mostly gets the dispatcher plus a timeline. The app adds value with a second bystander or phone, while 911 is on hold, or with no signal.

## Corrections to the research brief (checked today)
I read the AHA text through a fetch tool's extraction, so a clinician must still read the originals.

1. **The cognitive aid finding is stronger than the brief says.** It is COR 3: No Benefit, LOE C-LD, and its examples include apps and voice prompts ([AHA Part 12 mirror](https://u1-cd-cpr.sc.heart.org/en/resuscitation-science/cpr-and-ecc-guidelines/resuscitation-education-science); the canonical page returned 403). Even the no-AI build falls inside it.
2. **The FDA Class I path is doubtful.** The brief treats hand placement and metronome as Class I. The raw text says "for the professionally trained rescuer" and "intended for use by persons professionally trained in CPR" ([21 CFR 870.5210](https://www.law.cornell.edu/cfr/text/21/870.5210)), which does not plainly fit lay bystanders. Treat the no-AI build's classification as open. Software feedback on CPR quality still needs a 510(k).
3. **The sternum discrepancy is resolved.** Part 7 says "lower half to lower third of the sternum", COR 1, LOE C-LD. A lone rescuer with a phone activates EMS and immediately begins CPR ([AHA Part 7 mirror](https://u1-cd-cpr.sc.heart.org/en/resuscitation-science/cpr-and-ecc-guidelines/adult-basic-life-support)). I found no lay stop-CPR recommendation in the 91% of the page I read, so stop wording is a clinician decision.
4. **AR has less support than the brief implies.** Part 12's take-home #5 says "AR should not be used to teach CPR skills", alongside a COR 2b on AR feedback in training. Neither endorses AR in a live rescue.
5. **Sources conflict on Gemini output.** [AI Studio](https://aistudio.google.com/docs/live-api/capabilities) says native audio models only support AUDIO, while the [Agent Platform page](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-3-8-live) lists text output. This design does not depend on either.
6. **Same-phone coaching may not survive a call.** Apple's [archived audio guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html) says an app is suspended if the user accepts a call during an interruption. That guide is old and describes incoming calls. Assume no app audio during a same-phone 911 call until a device spike proves otherwise.
7. **The brief's mock-dispatcher demo creates a new hazard.** A demo build used in a real emergency would dial a teammate. Milestone M0 addresses this.

## Rules enforced in code
Runtime authority order: dispatcher, then AED voice prompts, then the local protocol, then the model.

1. **911 is always one tap away.** It is on every screen, and nothing on that path waits for network, permission, consent, or login.
2. **The app adds no setup delay.** The emergency build needs no camera, mic, or location prompt to work. Those are requested at onboarding only, and if not granted the feature stays off.
3. **No model output can de-escalate.** It cannot leave the CPR state, stop the metronome, or dismiss 911.
4. **The model never speaks.** All speech is a local pre-rendered clip chosen by the state machine. Clips also start faster than the roughly 1.2 s independent first-audio figure for Gemini Live.
5. **Only a human can stop CPR guidance.** That takes a 2 s hold plus a fixed confirmation. An "AED talking" tap pauses the metronome for at most 20 s, then it resumes.
6. **Uncertainty goes to CPR.** "Not sure" or no answer after 10 s on the breathing question takes the CPR path. There is no pulse check, and PPG is not linked into the emergency build.
7. **The overlay never gates anything.** It gets at most 3 s, is off during compressions, and the cloud can hide it but never place it.
8. **Failure only steps down, with no user action needed.**

The numeric thresholds are my proposals, for clinician approval.

## Clinical source of truth
- **Location:** `clinical/` holds versioned YAML for states, transitions, and phrases. Each item has a phrase ID, original wording, a guideline citation, and a reviewer.
- **Compiler:** `tools/protocolc` (Python 3.14) rejects a bundle unless all of these hold:
  - Every state has a citation and a timeout.
  - Every path reaches CPR or EMS handoff.
  - No model-sourced event sits on a de-escalation edge.
  - Clips are 5 s or shorter.
  - Every number is on an allowlist.
- **Sign-off:** a named medical director approves a content hash. The `HealthAI` target will not compile with unsigned content.
- **Delivery:** the bundle ships inside the app, with no over-the-air clinical updates and no web RAG. A hash check at launch detects corruption.
- **Review cycle:** every 12 months and on any AHA or ILCOR update. An expired bundle still works and raises an internal alert, because it must never disable itself.

## How the LLM is constrained
The model sees frames and hears speech, and its only output is typed tool calls. A pure function, `SafetyGate`, decides what each call may do.

| Model may emit | Effect |
|---|---|
| `resource_seen(enum)`: AED, tourniquet, second person | One hint clip with an enum direction slot, once only |
| `speech_intent(enum)` | "Dispatcher or AED talking" ducks audio for at most 8 s. "Breathing normally", "stop", and "EMS here" change nothing and are logged only |
| `propose_escalation(enum)` | Asks a fixed yes/no question and never cancels anything |
| `answer(snippet_id or none)` | Plays an approved snippet if allowed in this state, at most once per 20 s. Otherwise: "Keep going. Ask the dispatcher." |
| `highlight(enum)` | Only if on-device tracking already has a lock |

**Not exposed at all:** free text to the user, numbers, doses, diagnoses, stop or pause, dialing or contacting anyone, overlay coordinates, and EMS card facts. Every call also carries a state version and expires after 5 s. Text in the scene or hostile speech can only reach this enumerated output space.

**Why audio is discarded rather than screened:**
- OpenAI states corrective instructions [cannot retract audio already heard](https://developers.openai.com/api/docs/guides/voice-server-controls).
- One developer reported 3.8 Live [transcripts containing unspoken words](https://discuss.ai.google.dev/t/gemini-3-8-live-1011-1008-session-drops-runaway-audio-and-output-transcription-with-unspoken-text/190881), so a clean transcript may not prove what was said.

**This reopens the brief's model pick.** Continuous video and native voice no longer matter, so M6 compares three options:
- **A:** `gemini-3.8-live` with client-side audio discard. The docs do not say whether a turn can be tool-only, and you still pay for audio.
- **B:** `gpt-realtime-2.1` with [`output_modalities` text](https://developers.openai.com/api/docs/guides/realtime-conversations) and snapshots.
- **C:** on-device [`SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer) (iOS 26) plus stateless vision calls. This has no session limits and no token step at start, and it avoids the resumption and zero-retention conflict.

Medical and fine-tuned models stay out. This design gives no generated advice, which may help with Google's and OpenAI's terms but does not settle them, so get a written answer.

## Data flow
```
Touch, on-device speech, timers, CXCallObserver, audio interruptions
        |
        v
ProtocolEngine (pure reducer) --> AudioCore (signed clips, metronome)
   ^          |               --> SwiftUI screen
   |          +--> EventLog (append-only) --> HandoffCard
SafetyGate (pure)
   ^  typed proposals, 5 s TTL
CloudLoop (optional, model audio dropped)
   ^  on-demand frames with faces blurred, mic PCM
Camera / mic

Perception (ARKit, pose) --> overlay only. No path to the engine.
```
Build boundaries enforce this. `ProtocolEngine`, `SafetyGate`, and `EventLog` have no network or media dependencies, and the `HealthAI` target does not link `CloudLoop`, `Perception`, or `PPG` until their gates pass.

## Degraded modes
| Mode | Trigger | User gets |
|---|---|---|
| Full (gated) | All gates passed, cloud healthy | Local protocol, cloud hints, overlay |
| Local (default) | No model, no network, no consent | Clips, 110/min double-click metronome, timers, card |
| Quiet | Same-phone call connected ([`CXCallObserver`](https://developer.apple.com/documentation/callkit/cxcallobserver)) or audio interrupted | "Follow the dispatcher", visual pulse, hand diagram, log. No audio unless the spike proves it safe and the user opts in |
| Static | Bad bundle or engine fault | Cards compiled into the binary, plus 911 |
| Nothing | App dead | User is already on 911 or dials natively. Onboarding teaches side-button SOS |

| Failure | Detection | Behavior | Test |
|---|---|---|---|
| Model or token backend outage | No setup in 3 s, 1011 or 1008 close, watchdog | Step down silently, retry in background | Block hosts; flow is identical |
| Bad network | State version plus TTL | Stale proposals dropped | Link conditioner: 100% loss, 5 s delay |
| Hallucinated instruction | Gate allowlist per state | Rejected and logged, never voiced | Fuzz adversarial tool calls: 0 illegal transitions |
| Model says "breathing, stop CPR" | Trust table | No state change; logged as AI-inferred | Scripted scenario |
| Wrong person in frame | Exactly one torso, horizontal against gravity | No ring, voice only | Upright rescuer plus patient; two lying people; child |
| Wrong overlay | Palm-sized region, time box, cloud veto, stale check | Ring hidden; voice says "centre of the chest" | Measured error; hand position against voice-only arm |
| Ambient TV or AED voice | Speech can only hint | No stop; duck is time-boxed | Audio replay suite |
| Crash or kill | Journal replay on launch | Same state within 1 s, metronome restarts | Kill during CPR on device |
| Audio route or volume | Route and `outputVolume` checks | Restart engine, visual pulse, "turn up volume" | Unworn Bluetooth, volume 0 |
| Heat or low battery | `thermalState` | Drop camera and cloud first, never audio | Xcode thermal condition |

The no-mic emergency build uses `.playback`, which avoids the voice-processing ducking in the brief. Any mic-enabled build mixes the metronome into one `AVAudioEngine`.

## Your feature list
| Idea | Emergency build | Demo build |
|---|---|---|
| Step-by-step guidance | Deterministic protocol | Same |
| Tool and resource awareness | Off until gated | Enum hints |
| Body and AED overlays | Off. AED pads: "follow the pictures on the pads" | Chest ring, manikin or volunteer |
| Autonomous 911 agent | Not built: no public iOS path, plus legal conflicts | Mock dispatcher only |
| 911 help | Human dials; live caller card; Read Aloud on tap only; pre-filled text-to-911 that the user sends | Same, with mock number |
| Sentinel | `SafetyGate` plus compiler checks. Say "constrains", never "prevents hallucinations" | Adds async auditor |
| CPR beat | Local metronome, no commercial song | Same |
| PPG | Not linked | Awake volunteer only, separate screen |
| EMS report | Card from `EventLog`, each item tagged timer, bystander, or AI-inferred; no transcripts; deleted after 24 h unless the user exports it | Same |

## Repo structure
Native Swift 6.3 with SwiftPM packages and an iOS 26 target, which fits the installed Xcode 26.4.1.
```
HealthAI/
  README.md            NOT FOR REAL EMERGENCIES banner, stage status
  SAFETY.md            rules, gates, hazard log index
  .github/CODEOWNERS   clinical/ requires medical director
  clinical/            protocols/ phrases/ snippets/ citations/ hazards/ signoff/
  tools/protocolc/     validate, exhaustive state check, render audio, hash
  tools/lint/          911 string check, target-link check
  ios/
    App/HealthAI/      emergency target
    App/HealthAIDemo/  demo target (different icon, name, permanent banner)
    Packages/          ProtocolEngine SafetyGate EventLog ClinicalContent
                       AudioCore CallPath HandoffCard CloudLoop Perception PPG
  backend/token/       Node 24 token mint, App Attest, stores nothing
  evals/               labelled scenes and audio, scoring harness
  sim/                 fault scenarios, adversarial model replay
  studies/             protocols, consent forms, pre-registered margins
```

## Milestones, in order
Efforts are my rough solo estimates. Device tests that need a call use a teammate's phone, never 911.

| # | Build | Verified by |
|---|---|---|
| M0 (3 d) | `git init`; `gh repo create patriotsbreeze/HealthAI --private --source . --remote origin`. CI. Two mutually exclusive targets: the demo button reads "CALL MOCK DISPATCHER", with a permanent "this will not call 911" banner. Spike: what survives an outgoing cellular call | Repo private under the right account; CI fails if `911` appears outside the emergency config or the demo flag reaches it. Written table for audio, mic, and camera during a call on two iPhones |
| M1 (3 d) | Draft adult arrest bundle marked DRAFT; `protocolc` | Exhaustive check passes; deliberately bad bundles fail; unsigned content blocks the emergency target |
| M2 (3 d) | `ProtocolEngine`, `SafetyGate`, `EventLog` | Fuzzed sequences: every rule holds. Journal replay is deterministic. Package graph has no network |
| M3 (1 wk) | No-AI app: `CallPath`, `AudioCore`, screens, Quiet and Static modes | Full flow in airplane mode. Metronome 110 ± 1/min from a recording. Cold launch to button under 1 s on an iPhone 13 class device. Every fault row with a local trigger passes |
| M4 (1 d) | `HandoffCard` | Paramedic review of 3 to 5 cards; no diagnosis text; timeline survives a clock change |
| M5 (1 wk) | **First go/no-go, before any AI.** Naive adults, manikin, mock dispatcher using a standard telecommunicator CPR script, against native dial | Pilot about 20 per arm. If the app is 10 s or more slower at median to call or to first compression, redesign and do not add AI. Check IRB needs first |
| M6 (1-2 wk) | `CloudLoop` in demo build; options A, B, C; `evals/` set | Cellular latency with frames flowing; recognition scored per enum; hint false positives; 10,000 adversarial sessions with 0 illegal transitions; outage mid-session is invisible except for lost hints |
| M7 (2 wk) | `Perception`: ARWorldTracking, 2D pose bake-off, torso homography, tracking and hold states | Lying adults across body types, skin tones, and clothing: acquire in 2 s, 4.5 cm error in 90% of frames (tolerance needs clinician confirmation). 0 ring placements on the wrong person in multi-person scenes. Time to first compression unchanged |
| M8 (3 d) | Async auditor | Seeded errors caught, measured. Cut it if it adds nothing beyond `SafetyGate` |
| M9 | Validation study and gates below | Pre-registered non-inferiority, about 130 per arm for a 10 s margin at SD 25 s, 90% power (the SD is my assumption; replace it with the M5 pilot figure) |

**Hackathon cut:** M0 to M3, then a minimal M6 and M7 in the demo build, in about 2 weeks. Use a manikin for compressions and a lying volunteer for the ring, since pose models may not detect a torso-only manikin. Never do compressions on a volunteer, and never dial 911 on stage.

## What must be true before this touches a real emergency
All of these, or it stays on team devices with the banner.

1. **Medical director:** named, has signed the content hash, has read Parts 4, 6, 7, 10, and 12 in full, and the hazard log is closed.
2. **Part 12 answered with data:** M9 shows non-inferiority on time to call and time to first compression, with a resuscitation expert's view on scope. Results are reported honestly as simulation only.
3. **FDA:** written counsel opinion plus a 513(g) or Q-Submission covering lay-user metronome and voice prompts. Rate or quality feedback stays out without a 510(k). If this comes back badly, the fallback is static content, timers, and 911.
4. **Same-phone behavior known:** tested on devices, plus an Apple DTS answer or a test arranged through a PSAP's non-emergency line. The app must demonstrably not interfere with the call.
5. **911 path:** human-initiated only, and 911-telecom counsel has reviewed state auto-dialer law.
6. **Fault suite:** 100% pass on real devices across iOS 26 and 27, with guidance continuing within one beat (545 ms) of a cloud failure.
7. **Human factors:** summative testing under stress and noise. Language and hearing limits are stated.
8. **Vendor terms:** written clearance, or ship without any cloud model, which this design allows.
9. **Privacy:** Apple 5.1.2(i) AI consent, paid tier only, Washington health-data and FTC breach review by counsel, no face embeddings or voiceprints, and an answer from Apple on 5.1.5 for location.
10. **Organization:** legal entity, liability insurance, AI voice that does not imply a licensed professional, and an incident process. A remote switch may disable the cloud only, never the local protocol.

Then release in order: no-AI build first, cloud hints second, overlay last. Each step needs its own study showing no added delay. A field pilot, if any, runs only under an EMS agency's medical director and an IRB.

## Open decisions
- Is this a hackathon or a product? This sets how many gates apply now.
- Who is the medical director?
- For a real product, are you willing to ship a first version with no visible AI? I recommend yes.

The repo name `patriotsbreeze/HealthAI` looks free, and `gh` and the global git identity both point to `patriotsbreeze`. I did not create it because this step is read-only. That is the first action in M0.

## Sources checked today
- [AHA Part 12 mirror](https://u1-cd-cpr.sc.heart.org/en/resuscitation-science/cpr-and-ecc-guidelines/resuscitation-education-science)
- [AHA Part 7 mirror](https://u1-cd-cpr.sc.heart.org/en/resuscitation-science/cpr-and-ecc-guidelines/adult-basic-life-support)
- [21 CFR 870.5210](https://www.law.cornell.edu/cfr/text/21/870.5210)
- [OpenAI server controls](https://developers.openai.com/api/docs/guides/voice-server-controls)
- [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [Gemini Live capabilities](https://aistudio.google.com/docs/live-api/capabilities)
- [Gemini 3.8 Live guide](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-3-8-live)
- [Apple audio interruption guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)
- [CXCallObserver](https://developer.apple.com/documentation/callkit/cxcallobserver)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)

All other facts come from the research brief.

### Critical Files for Implementation
These do not exist yet because the repo is empty.
- /Users/brendanlo/Documents/GitHub/HealthAI/clinical/protocols/adult_arrest.yaml
- /Users/brendanlo/Documents/GitHub/HealthAI/tools/protocolc/check.py
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/ProtocolEngine/Sources/ProtocolEngine/Reducer.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/SafetyGate/Sources/SafetyGate/Gate.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/AudioCore/Sources/AudioCore/Metronome.swift

=== DRAFT: latency-architecture ===
# Realtime implementation plan: phone AI + AR emergency guide

Nothing was created or changed in this step. All latency numbers are my targets, not vendor figures or standards, unless cited. API names without a citation come from my SDK knowledge, and M0/M1 will confirm they compile.

## 1. Core decision

The experience is four independent loops. Nothing slow can block anything fast.

- **Authority:** an on-device protocol engine decides what happens next.
- **Model role in critical states:** the live model acts as eyes and ears that return structured events. Its speech is dropped on the phone, and the app plays pre-rendered local phrases instead.
- **Why this is also the fastest option:** a local phrase can start in under 100 ms, while cloud speech takes about 1.5 s or more.
- **Why it is the only hard speech guarantee:** Google documents no way to force 3.8 Live silent or tool-only ([guide](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-3-8-live)). A gate on the phone is what enforces it.

## 2. Latency budgets

| Loop | Runs on | Path | Target (p50 / p95) | On a miss |
|---|---|---|---|---|
| A. Metronome | Phone, audio render thread | Sample counter to output | Zero interval drift by construction; starts under 50 ms after a state change | No dependencies, so nothing can stall it |
| B. Protocol prompt | Phone | Tap to first audio; local keyword to first audio | Under 100 ms; under 500 ms | Tap targets always remain |
| C. Overlay | Phone | Camera frame, keypoints, screen | World-locked ring at display rate; inference at most 33 ms; keypoint age 50 / 80 ms; acquire within 2 s | Hide ring if age exceeds 200 ms or confidence is low, then use voice |
| D. Voice reply | Cloud | End of speech to first audible word | Local earcon under 150 ms; model 1.7 / 2.8 s | At 3 s play a local phrase; two misses in a row trigger failover |
| E. Vision decision | Cloud | Frame captured to tool call applied | 2 / 4 s; one-shot `locate` 3 / 8 s | Reject stale results by epoch, then ignore |
| F. Sentinel rules | Phone | Tool call to accept or reject; transcript delta | Under 1 ms; under 5 ms | Fails open to the protocol |
| G. Auditor | Cloud | Finished turn to flag | Under 3 s p95; correction phrase within 200 ms of the flag | Timeout is ignored and never gates |
| H. Reconnect | Cloud | Socket drop to resumed | Under 2 s | Failover, with loops A to C unaffected |
| I. Launch | Phone | Launch to first instruction | Warm under 1 s; cold under 2 s | Nothing may block this |

Loop D estimate:
- Client voice-activity (VAD) hangover: about 300 ms.
- Uplink: about 50 ms.
- [Artificial Analysis](https://artificialanalysis.ai/speech-to-speech) time to first audio: 1.18 s. This is audio only, and it is unclear whether it includes VAD.
- Playout buffer: about 80 ms.
- Total: about 1.6 s, which M2 must measure with frames flowing.

Latency levers I found in the docs:
- **Faster end of speech:** keep server VAD on and send `audioStreamEnd` when the client VAD hears the end of speech. Google says this prompts immediate finalization, which avoids the 500 to 800 ms silence wait ([capabilities](https://aistudio.google.com/docs/live-api/capabilities), [reference](https://aistudio.google.com/api-reference/live)).
- **Chunk size:** send 20 to 40 ms chunks with no significant buffering ([best practices](https://aistudio.google.com/docs/live-api/best-practices)).
- **Barge-in:** flush playback on the client VAD onset. Do not wait for the server's `interrupted` message.
- **Noise control:** send mic audio only when the client VAD opens, with a 300 ms pre-roll. Metronome ticks and panting then never reach server VAD.

## 3. What runs where

| Function | Location | Why |
|---|---|---|
| Protocol state machine, phrases, metronome, event log, 911 script, handoff card | Phone | Must work in airplane mode; beat is 545 ms at 110/min |
| Pose, AR anchors, overlay, AED tracking | Phone | Live input is capped at 1 FPS, so per-frame anchoring from the cloud cannot work |
| Client VAD, keyword speech recognition, Sentinel rules | Phone | Network round trips exceed the budgets |
| Understanding speech and scenes, resource inventory | `gemini-3.8-live` | Only documented continuous frame path; not time-critical |
| Fallback | `gpt-realtime-2.1` over WebSocket with `input_image` snapshots | Separate failure domain |
| One-shot `locate` | `gemini-3.8-flash` via backend | Lets a specific frame be tied to a stored camera pose |
| Auditor | `gemini-3.5-flash-lite` via backend | Cheap and out of band |
| Backend | Node 24, Hono, one small service | Token minting and proxying only; no media relay, which would add latency and patient data exposure |

## 4. Agent topology

This is one live session plus deterministic services. There is no orchestrator and no agent-to-agent traffic, because every hop would add latency and give up control.

The agents in the original idea map as follows:

| Idea | Implementation |
|---|---|
| Voice agent | `LiveSession`, the only long-running model |
| Sentinel | Sync rules on the phone plus a stateless auditor call per turn; it can stop model speech and cannot stop guidance |
| 911 agent | No AI on the line. `CallScript` is a live card built from the event log, and the human dials |
| EMS report | `HandoffCard`, a template over the event log, never model transcripts |
| PPG agent | Removed from emergency paths (see section 8) |

The pitch can still show these as named lanes on screen.

## 5. iOS concurrency model

Use Swift 6 language mode with a deployment target of iOS 26.

| Execution context | Work | Rules |
|---|---|---|
| Audio render thread | Metronome and voice source nodes, mic sink | No allocation, locks, actors or class reference counting. Uses atomics and single-producer ring buffers only |
| `ar.delegate` serial queue | Copy pose, intrinsics and timestamp to the ledger; hand the pixel buffer to a one-slot mailbox | Return immediately. At most 2 buffers held |
| `PoseWorker` actor on its own serial queue | Crop, Core ML or Vision inference, torso target, filter | Latest frame wins, older frames dropped |
| `FrameEncoder` serial queue | Scale to 768 px, JPEG, under 15 ms | Runs only when frame policy asks |
| `AudioUplink` serial queue, 20 ms tick | Resample to 16 kHz Int16, VAD, pre-roll, keyword recognizer feed | Bounded at 200 ms, drop oldest |
| `LiveClient` actor | WebSocket send and receive, JSON | Off main; frames are latest-wins |
| `ProtocolEngine` actor | Pure reducer `(State, Event) -> (State, [Effect])` | No clock or I/O inside; timestamps arrive with events, so runs replay exactly |
| Main actor | SwiftUI, ARView updates | No inference or encoding |
| `EventLog` serial queue | Append-only NDJSON with monotonic and wall time | Fire and forget |

Hard rules:
- Communication between contexts is one-way, through mailboxes, ring buffers or atomics.
- Copy data out of `ARFrame`. ARKit warns once more than 10 frames are retained, and the camera can start dropping at about 15 to 20 ([Apple forum](https://developer.apple.com/forums/thread/695404), [Apple forum](https://developer.apple.com/forums/thread/831772)).
- `ThermalGovernor` sheds load in this order: fewer uploaded frames, inference from 30 to 15 to 10 FPS, then AR off. It never touches audio or the protocol.

## 6. Audio session design

**Session:** `.playAndRecord`, mode `.voiceChat`, option `.defaultToSpeaker`, preferred IO buffer 10 ms. Activate it before the first UI paint.

**Graph:** a single `AVAudioEngine` with voice processing on from launch.

```
inputNode (VP) -> AVAudioSinkNode -> SPSC ring -> AudioUplink
MetronomeNode (source, double click at 110/min) -> mixer -> outputNode (VP)
VoiceBusNode  (source: local phrases > model audio) -> mixer
```

Why it is built this way:
- **One engine:** voice processing heavily ducks any second output stream, even from the same app ([Apple engineer](https://developer.apple.com/forums/thread/829753)). A single engine should also put the metronome in the echo-cancel reference, which is my inference and M1 tests it.
- **Voice processing stays on:** it can only be toggled while the engine is stopped ([Apple headers mirror](https://docs.rs/objc2-avf-audio/latest/objc2_avf_audio/struct.AVAudioSinkNode.html)), so toggling it mid-rescue would interrupt the metronome.
- **Sink node instead of a tap:** a tap's buffer size is only a hint. One developer saw 4096 or more frames from a tap against 1024 from a sink ([anecdotal](https://developer.apple.com/forums/thread/688082)). M1 measures this.
- **Source node instead of a player node for model audio:** flush becomes one atomic index jump, effective within one IO buffer.

**`SpeechGate`, set by the protocol state:**
- `localOnly`: all arrest and bleeding states. Model audio is dropped before the ring.
- `modelAllowed`: non-critical states only, with transcript validators running.
- Runaway guard: stop any turn over 20 s of audio. A developer has reported replies running about 86 s after a 10 s sentence on 3.8 Live ([forum](https://discuss.ai.google.dev/t/gemini-3-8-live-1011-1008-session-drops-runaway-audio-and-output-transcription-with-unspoken-text/190881)).

**Ducking:** the metronome is ducked by about 6 dB under voice and never muted, except when the user taps "Dispatcher is talking". That mode also closes the gate and pauses the mic uplink.

**Failure cases:**
- On `interruptionNotification`, a media services reset or an engine config change, rebuild the graph and show a visual pulse with "count out loud" until audio returns.
- `CXCallObserver` can flag an active call, but event sequences have varied by iOS version ([CXCall](https://developer.apple.com/documentation/callkit/cxcall.md), [forum](https://developer.apple.com/forums/thread/766395)).
- Whether audio survives a same-phone cellular call is the largest unknown. M1 tests it against a non-emergency number. Two-phone mode is the design default.
- Without mic permission, run a playback-only graph with tap input. Never show a permission or AI consent prompt during an emergency. Collect both at onboarding, and treat cloud features as opt-in.

**Dynamic text** (reading the address aloud): `AVSpeechSynthesizer.write` into VoiceBus. It works offline and uses the same engine.

**Counting rejection:** VAD segments phase-locked to the beat for 3 or more beats count as counting and are not uplinked. This heuristic is untested, and M2 measures it.

## 7. Overlay pipeline

- **Session:** `ARWorldTrackingConfiguration` with horizontal planes, `.gravity` alignment, `sceneDepth` if supported, and `automaticallyConfigureSession = false`.
- **Rendering:** ARView with motion blur, depth of field and camera grain disabled.
- **Pose:** Apple Vision 2D or `yolo26n-pose`, chosen by the M4 bake-off, with a rotated crop and a horizontal-torso test for patient selection.
- **State machine:** use the brief's TRACKING, LOCKED and STALE states.
- **Lag compensation:** convert the target to a world point using the pose stored at capture time, via depth, or via plane plus body-height offset. ARKit then keeps it stable between inference results. Before tracking initializes, draw a 2D ring from the keypoints. Show a palm-sized region, never a dot.
- **Timing rule:** AR never gates anything. If pose is not acquired in about 2 s, voice proceeds.
- **Compressions:** no overlay for a lone rescuer.

**Frame upload policy** (at most 1 FPS):
| State | Rate |
|---|---|
| Scene and AED states | 1 per 5 to 10 s |
| Speech onset, a `locate`, a pose loss | 3 s burst at 1 FPS |
| Compressions | None by default |

## 8. Camera arbitration

`CameraArbiter` is an actor with a single owner, either `.ar` or `.ppg`. ARKit is the only frame source in emergency flows.

- Apple says a second capture session interrupts ARKit ([forum](https://developer.apple.com/forums/thread/847744)), and a finger on the lens removes the view anyway.
- PPG is compiled into a separate package and is cut from the MVP.
- `ppgLease()` succeeds only when `ProtocolEngine.state.allowsPPG` is true, which applies only to a confirmed awake and talking patient. It can never be reached from an arrest path.
- Lease sequence: `ARSession.pause()`, run an `AVCaptureSession` with torch and a target of 60 FPS, record 30 to 60 s, stop, then `run` without reset and reacquire keypoints. Assume anchors are lost. Switch time is unknown, and M8 measures it with a target under 2 s.
- Output goes one way into the event log and handoff card, labeled unverified. A failed quality check shows no number.

## 9. Data contract

Defined once in `contracts/tools.v1.json`, with Swift generated from it. Declare `behavior` on every function explicitly (see section 12).

**Model to app.** The model has no coordinates and no authority.

```
report_observation(kind: enum, source: heard|seen, confidence: low|med|high, epoch)
report_resources(items: [enum], epoch)
ask_user(question_id: enum, epoch)            // fixed yes/no only
say(phrase_id: enum, epoch)                   // allowed set for this state
answer_side_question(snippet_id: enum, epoch)
request_step(step_id: enum, reason: enum, epoch)  // engine checks guards
highlight(target: chest_center|aed_device|pad_upper_right|pad_lateral_left|limb_above_wound|resource:<id>, epoch)
locate(label: enum, epoch)                    // one-shot, async
request_metronome_on(epoch)                   // there is no off tool
log_note(text, epoch)                         // tagged AI-inferred
```

**Tool responses** use the [required format](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/migrate-from-gemini-2-5-to-gemini-3-8-live): matching `id`, plus

```
{status: ok|rejected|stale_state|not_allowed_in_state|no_tracking,
 retryable: false, state, epoch, allowed: [...], message, scheduling: "SILENT"}
```

**App to model:**
- `StateBrief` on each transition: epoch, state, allowed tools and phrases, last 3 phrases actually played, resources, elapsed time.
- Sent with `contextUpdate` where available, otherwise as ordered client content.
- "Actually played" matters because content already sent to the client stays in session history ([capabilities](https://aistudio.google.com/docs/live-api/capabilities)), so the model may believe it said something the gate dropped.
- JPEG frames via realtime input. No PPG.

**Gemini setup:**
- `responseModalities: ["AUDIO"]`
- `mediaResolution: LOW`
- `contextWindowCompression: {slidingWindow: {}}`
- `sessionResumption`
- `automaticActivityDetection` on, 500 ms silence
- `inputAudioTranscription` with `customVocabulary` for terms such as AED, naloxone and tourniquet
- `outputAudioTranscription`
- Ephemeral token: `v1beta`, `BidiGenerateContentConstrained`, long `expireTime`

**Sentinel invariants**, enforced in `RescueCore` and unit tested:
1. Only a human tap or an EMS-takeover event can exit CPR.
2. Only the engine can stop the metronome.
3. Model or sensor observations may raise urgency immediately. Lowering it requires human confirmation.
4. Model speech is never audible in `localOnly`.
5. A stale epoch is always rejected.
6. A Sentinel failure can never halt guidance.
7. Non-release builds cannot contain the real emergency number.

**Server events:**
| Event | Action |
|---|---|
| `interrupted` | Flush VoiceBus |
| `toolCallCancellation` | Cancel `locate` |
| `sessionResumptionUpdate` | Store handle |
| `goAway` | Reconnect when resumable |
| `usageMetadata` | Metrics |

**Failover trigger:** a 1011 or 1008 close, a failed resume, or first audio over 3 s twice. Rebuild context from `StateBrief`, never from transcripts.

## 10. Data flow

```
mic -> VP -> sink -> AudioUplink -> VAD gate -> LiveClient -> model
                        '-> keyword STT -> ProtocolEngine
model audio -> SpeechGate -> VoiceBus -> speaker
model toolCall -> ToolRouter -> Sentinel rules -> ProtocolEngine -> Effects
Effects -> phrase | metronome | overlay target | frame burst | EventLog
ARFrame -> Ledger + mailbox -> PoseWorker -> target -> anchor -> ARView
ARFrame -> FrameEncoder (policy) -> LiveClient
EventLog -> StateBrief | CallScript | HandoffCard | Auditor (async)
Auditor flag -> ProtocolEngine -> stop model voice + play correction phrase
```

## 11. Repo structure

Private repo `patriotsbreeze/HealthAI`. I checked read-only that `gh` has `patriotsbreeze` as the active account with `repo` scope, and that git uses its noreply email. The local folder is empty and not yet a git repo. I did not verify the link to blobrendan422@gmail.com.

```
README.md                  prototype and non-medical-device notice
docs/adr/, docs/test-protocols/, docs/clinical/
contracts/                 tools.v1.json, events.v1.json, phrases.v1.json
protocols/                 adult_arrest.v1.yaml, limb_bleed.v1.yaml, golden/
ios/HealthAI.xcodeproj, ios/App/
ios/Packages/RescueCore    ProtocolEngine, EventLog, SentinelRules, CallScript, HandoffCard
ios/Packages/RescueAudio   AudioGraph, Metronome, VoiceBus, SpeechGate, AudioUplink, ClientVAD
ios/Packages/RescueVision  ARController, FrameLedger, PoseWorker, TorsoTarget, CameraArbiter
ios/Packages/RescueLive    RealtimeTransport, GeminiLive, OpenAIRealtime, MockTransport, ToolRouter
ios/Packages/RescuePPG     optional, feature flagged
backend/                   Node 24, Hono: /token/gemini, /token/openai, /audit, /locate
evals/                     Python 3.14: latency reports, vision eval set, phrase checks
tools/                     phrase pre-rendering, contract codegen
.github/workflows/ci.yml   swift test, backend tests, emergency-number guard
```

**Named dependencies:**
- `URLSessionWebSocketTask` for Live, unless the Firebase Swift SDK passes its spike.
- [Silero VAD Core ML](https://huggingface.co/ark-tech/silero-vad-coreml) (MIT) behind a thin wrapper.
- `SpeechAnalyzer` for keywords, based on third-party sources only ([example](https://dev.to/simple_memo/ios-26-speechanalyzer-what-i-learned-wiring-it-to-a-mic-f7p)), so confidence is low. Offline behavior before the asset download is unverified.
- Fallback: `SFSpeechRecognizer` on-device, then taps.

## 12. Where I deviate from or doubt the brief

1. **OpenAI transport:** I use WebSocket PCM first, not WebRTC.
   - WebRTC normally owns the audio unit, so the metronome could become a ducked second stream.
   - A custom `RTCAudioDevice` exists, but I found only community examples ([Twilio sample](https://github.com/twilio/video-quickstart-ios/blob/master/AudioDeviceExample), [test repo](https://github.com/mstyura/RTCAudioDevice)).
   - Costs: OpenAI calls WebRTC usually sturdier for clients ([guide](https://developers.openai.com/api/docs/guides/voice-websockets)), I must send `conversation.item.truncate` myself ([guide](https://developers.openai.com/api/docs/guides/realtime-conversations)), and I assume no sideband.
   - Revisit if M2 cellular results are poor.
2. **Tool defaults conflict:** the brief says `NON_BLOCKING` is the default. The [AI Studio page](https://aistudio.google.com/docs/live-api/tools) says calls are synchronous by default, and the [Agent Platform guide](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-3-8-live) implies otherwise. Set it explicitly.
3. **Forcing a reply is unclear:** the [capabilities page](https://aistudio.google.com/docs/live-api/capabilities) supports `turn_complete` throughout a session, while the [migration guide](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/migrate-from-gemini-2-5-to-gemini-3-8-live) lists it only for history seeding. M2 tests it.
4. **`contextUpdate` on the Developer API is unconfirmed:** the migration guide documents it, but [Firebase](https://firebase.google.com/docs/ai-logic/live-api/sessions) limits mid-session instruction updates to Agent Platform. The design survives without it, because the engine rejects by state anyway.
5. **"Pre-speech screening is not possible" is only partly true:** the server cannot do it, but the client gate can block speech entirely. A look-ahead buffer depends on transcript timing, which is undocumented, and transcripts have reportedly contained unspoken words. So transcript validators are a backstop only.
6. **PPG conflict inside the brief:** one topic suggests low-rate summaries to the model, and another says one-way to the report. I take the stricter rule. This overrides the original idea of PPG data informing the model's decisions, for the safety reasons the brief gives.
7. **Model tools narrowed:** `advance_step` and `start_metronome` become request-only, and no off tool exists.
8. **Possible ephemeral token issue:** one forum report says the system instruction was ignored with a token ([forum](https://discuss.ai.google.dev/t/live-api-with-ephemeral-token-ignores-the-system-instruction/113346)). M2 checks it. It may be stale.

## 13. Milestones

Durations are my rough estimates for one developer.

**M0, repo and device (0.5 day)**
- Confirm the login with `gh api user --jq .login`, then `git init`, first commit, and `gh repo create patriotsbreeze/HealthAI --private --source=. --remote=origin`.
- Scaffold packages and CI. Add a mock dispatcher number through build config.
- Check the test iPhone. Xcode knows an iPhone 15 Pro Max (LiDAR), which was unavailable when checked.
- Check its OS. Apple DTS says Xcode does not support platforms released after it ([forum](https://developer.apple.com/forums/thread/836048)). Xcode 27 may need macOS 26.6 ([blog, low confidence](https://blakecrosley.com/blog/xcode-27-release)), and this Mac runs 26.5.1. A non-LiDAR phone is also needed.
- Verify: `gh repo view --json visibility,owner` shows PRIVATE under patriotsbreeze; CI fails if a test adds the real number outside release config; the app runs on the device.

**M1, deterministic floor (2 days)**
- AudioGraph, Metronome, VoiceBus, ProtocolEngine for adult arrest, phrases, tap flow, 911 button, event log.
- Verify:
  - Run the full flow in airplane mode.
  - Record 5 minutes on a second phone. Onset analysis shows 110 ± 0.5/min, including across phrases, AR start and an induced engine rebuild.
  - Tap-to-audio under 100 ms, measured from slow-motion video and audio.
  - Golden transcripts pass with `swift test`.
  - Same-phone call test on a non-emergency number, with results recorded.

**M2, provider spike (2 days)**
- A harness over `RealtimeTransport` on Wi-Fi and cellular, at least 30 turns per provider. Measures:
  - End of speech to first audio with frames flowing, and to `toolCall`.
  - `audioStreamEnd` compared with server VAD.
  - Reconnect during a live session.
  - Whether `contextUpdate` works and how fast.
  - Tool-only behavior, and cost from usage fields.
  - False barge-ins with speakerphone metronome and counting aloud, including a `NO_INTERRUPTION` variant.
  - Panicked speech against proactive audio.
  - Whether a small photo and video set is read correctly.
- OpenAI advantage to test: `output_modalities: ["text"]` with manual `response.create` gives true tool or text turns. If Gemini tool latency is poor, this can flip the primary pick.
- Verify: an ADR with a p50/p95 table names primary and fallback.

**M3, live integration (3 days)**
- ToolRouter, SpeechGate, epochs, StateBrief, frame policy, resumption, watchdog, failover, token backend.
- Verify:
  - `MockTransport` replay of fixtures, including wrong-state, stale and banned calls, shows 100% rejection.
  - Killing the socket mid-compression causes no metronome deviation.
  - The gate blocks all model audio in `localOnly`, checked by a counter and by recording.
  - Reconnect meets under 2 s on device.

**M4, overlay (1 day bake-off + 3 days)**
- Compare on real lying adults, using the views in the brief. Compressions are on a manikin only, never on a volunteer. Whether any model detects a torso manikin is untested.
- Verify: the brief's proposed bar of acquire within 2 s and 90% of frames within about 4.5 cm of a human-labeled point; keypoint age from signposts; 240 FPS video for visual lag; automatic fall to voice when tracking degrades. A clinician must confirm the target location, because the lower-half versus lower-third wording is unresolved.

**M5, Sentinel, script, card (2 days)**
- Auditor endpoint, correction phrases, CallScript, HandoffCard with QR and source tags.
- Verify: adversarial transcript suite; auditor p95 under 3 s and timeouts have no effect; card fields trace to event log IDs; a mock dispatcher call using the script.

**M6, AED, resources, bleeding (3 days)**
- `report_resources`, `locate` with ledger raycast, AED detector, limb bleeding protocol, without the Stop the Bleed brand.
- Verify: labeled eval set for AED and tool recognition; late `locate` results land correctly or are dropped.

**M7, end-to-end study and soak (2 days)**
- Manikin comparison against dispatcher-only guidance. Time to first compression is the go/no-go metric, because AHA 2025 advises against cognitive aids for lay rescuers due to CPR delays.
- 15-minute soak with AR, inference, socket and speaker on.
- Verify: time to first compression is no worse than dispatcher-only; no audio dropouts; thermal shedding works in the planned order.

**M8, optional PPG bonus (2 days)**
- Awake volunteer only.
- Verify: unreachable from arrest states by test; a failed quality check shows no number; AR resumes after the lease.

**Hackathon cut (about 1 week):** M0, M1, a half-day M2, M3, the M4 overlay on a volunteer, and the M5 card. Demos never dial 911.

## 14. Decisions needed

- **Hackathon or product, iOS only or cross-platform:** this plan is iOS first and fits both.
- **Public launch gate:** Gemini terms bar providing medical advice and under-18 audiences ([terms](https://aistudio.google.com/docs/terms)), OpenAI also needs review, and camera-based compression feedback falls under a Class II device rule ([21 CFR 870.5210](https://www.law.cornell.edu/cfr/text/21/870.5210)). Rate feedback therefore stays behind a flag and off by default. Counsel and a medical director are required before any real-world use.
- **Clinician:** someone must sign off the protocol files and phrase library.

### Critical Files for Implementation
These files do not exist yet, since the repo is empty.
- /Users/brendanlo/Documents/GitHub/HealthAI/contracts/tools.v1.json
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/RescueCore/Sources/RescueCore/ProtocolEngine.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/RescueAudio/Sources/RescueAudio/AudioGraph.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/RescueLive/Sources/RescueLive/GeminiLiveTransport.swift
- /Users/brendanlo/Documents/GitHub/HealthAI/ios/Packages/RescueVision/Sources/RescueVision/PoseWorker.swift
