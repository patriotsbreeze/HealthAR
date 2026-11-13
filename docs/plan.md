# HealthAI: phone AI + AR emergency guide

## Context

The folder is empty. The goal is a phone app that guides a bystander through a medical emergency using the camera, voice, and AR, and hands a report to EMS.

Your decisions:
- **Goal:** real product, demo first. The first build is a private simulation, but its boundaries are the ones the product keeps.
- **Timeline:** under 1 week.
- **Audience:** private or judges only, no public posts or videos.
- **911:** a human dials. On stage, an AI voice talks to a mock dispatcher.
- **AI voice:** speaks outside compressions, checked afterward.
- **PPG:** bonus for an awake patient only.
- **Compression-rate feedback:** labeled stretch.

Durations and thresholds are estimates, not measurements. Facts come from current vendor docs and guidelines. AHA text was read through a mirror, so a clinician must confirm clinical wording.

## What research changed

| Your idea | Finding | Plan |
|---|---|---|
| Cloud vision model points at body parts | Gemini Live takes at most 1 FPS and replies are 1-2 s stale | On-device pose and ARKit place overlays. The model never supplies coordinates |
| AR guides compressions | Both hands are busy and arms cover the chest | Ring appears before compressions only. Audio carries compressions |
| Voice agent guides the rescue | LLM omissions dominate published failures, and spoken audio can't be retracted | Engine plays every required step as a local phrase. AI voice adds to that outside compressions, per your choice |
| Sentinel prevents hallucinations | Nothing can prevent them with native speech models | Sentinel contains them in layers, below. Pitch it as "constrains" |
| AI calls 911 | iOS has no public path, and Twilio routes by registered address, not patient location | Human dials, AI keeps a live script. AI voice addresses a mock dispatcher only |
| SOS signal | No public Emergency SOS API | Onboarding teaches side-button SOS. Text-to-911 and RapidSOS move to the product phase |
| PPG informs the AI's decisions | No validation in arrest, a false pulse could stop CPR, and a finger blocks AR | Separate awake-patient screen. Output goes to the EMS card only |
| CPR beat song | Needs rights-holder permission (App Store 4.5.2(ii), plus stage and video rights) | Local 110/min double-click metronome. An original track can come later |
| Realtime feedback | Rate is measurable on-device, depth is not trustworthy | Rate-only stretch. No depth score |
| EMS report | NEMSIS is an agency record, not a bystander format | One-screen handoff card from the event log |
| Fine-tuned medical models | Realtime models can't be tuned, and MedGemma targets radiology-type images | Skip. Spend the effort on protocol content and an eval set |

**Largest product risk:** AHA 2025 rates cognitive aids for lay rescuers COR 3: No Benefit, with mobile apps and voice prompts among its examples, because they delayed calling and compressions by 30-70 s. Time to first compression is the product's go/no-go metric.

**Limit to state plainly:** the AR and AI story needs a second person or second phone. A lone rescuer on one phone gets at most the dispatcher plus a local metronome. The demo script uses a helper for this reason.

**Accepted risk, from your AI voice choice:** a wrong line such as "he sounds fine" can be heard during the breathing check before validators catch it. The engine still ignores it, and the default stays CPR. This is acceptable for a simulation only. Product gate 1 reverses or justifies it. Once a person taps that the patient is responding, the AI also talks freely, from approved text, and can say something that text doesn't support before anything catches it. `SAFETY.md` keeps the full list.

## Architecture

Core rule: **the model reports, the engine decides.**

```
ARSession frames ─┬─ PoseWorker → TorsoMap → overlay               (on-device)
                  ├─ FrameUplink (1 per 5-10 s, bursts, none during pads) → LiveClient
                  └─ FrameLedger (frame id → camera pose)
Mic → voice processing → client VAD → 16 kHz PCM → LiveClient
LiveClient tool calls → SafetyGate → ProtocolEngine → phrase, metronome, overlay target, EventLog
LiveClient audio → SpeechGate → speaker (open states only; local phrase always wins)
LiveClient transcript → validators + async auditor → correction phrase
EventLog → CallerScript, HandoffCard, StateBrief (phrases actually played → model)
```

