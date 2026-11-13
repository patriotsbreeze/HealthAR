# Plumb

A CPR training simulator for iPhone. A propped iPhone with LiDAR measures compressions on a cushion
torso, keeps a fixed beat, coaches with five fixed cues, and hands over a record built only from the
session log.

**Training simulation. Not a medical device. Nobody compresses a real person.**

## What it does

Prop the phone about a metre from the torso and push. The phone finds the hands, counts each push,
measures its depth against a 5 cm line and plays a beat at 110 a minute. Fixed rules pick at most one
cue at a time. Measuring, coaching and the record use no network and no key. The model helpers are
optional, and none of them can change a number or a cue.

Three moments for a judge:
1. **Push, and the phone is right.** Each push draws a bar against the 5 cm line, the rate shows as one
   large number, and the beat turns from a thin tick to a full tock once a trusted push reaches 5 cm.
2. **Kill something, and it stays honest.** Turn the network off: counting, the beat, the cues and the
   record carry on, and "Hold to ask" is answered on the phone. Spoil the depth reading of the hands:
   new bars are drawn as outlines or ticks, never judged, the screen says "Estimating depth", "Rhythm
   only" or "Looking for hands", and no depth cue is given.
3. **Their own record at hand-over.** Three seconds after the last push, "Hand over" replaces "Hold to
   ask". Hold it for the start time, length, pauses, rate, depth range, share of trusted pushes reaching
   5 cm, share of time with hands on the chest, and a "Not recorded" line. "Read aloud" reads it out.

## How it measures

**The hands, not the wrist joints.** A box 14 cm wide and 24 cm tall is fixed in the world where the
hands are. Each frame the height is the nearest surface in that box along the line of sight through its
centre. No joint is measured: the arms pivot as they push, so wrist and shoulder joints travel further
than the chest does and would overstate depth. The box is
placed by a tap on the hands, or from Vision's body pose: both wrists read by LiDAR within 2 m, within
15 cm of each other and below the shoulders. After 2 s without a valid reading the hands are sought again.

**A still reference.** An 8 cm patch 25 cm to one side of the hands, level with them; both sides are
watched for half a second and the steadier one kept. Its slow drift is taken off the hands' height, at
most 5 mm a second. Its jitter is the noise floor, shown on show working as "Still point moves ±x mm".

**LiDAR for true scale.** Capture uses ARKit's raw scene depth, never the smoothed depth, whose blending
of frames would flatten strokes. ARKit calls back on a private serial queue, and nothing of an ARFrame
is kept. There are two height methods (`Packages/Geometry`), and neither works without the range:
- **Along the line of sight** (what the app runs): the LiDAR range through the box centre places the
  hands in the world, and the height is that point's world height.
- **Picture slide** (`imagePlane`): how far the brightness pattern over the hands slid along world-up,
  turned into millimetres with the LiDAR range as the ruler.

**Lock states.** Each sample's quality (0 to 1) comes from how much of the box the hands fill and how
flat their depth reads, capped at 0.3 while ARKit tracking is not normal. Trust rises after about a
second of good quality and falls after 0.3 s of poor quality. Time without a signal never counts as a pause.

| State | When | On screen | In speech |
| --- | --- | --- | --- |
| Locked | Quality 0.6 or more | Solid bars: off-white when they reach 5 cm, accent when short. Solid line in the room. | All five cues. Answers may give depth. The beat can turn to the tock. |
| Estimating | 0.3 or more | Outline bars, never judged. "Estimating depth". Dashed line. | Push now, Faster, Slower. Answers say depth is still being estimated. |
| Rate only | Below 0.3 | Ticks of one length. "Rhythm only". No line. | Push now, Faster, Slower. Answers give the rate only. |
| Lost | No sample for 0.5 s | Ticks. "Looking for hands". No line. "Good" taken down. | No cue. Push now waits until the signal has been back 1 s. Answers say the hands cannot be seen. |

**What it does not coach: leaning, incomplete recoil, too deep.** Depth is the top of each stroke minus
its deepest point, so the phone knows how far the hands travel, not how hard they press or where the
chest would rest without them. None of the three can be measured well enough to coach.

## Coaching

**The beat** is fixed at 110 a minute, starts by itself after launch and never follows the person
pushing. It is a thin high tick until a locked push reaches 5 cm, then a fuller, lower tock until a
push falls short or is not trusted.

