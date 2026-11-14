# HealthAI

> **SIMULATION. NOT FOR REAL EMERGENCIES.** This build cannot call 911. In a real emergency, use your phone's dialer. This software has no clinical validation and is not a medical device.

A phone app that guides a bystander through an emergency using voice, camera, and AR, then hands a report to EMS. The current build is a DRAFT simulation for a private demo, run on a manikin and props, built so its safety boundaries carry into a later product. Every protocol, phrase, and line of approved text is DRAFT until a named reviewer signs it.

**Core rule: the model reports, the engine decides.** A deterministic on-device protocol owns every required step and keeps working with no network. Gemini Live hears and sees, and can raise urgency but never lower it.

## What it does

- **Cardiac arrest.** "Are they responding?", then "Are they breathing normally?", then the call prompt, hand placement, a metronome, the AED steps, and a handoff card. No reply on this path goes to CPR. A rescue that never enters an awake state runs exactly as it did before them, apart from a What's going on? button on the static responsive card, which leads to triage.
- **Triage, after a Yes tap.** Once a person taps that the patient is responding, the app asks what's going on. A person taps Chest pain or heart symptoms, Injured arm or leg, or Something else, or the AI routes from what it hears, only upward in urgency. The screen says "possible" and "Not a diagnosis", and the why panel shows whether the AI chose or a person tapped.
- **Possible heart attack.** The call prompt, sitting comfortably with a guide card, an aspirin check, a wait step, and a room scan for the AED. The aspirin check asks about risks, so Yes means a risk and no aspirin, and only a person's No reaches the one approved dose.
- **Possible broken bone.** Leave the limb as found, a danger question, then cover any wound and support the limb with a guide card, or the danger step for heavy bleeding or a neck or back injury.
- **Conversational AI in the awake states.** A Live session of its own, with an awake prompt and a knowledge pack of approved text, talks with the rescuer in triage, the wait steps, the danger step, choking, and anything else. It's told to say it's an AI, to say "could be", and never to give a dose, and validators correct it out loud when it doesn't, which can be after the line was heard. With no knowledge pack it only listens.
- **AR per flow.** The arrest path has the chest ring at hand placement and the AED arrow from Scan room. The heart attack flow's scan finds the AED early, and if the patient collapses the arrow is already there in compressions. The broken bone flow puts a pin where a person taps the injury on screen.
- **Collapse.** "Not responding now", Start CPR, or the AI hearing a collapse in any awake state goes to the breathing question or compressions.

Everything works offline by taps. The AI adds to the local steps and replaces none of them.

While the camera is active, on-device pose detection shows blue, named dots for shoulders, elbows, wrists, and hips, with a translucent arm-and-torso outline for each person. Left and right are the detected person's sides. Face and leg points are hidden, and missing or uncertain joints leave gaps. The shaded outline follows 2D image points; it is not a depth-accurate 3D body mesh, a sternum detector, or a compression-depth measurement. The existing hand-placement guide remains separate. Test alignment and left/right labels on a device before a demo.

## Layout

| Path | What it is |
|---|---|
| `clinical/` | Arrest protocol and phrases, the triage, heart attack, and broken bone modules, and the knowledge pack. Each with citations, and DRAFT until reviewed |
| `contracts/` | Tool definitions for the arrest session and the awake session |
| `Packages/RescueCore` | Engine, safety gate, module loader, event log, cards. No network or media code |
| `Packages/RescueAudio` | Metronome, voice mix, speech gate, two audio modes |
| `Packages/RescueVision` | AR session, pose, chest ring, AED locate, injury pin |
| `Packages/RescueLive` | Gemini Live transport, both sessions' prompts, tool routing, auditor, live evals |
| `App/` | SwiftUI demo app |
| `evals/` | Utterance and question sets for the Live session |
| `tools/` | Phrase rendering and the build checks |
| `docs/` | Plan, research brief, demo script, device checks, decision records |

Read [SAFETY.md](SAFETY.md) before running this with anyone.