| Loop | Runs on | Target |
|---|---|---|
| Metronome | Phone audio thread | 110/min, no drift, no dependencies |
| Protocol prompt | Phone | Tap to audio under 100 ms |
| AR ring | Phone | Shown only if torso is already in view, at most 3 s, else voice proceeds |
| Voice understanding and AI voice | `gemini-3.8-live` | Speech end to tool call about 2 s, measured in M3 |
| AED locate | `gemini-3.8-flash` on a frozen frame | 3-8 s, fine for a static object |
| Auditor | `gemini-3.5-flash-lite` | Async, never gates |

### Your agents, mapped

One live session at a time plus deterministic services, with no orchestrator, since each hop adds latency and gives up control. The app can still show them as named lanes. The session is swapped on crossing between the arrest path and the awake states, so each has its own prompt and contract, and the arrest session's never change.

- **Voice agent:** `LiveClient`, with tools `report_finding`, `report_resources`, `say(phrase_id)`, `locate_object(label)`, `log_event`. All arguments are enums and carry a state version, and stale calls are rejected. It also speaks in open states.
- **Not exposed to the model:** overlay coordinates, step changes, stopping the metronome, dialing.
- **`SpeechGate` table:** open in intake, placing hands, resource scan, handoff, and the open awake states. Closed in compressions, pads, AED analysis, and any dispatcher call. It lives in one table so the product can close it with one change. A 20 s runaway guard stops long turns.
- **Sentinel, in layers:**
  1. Engine invariants
  2. `SafetyGate` and `SpeechGate`
  3. Transcript validators for pulse checks, stopping CPR, doses, death statements, and reassurance such as "he's fine" (after the fact, and transcripts may include unspoken words)
  4. Async auditor that can flag and trigger an approved correction phrase. Cut if it adds nothing beyond the validators
- **911 agent:** `CallerScript` plus Read Aloud. See M6.
- **EMS report:** `HandoffCard`, built from the event log and never from transcripts. Items are tagged timer, sensor, bystander, or AI-inferred.

### Invariants, enforced by tests

`SAFETY.md` has the full wording. The arrest path is every intake, watch, setup, and CPR state. The awake states are triage and the flows, reached only by a person's tap that the patient is responding.

1. Only a human action leaves CPR.
2. Only the engine stops the metronome. Once pads are on, it is off by default and the AED is the authority. A local keyword can pause audio, never exit a state.
3. Model, sensor, and timer events can raise urgency or keep it level. Lowering it requires a human. On the arrest path they also can't leave for a card or an awake state.
4. Every required step, on the arrest path and in each awake flow, comes from a local phrase and never depends on the model.
5. **On the arrest path, "Yes, breathing" never ends the flow.** Agonal gasps occur in up to 40-60% of arrests. It enters a watch state: 911 stays prompted, the bystander marks breaths for 10 s, the app re-asks, and no reply goes to CPR. Needs clinician approval.
6. On the arrest path, uncertainty, or no reply in 10 s, goes to CPR. In the awake states no reply takes the safer branch, never CPR. There is no pulse check on any path.
7. Cloud or Sentinel failure never halts guidance.
8. AR never gates anything.
9. Demo builds cannot contain a real emergency number. Dialing goes through an allowlist.
10. PPG is unreachable from the arrest path and the awake states, and feeds only the card.
11. No frame uplink during pads. No mic uplink while a dispatcher may be audible.
12. Unresponsive always follows the CPR path. A collapse tapped or reported in any awake state goes to the breathing question or compressions, by edges no scenario file can remove.
13. The AI chooses among awake flows only after a person's tap, and only upward in urgency. It can never choose triage or the aspirin dose.
14. A bad scenario file can't affect arrest. It is dropped whole and named, and with no approved knowledge pack the AI voice stays closed in every awake state.
15. The app never states a condition as fact, gives no dose beyond the one approved aspirin phrase, and never claims to be a clinician.

Authority order at runtime: dispatcher, AED, protocol, model.