**Five fixed cues** (`Cue` in `Packages/Contracts`, rules in `Packages/Coach`). No model chooses a cue.

| Said | Shown | When the rules allow it |
| --- | --- | --- |
| Push now | PUSH NOW | Pushing started, then stopped for 3 s, with the signal steady. Repeats every 5 s while the pause lasts. |
| Push harder | PUSH HARDER | Locked typical depth more than 3 mm under 5 cm for 2.5 s. Clears at 3 mm over. |
| Faster | FASTER | Rate more than 3 under 100 a minute for 2.5 s, after 6 pushes since the start or a pause. |
| Slower | SLOWER | Rate more than 3 over 120 a minute for 2.5 s, after the same 6 pushes. |
| Good compressions | GOOD | Depth and rate both judged on target: 4 pushes after a shown correction, or every 30 s of unbroken good work. |

Typical depth is the median of the last 5 trusted pushes; the rate is the median of the last 6
intervals. A pause outranks depth, and depth outranks rate. The voice backs up the screen sparingly: 6 s
of quiet after anything said, then 12 s and 4 new pushes before the same correction again. "Push now"
skips the quiet and cuts in. Nothing is said until pushing starts. The accent colour only means "fix
this now", and AED green is used for the AED alone.

## The harness

**Models propose, sensors falsify, a fixed policy speaks.**

The rescue loop has no model in it. `CompressionAnalyzer` turns height samples into pushes and
`CuePolicy` picks the cue; both take time stamps as their only clock, so the same samples always give
the same pushes and cues. Every measurement, cue, tool call, refusal and finding goes into one
append-only session log. The record, and the show-working screen that puts measured, suggested and
decided on one time axis, are built from that log. Model tool calls go through the `Conductor`, plain
scheduling code: it looks a tool up by name, checks the arguments, enforces a deadline, runs at most two
calls at once, refuses extras, and logs each call with its duration and outcome. The helpers run only
when a Gemini key is built in, except offline asking, which needs none.

| Helper | What the model does | What checks it | What it cannot touch |
| --- | --- | --- | --- |
| Scribe | Writes up to three sentences of at most 30 words about the finished session, each citing log entry ids. | `ScribeVerifier`, fixed code: real cited entries, every number backed by them or the handoff numbers, one short sentence, nothing on condition, outcome, cause, signs of life, medicines, accuracy or blame. Refused sentences get one retry. The handoff shows at most two that passed. | The numbers, the headline, the bars. The record is complete without it. |
| Voice (Gemini Live) | Answers a held question aloud. | One read-only tool, `get_cpr_quality`, with no arguments: the latest numbers with their age, depth only while locked, rate only with a signal, neither while stale. The prompt allows only reading them out. | The beat, the cues, the measurements, any app state. Its audio plays under the cues, and a cue cuts it off. |
| AED finder | Points at up to three spots in a still with people filled in. | `SceneJudge` tests each with LiDAR: 0.3 to 5 m away, standing out at least 4 cm and 3 times the sensor noise from the surface behind, sides 15 to 60 cm, wholly in view. A flat sign or a picture on a screen fails. One zoomed second look on the best rejected guess. | The coaching. Only an accepted point gets a marker. |
| Offline asking | Used for "Hold to ask" unless there is a key, a network path and an open voice connection. Speech becomes text on the phone. Apple's on-device model, through guided generation, picks one intent: overall, rate, depth, pauses, count or unknown. Keyword rules stand in when it is missing, fails or takes over 1.5 s. | A fixed template in `OfflineAnswerer` fills the answer from the latest numbers, under the voice's trust rules. A question naming the person or their condition is never answered from the numbers. | The words said. |

**Chest movement can only push toward CPR.** Before any push, "Check chest" opens a no-contact check: tap
the chest on the picture and the phone watches that patch's height against the still reference. A rise
or fall within 8 s of at least 2 mm, or 3 times the noise floor if larger, is movement. After 10 s with
none, the screen says "Start pushing" and "Push now" is spoken once. Nothing the sensor sees then takes it
back; only a person resets it, by opening the check again. The words describe the chest, never the person
("Chest movement seen", "No chest movement seen for 12 s"). "Start pushing" begins a fresh rescue whose
record opens with what the check last saw.

## AR guides