## Setup

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

Fill in `Config/Secrets.xcconfig`, using a paid-tier Gemini key only. Then:

```bash
xcodegen generate
```

```bash
open HealthAI.xcodeproj
```

### Voice clips

Every fixed line the app speaks is a clip in `App/Resources/phrases`, rendered with Gemini TTS and committed with its `manifest.json`, so a checkout builds with the same voice and no key. Re-render after a phrase's wording changes, or after `GEMINI_VOICE` in `Config/Demo.xcconfig` changes. That one setting is the voice of the clips and of both Live sessions.

```bash
python3 tools/render_phrases.py
```

The script reads the key from `Config/Secrets.xcconfig` itself and never prints it, so don't pass it on the command line or in the environment. It renders only clips whose text, voice, model or style changed, and records each in the manifest. Delivery goes in the TTS style field, never in the spoken text. Then check every clip:

```bash
python3 tools/verify_phrases.py
```

This transcribes each clip blind with Gemini Flash and compares it with its phrase, and checks the step timing budgets that the clip-gated RescueCore tests hold. Add `--no-transcribe` to run only the offline checks.

Other options:

- `python3 tools/render_phrases.py --check` lists missing or stale clips, with no key and no network. A Release build runs the same check through `tools/check_phrase_clips.sh` and fails the archive if any clip is missing or stale.
- `--smoke` renders one line to a temp folder and reports its format, and `--audition Kore,Orus,Alnilam,Charon` renders a few lines in each voice to compare by ear, into `$TMPDIR/healthai_audition` unless `--audition-dir` says otherwise.
- `--only call_911,roll_flat --force` re-renders just those.
- `--engine say` renders offline with macOS `say`. Those clips are for private rehearsal only, because macOS voice output may not be redistributable, so never commit them.

The script renders core's phrases and every module's.

## Test

Each package, the same way:

```bash
(cd Packages/RescueCore && swift test)
```

```bash
(cd Packages/RescueAudio && swift test)
```

```bash
(cd Packages/RescueLive && swift test)
```

```bash
(cd Packages/RescueVision && swift test)
```

The audio controller itself only builds for iOS, so `swift test` on a Mac skips its tests, the smoke test and the awake wiring among them. Run the package on a Simulator too:

```bash
(cd Packages/RescueAudio && xcodebuild test -scheme RescueAudio -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO)
```

The app suite, on a Simulator:

```bash
xcodebuild test -project HealthAI.xcodeproj -scheme HealthAIDemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

```bash
python3 tools/test_render_phrases.py
```

```bash
python3 tools/test_verify_phrases.py
```

```bash
tools/check_no_emergency_number.sh
```

```bash
tools/check_key_not_logged.sh
```

The last one builds a throwaway copy of the app with a made-up key, and takes a few minutes.

### Live evals, against the real model

These make network calls and cost money, so a plain `swift test` skips them. They run only with `HEALTHAI_LIVE_EVAL=1`, one test at a time, from `Packages/RescueLive`. The key is read from `Config/Secrets.xcconfig` by a command substitution for that one command, so it is never echoed or left in the shell:

```bash
cd Packages/RescueLive
HEALTHAI_EVAL_OUT="$TMPDIR/healthai_live_eval" \
HEALTHAI_EVAL_ROUND=round1 \
HEALTHAI_EVAL_KEY="$(awk -F' *= *' '/^GEMINI_API_KEY/{print $2}' ../../Config/Secrets.xcconfig)" \
HEALTHAI_LIVE_EVAL=1 swift test --filter 'LiveEvalTests/triage\(\)' 2>&1 | grep -E 'LIVE_EVAL|error:|Test run with'
```

Never run `echo`, `printenv`, or `set -x` with the key set. [evals/README.md](evals/README.md) lists every test and what it measures. These use synthesised speech on a Mac, so they say nothing about a phone's mic or network, which stay device checks in [docs/device_checks.md](docs/device_checks.md).