### Audio has two modes

Apple documents that activating `playAndRecord` fails with `AVAudioSessionErrorInsufficientPriority` while another app hosts a call, that `playback` is allowed, and that an app can't capture the call's mic. So:

- **No call active:** `playAndRecord` with voice processing, in one `AVAudioEngine` mixing metronome, local phrases, and model audio. Client VAD keeps ticks off the uplink.
- **Any call active, including at launch:** `playback` with metronome and local phrases only, with no mic, model, or AI voice. Tell the user to tap Speaker before dialing.

Two-phone use is the design default. Whether `playback` is audible and the app survives a real cellular call is unverified, so M1 tests it against a teammate's phone.

## Clinical scope

Adult cardiac arrest with hands-only CPR plus AED. For a patient a person has tapped as responding: a triage step, then a possible heart attack flow or a possible broken bone flow, whose danger step covers heavy limb bleeding. Each says "possible" and "Not a diagnosis".

The arrest flow includes the steps drafts tended to omit: an adult gate (child, infant, drowning, and pregnancy get a static card and "follow the dispatcher"), roll onto back on a firm surface, second person calls while first compresses, switch compressors about every 2 minutes, and "push hard" every 60 s. Anything else after triage gets the call prompt, the dispatcher, and the AI to talk it through, and choking gets a step of its own. A patient who woke after CPR, or with pads on, gets 911 plus a static card.

Every phrase in `clinical/` carries wording, citation, and reviewer, and stays marked DRAFT until reviewed.

## Stack

- Native Swift 6.3, SwiftUI, RealityKit `ARView`, `ARWorldTrackingConfiguration`, iOS 26 target. iPhone first; Android later behind the same core.
- Pose: Vision `DetectHumanBodyPoseRequest`. Ruled out: ARKit body tracking (no evidence on people lying down), BlazePose (model card excludes life-critical use), WebXR (not on iPhone). Fallback `yolo26n-pose`: check the Ultralytics license before product use.
- Live: `URLSessionWebSocketTask` to `gemini-3.8-live`, behind a `RealtimeTransport` protocol so OpenAI `gpt-realtime-2.1` can be added later. Avoid Gemini preview models, whose earliest shutdown is 2026-11-17.
- Phrases: macOS `say` for private rehearsal only. Older macOS licenses restrict public or commercial use, so replace them before anything public.

## Repo layout

`patriotsbreeze/HealthAI`, private. The name is free and `gh` is logged in as `patriotsbreeze`. The token can't read account email, but the Apple Development certificate on this Mac uses blobrendan422@gmail.com.

```
README.md            SIMULATION, NOT FOR REAL EMERGENCIES
SAFETY.md            invariants, limits, product gates
project.yml          XcodeGen; .xcodeproj gitignored
Config/              Demo.xcconfig, Secrets.example.xcconfig (Secrets.xcconfig gitignored)
clinical/            adult_arrest.v1.json, phrases.v1.json, modules/, knowledge_pack.v1.json
contracts/           tools.v1.json (arrest session), tools.awake.v1.json (awake session)
Packages/
  RescueCore/        ProtocolEngine, SafetyGate, EventLog, CallerScript, HandoffBuilder, Validators
  RescueAudio/       AudioGraph, Metronome, VoiceBus, SpeechGate, ClientVAD
  RescueVision/      ARController, FrameLedger, PoseWorker, TorsoMap, AEDLocator, CameraArbiter, RateEstimator
  RescueLive/        RealtimeTransport, GeminiLive, MockTransport, ToolRouter, Auditor
  RescuePPG/         stretch only
App/                 SwiftUI screens, SentinelPanel, OperatorPanel, LatencyHUD
tools/               render_phrases.py, check_no_emergency_number.sh
evals/               labelled AED and scene photos, utterance set
docs/                demo_script.md, research_brief.md, adr/
```

`RescueCore` imports no network or media code, so the product can ship with AI removed.

## Milestones