RealityKit draws the guides in ARKit's world, at true size and unlit.
- **Ring** (off-white, rescue screen only, like the line): 8 cm across at the box centre, flat on the
  chest surface fitted to the LiDAR depths within 6 cm; level when that fit is too sparse, too rough or
  leans more than about 35 degrees.
- **Target line**: a 25 cm bar where the picture shows the top of the hands once it has sunk 5 cm below
  the top of recent strokes. Only while pushing: solid when locked, dashed when estimating, absent
  otherwise. Drawn 4 cm toward the camera, so it sits in front of the hands, not inside them.
- **People occlusion**: arms pass in front of the ring, the line and the marker, where the phone supports
  person segmentation with depth alongside scene depth.
- **AED marker and edge pointer**: a green stem 45 cm tall with a 10 cm disc on the accepted point. Out
  of the picture, a green chevron at the edge points the way with the distance, such as "AED 4.2 m".

The walk-around: after Find AED, pick the phone up and turn or walk. The marker keeps its place in the
room and the chevron leads back to it. Measuring needs the phone propped, so this shows the guides, not
pushing. None of it has been tried on a phone yet.

## Privacy

Without a key, nothing about a session leaves the phone. With a key and a network, only this:

| When | What is sent to Gemini |
| --- | --- |
| Find AED is pressed | Up to two JPEGs, at most 1024 px on the long side, cut from one still in which every person Vision finds and every face box, with a margin, is filled with flat dark colour, not blurred. If people cannot be hidden, nothing is sent and show working shows the refusal. |
| Hold to ask is held and the voice is connected | Microphone audio while the button is held, and the numbers the voice's tool returns. Audio outside a held press is dropped on the phone. |
| Hand over | The headline (start time and length), the handoff numbers, and a compact list of the log's pushes, pauses, lock changes and cues. Notes, transcripts and tool text are left out. |

With a key, the voice connection opens at the start of each rescue with the instructions and tool
description, no audio. The key is built into the app's Info.plist, so a build with a key holds it.
Stored: nothing about a session is written to disk. The session log (measurements, cues, what the helpers
did, the words of any question asked) lives in memory until "New rescue" or the app quits. The one
exception: "Record measurements" on show working writes `plumb-trace-*.jsonl` to the app's Documents
folder, holding per frame the lens values, pose, hands' pixel, small LiDAR depth patches over the hands
and the still reference, and a 32 by 96 brightness grid over the hands box. No video and no faces.

## Evidence

Nothing has been measured yet, and nothing has run on the real phone.

| Measurement | How | Result |
| --- | --- | --- |
| Rate error | `plumb-replay --truth-rate` on rig recordings pushed to a metronome | Not measured yet |
| Depth error | Gain fitted on one recording, scored on another (`--gain-from`), against the rig's fixed travel | Not measured yet |
| Share of time locked | `plumb-replay` "time locked" across distance, angle, sleeves and light | Not measured yet |
| Time to lock | Seconds from the box being placed to locked | Not measured yet |
| LiDAR ablation | `--no-range`: picture slide at an assumed distance beside the LiDAR run, at two distances | Not measured yet |
| Time to first compression, with and without the app | The handoff's time to first compression, against people without the app | Not measured yet |
| Verifier catch rate | Share of scribe sentences with a wrong number or a banned idea that the checker refuses | Not measured yet |
| Scene finder rejections | Points the depth judge rejects, and why, for real AEDs, signs and pictures | Not measured yet |
| Latency | Deepest point to report, then to screen and beat; question to answer | Not measured yet |

**Synthetic self-check, not evidence.** The replay tests render a made-up rig: a camera 40 degrees down
at a textured plate that travels exactly 50 mm, 15 pushes, 2 mm of depth noise. Their fixtures
`Traces.standard` (0.9 m, 110 a minute) and `Traces.nearer` (0.6 m, 116 a minute) were written out by a
throwaway test and run through `plumb-replay`. This checks the code against its own renderer only.

| Run | Pushes counted | Depth error, median absolute (bias) | Rate error, median absolute |
| --- | --- | --- | --- |
| Along the line of sight, 0.9 m | 15 of 15, all locked | 0.3 mm (-0.3) | 0.1 a minute |
| Along the line of sight, 0.6 m | 15 of 15, all locked | 0.2 mm (-0.2) | 0.1 a minute |
| Picture slide, 0.9 m | 15 of 15, all locked | 3.3 mm (-3.4) | 0.0 a minute |
| No LiDAR, 1.0 m assumed, gain 0.973 fitted at 0.9 m, scored at 0.6 m | 15 of 15, all locked | 22.8 mm (+22.8) | 0.0 a minute |