| # | When | Build | Verified by |
|---|---|---|---|
| M0 | Day 1 am | `git init`, `.gitignore` with secrets excluded, research brief committed, `gh repo create patriotsbreeze/HealthAI --private --source=. --remote=origin`. XcodeGen scaffold with separate demo name, icon, and banner | `gh repo view --json visibility,owner` shows PRIVATE under patriotsbreeze. Hello-world runs on the iPhone |
| M1 | Day 1 | Engine with watch state, clinical bundle, phrases, metronome, event log, dual-mode audio, tap-only flow. Same-phone call spike against a teammate's phone | `swift test` covers all transitions and invariants. Full run in airplane mode. Recording shows 545 ms ±5 between clicks. Unlocked phone to metronome within 15 s. Call results written to an ADR |
| M2 | Day 1-2 | AR ring on a lying volunteer | CPR-trained person places tape. Ring covers it in at least 27 of 30 frames. Acquire within 2 s. This is a demo bar. A clinician must set the real one, which is asymmetric. Fallbacks: `yolo26n-pose`, then a disclosed tap-to-place |
| M3 | Day 2 | Live session, tools, frames, compression and resumption, `StateBrief` | At least 18 of 20 scripted utterances give the right tool call. Median about 2.5 s or less. 5-min soak passes the 2-min limit and a `goAway` resume. Metronome and counting aloud don't stall it. Proactive audio can stay silent, so timeouts must fire. **Go/no-go:** if it fails, use on-device speech plus stateless vision calls |
| M4 | Day 3 am | SpeechGate, validators, auditor, SentinelPanel | Fuzzed tool calls cause 0 illegal transitions. Seeded bad line flagged within 3 s and corrected. Killing the auditor changes nothing. No model audio in closed states |
| M5 | Day 3 | Resource scan, second-person role assignment, AED arrow, AED steps, coarse pad zones | AED box IoU ≥ 0.5 in at least 16 of 20 photos. Arrow holds after a 2 m walk away and back. Metronome off once pads are on, checked against the AED trainer's prompts. No uplink during pads |
| M6 | Day 4 am | Caller script, mock dispatcher, handoff card, latency HUD | No `tel:911` in the Demo binary (`strings`). Button reads CALL MOCK DISPATCHER. Address shows "Approximate, confirm" with accuracy radius. Read Aloud never speaks an unconfirmed address. Card matches the log, shows "not recorded" rather than zero, and says "coaching started" rather than "CPR started". Readout within 30 s |
| M7 | Day 4-5 | Rehearse, freeze | 15-min full-stack soak, with load shed in this order: fewer frames, slower inference, AR off, never audio. 10 runs on the venue network, at least 9 without OperatorPanel, first compression within 30 s of collapse with the phone starting locked. Backup video. Tag `demo-v1` |
| M8 | After M6 | Triage after a Yes tap, possible heart attack and possible broken bone modules, knowledge pack, awake Live session, AED arrow carried into compressions, injury pin | `swift test` and the app suite cover the merge, the flows by taps and timeouts, and the invariants. Device checks M8 in `docs/device_checks.md` |

**Mock dispatcher (M6):** a teammate's phone acts as dispatcher. Tapping Read Aloud has an on-device voice state that it is an AI assistant, then read the live script. This is one-way, not a conversation. It needs no telephony backend, keeps the demo phone out of a call, and is the same Read Aloud the product keeps. A real outbound call to an allowlisted mock number via Twilio is an extra stretch and needs your account.

**Stretch, only after M6 passes:**
- **S1, rate feedback:** `RateEstimator` from wrist keypoints, helper-held or propped at about 1 m, on a manikin. Local "faster" or "slower" phrases when rate stays outside 100-120. Labeled EXPERIMENTAL, off by default in product builds, no depth, silent on low confidence, never reassuring. Check within ±5/min at paced 90, 110, and 130.
- **S2, PPG:** separate awake-patient screen. Pause ARSession, run torch capture for 30-60 s, resume. Heart rate only, no number on a failed quality check, nothing sent to the model.

**Cut order if behind:** S1, S2, pad zones, AED arrow (voice instead), auditor (keep validators). **Never cut:** offline protocol, ring, metronome, Live intake, handoff card.