Each trace was locked for 90% of its 10.5 s. The median delay from deepest point to report was 0.065 to
0.077 s of trace time; the phone's own processing comes on top.

## Fails when

The app's own list, shown on show working, none of it measured yet: dark, loose sleeves; phone held, not
propped; steep angle from above; soft surface under the chest; two people in frame.

Known limits in the code:
- Nothing has run on the real phone. The Simulator cannot inject touches into this landscape app, so
  screens are reached with `-jump`, and cannot run Vision person segmentation, so people hiding is
  tested only with a stand-in for Vision.
- The picture slide reads about 7% short at 50 mm: the phone passes the box centre's fixed pixel, and
  the estimator treats it as if it followed the hands. Not fixed; the app runs along the line of sight.
- Defaults assume a phone about a metre away. Adult targets only: 5 to 6 cm, 100 to 120 a minute.
- Find AED does nothing without a key. Asking offline needs the phone's speech model; until it is ready
  a press is refused with a note in the log.

## Build and run

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPhone with LiDAR on
iOS 18 or later. Without LiDAR, and in the Simulator, the app plays a labelled replay of a made-up
session: too shallow, corrected, a pause, good again, then hands off.

```sh
brew install xcodegen
cp Config/Local.example.xcconfig Config/Local.xcconfig      # set DEVELOPMENT_TEAM to your team
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig  # optional: set GEMINI_API_KEY
xcodegen generate
open Plumb.xcodeproj
```

`Local.xcconfig`, `Secrets.xcconfig` and `Plumb.xcodeproj` are git-ignored. Never commit
`Secrets.xcconfig`. Without a key the app runs fully; only the model helpers are off.

Launch arguments (Xcode: Edit Scheme, Run, Arguments; Simulator:
`xcrun simctl launch booted com.patriotsbreeze.plumb <arguments>`): `-replay` plays the made-up session
on a phone that has the sensors. Debug builds only: `-jump handoff|working|chest <seconds>` moves to that
screen after that many seconds.

Package tests (Capture is iOS only; use any iPhone simulator):

```sh
for p in Contracts Signal Coach Session Geometry Sound UI Agents Replay; do
  (cd Packages/$p && swift test) || break
done
cd Packages/Capture && xcodebuild test -scheme PlumbCapture \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Replay a trace on the Mac from `Packages/Replay`. [Its README](Packages/Replay/README.md) covers
recording, pulling traces off the phone, calibrating on one recording and scoring another, and every flag.

```sh
swift run -c release plumb-replay ../../recordings/<trace>.jsonl --truth-depth-mm 50 --truth-rate 110
```

## Repository map

- `App/`: the app target: the rescue loop (`RescueController`), screens, model helpers, "Hold to ask" routing, live and replay feeds.
- `Packages/Contracts`: frozen shared types: samples, lock states, pushes, metrics, the five cues, targets, the log.
- `Packages/Geometry`: the two height methods, the still reference, projection maths, the trace format.
- `Packages/Capture` (iOS only): ARKit and LiDAR capture, the hands box, AR guides, AED marker, stills with people hidden, recording.
- `Packages/Signal`: pushes, rate, depth, pauses and lock state from height samples; the chest movement check.
- `Packages/Coach`: the fixed cue rules and their words.
- `Packages/Sound`: the beat, its tick and tock, and spoken cues over it.
- `Packages/Session`: the session log, the handoff numbers and text, the scribe's checker.
- `Packages/UI`: the rescue, chest, show-working and handoff screens.
- `Packages/Agents`: Gemini client, conductor, voice and its tool, scribe, AED finder and its depth judge, offline asking.
- `Packages/Replay`: `plumb-replay`, which replays phone traces on a Mac and scores them against a rig.

## Tools and credits

Most of the code was written by Claude Code, Anthropic's coding agent, under the author's direction.
Gemini models run the optional scribe, live voice and AED finder; their names are set in
`Packages/Agents/Sources/PlumbAgents/AgentsConfig.swift`. The app uses ARKit, RealityKit, Vision,
Speech, Foundation Models, AVFoundation and SwiftUI. XcodeGen generates the Xcode project.