### Demo scenario (3 min, plus 45 s)

Two runs, scripted in `docs/demo_script.md`. In the first, a patient clutching their chest is tapped as responding, the AI asks what's going on and routes to a possible heart attack, and the helper's room scan locks an arrow on the AED before anyone needs it. The patient then slumps, the app asks about breathing, and CPR starts with the arrow already there. The two seeded Sentinel beats follow: a bad AI line during hand placement is caught and corrected aloud, and a model "breathing, stop CPR" report during compressions is shown rejected on the panel. The metronome yields to the AED trainer, airplane mode shows guidance continuing, and the paramedic gets the handoff card. The second run is an injured arm, with a pin tapped onto the injury and the support card.

Nobody compresses a real person, nobody takes real aspirin or is splinted, and no build used on stage can dial 911.

## Safety and security this week

- Only the Demo target ships this week, with its own name and icon and a permanent "SIMULATION, will not call 911" banner. A demo build dials a teammate, so it goes to internal TestFlight testers only, with no external group or public link, and comes off any daily phone afterward.
- The API key stays in a gitignored xcconfig, is restricted, is never logged, and is rotated after the demo.
- Use the paid Gemini tier only. Free-tier content may be read by reviewers, and a person is on camera.
- Volunteers are consenting adults, with written consent covering video sent to Google. Pad zones are manikin only. A CPR instructor reads the phrase list.
- Judges still see a Gemini-based medical demo. Gemini terms bar medical advice and uses needing device clearance, and I found no demo carve-out. I rate this low risk but could not verify that private demos fall outside these rules. Make no clinical claims in the pitch, since statements can count as evidence of intended use. This is not legal advice.

## Product gates, after the demo

First step: a no-AI time-to-first-compression pilot, before more AI work. Use a mock dispatcher with realistic answer and address delays, since an instant one hides the app's only plausible advantage. AHA's benchmark is under 150 s to the first directed compression.

All of these before real use:
1. AI voice closed on arrest-capable paths, unless evidence shows open speech is safe.
2. Named medical director signs a hash of `clinical/`, having read AHA Parts 6, 7, 10, 12.
3. Pre-registered manikin study shows time to call and time to first compression are non-inferior to dispatcher-only. About 130 per arm, recalculated from the pilot.
4. FDA counsel plus a 513(g) or Q-Submission. The Class I CPR aid path is doubtful because the regulation text says professionally trained users. Rate feedback is Class II.
5. Written answer from Google covering both Gemini terms limbs and the under-18 bar, plus OpenAI review, or ship with no cloud model, which this design allows.
6. Same-phone 911 behavior known from device testing and Apple DTS, never by test-calling a PSAP unarranged.
7. Privacy: Apple 5.1.2(i) AI consent, Washington My Health My Data, FTC breach rules, no face or voice biometrics, Apple's answer on 5.1.5 location use.
8. Legal entity, insurance, and 911-telecom counsel.
9. Release order: no-AI build, then cloud hints, then overlay, each with evidence of no added delay. Add token backend with App Attest, OpenAI fallback, and text-to-911.

## Needed from you

- iPhone 15 Pro Max "ninja" (iOS 26.6.2) connected and unlocked. It shows as unavailable now, though device support is installed.
- Paid Gemini API key.
- CPR manikin, AED trainer, adult volunteer, helper, teammate phone, and a CPR-trained reviewer.
- A non-LiDAR iPhone if you can get one, since not all target phones have depth.

Estimated API cost: about $1.50 per 10-minute session, $40 for rehearsals.

## Verification

- `swift test` for engine, invariants, bundle checks, and validators, with no device needed.
- `tools/check_no_emergency_number.sh` as a build phase, plus `strings` on the Demo binary.
- `gh repo view patriotsbreeze/HealthAI --json visibility,owner` after M0.
- Device checks per the milestone table, then the full demo script with airplane-mode and network-loss variants.

**The demo will not prove:** sternum accuracy across bodies and clothing, clinical validity, non-inferiority to a dispatcher, safety of open AI speech, or coexistence with a real 911 call.
