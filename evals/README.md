# Evals

Scripted sets for the Live session. The labelled AED and scene photos for device check 49 aren't in the repo. Photos of people go in `evals/private/`, which is gitignored.

| File | What it is | Kept honest by |
|---|---|---|
| `utterances.json` | The M3 set: 20 scripted lines for the arrest session, each with the tool call it should produce and what the engine does with that call | `App/Tests/EvalSetTests.swift` sends every expected call through the real tool router and engine |
| `triage_utterances.json` | The M8 set: 20 spoken lines, each with the state it's said in, the findings that count, and where the engine must end | `LiveEvalSetTests.everyExpectedTriageReportEndsWhereTheRowSays` sends every expected finding through the real router and engine over the merged bundle |
| `conversation_questions.json` | 20 spoken questions asked where the AI may talk, each with what the answer must not do | `LiveEvalSetTests.everyQuestionIsAskedWhereTheAICanAnswer` checks each row's state is an open awake state |

The offline tests run in every `swift test` and app test run, so the sets can't drift from the contracts or the flows. Only a real run with a key can show whether the model produces what they expect. Each file's `purpose` and `scoring` say how a row is scored and what bar it answers to.

## Running against the real model, from a Mac

`LiveEvalTests`, in `Packages/RescueLive/Tests/RescueLiveTests/LiveEvalTests.swift`, uses the real transport, tool router, engine, and gate over the merged bundle, with `say` as the voice. It only runs with `HEALTHAI_LIVE_EVAL=1`, so a normal `swift test` makes no network calls. Run it one test at a time, from `Packages/RescueLive`:

```sh
HEALTHAI_EVAL_OUT=/some/scratch/folder \
HEALTHAI_EVAL_ROUND=round1 \
HEALTHAI_EVAL_KEY="$(awk -F' *= *' '/^GEMINI_API_KEY/{print $2}' ../../Config/Secrets.xcconfig)" \
HEALTHAI_LIVE_EVAL=1 swift test --filter 'LiveEvalTests/triage\(\)' 2>&1 | grep -E 'LIVE_EVAL|error:|Test run with'
```

The command substitution sets the key for that one command only. Never echo it, and never run `printenv` or `set -x` with it set. Reports go to `$HEALTHAI_EVAL_OUT/$HEALTHAI_EVAL_ROUND/` as JSON, or `$TMPDIR/live_eval/round0/` if those are unset, and each test scans them for the key before finishing. Reports hold the prompts' briefs and synthetic transcripts, so they stay out of the repo.

| Test | What it measures |
|---|---|
| `models` | Which Live models the key can reach |
| `arrestConnects`, `arrestEvals` | The arrest session with `SystemPrompt.text`, `tools.v1.json`, and `utterances.json` |
| `awakeConnects` | The awake session with the pack prompt, and its token count |
| `swapTime` | Stopping one mode's session to the other being ready, 5 each way |
| `kick`, `kickRightAfterTheSeed`, `kickAfterSpeech` | Whether the AI speaks first, 10 tries, with no gap behind the seed, and when the cue is held until a person stops talking |
| `briefIdle`, `briefDuringSpeech` | Mid-session briefs: accepted, replied to, cutting off a turn, version used |
| `toolCallsWhileSpeaking` | Whether the model reports and answers at once |
| `turnTiming`, `bargeIn`, `bargeInAppPath` | How audio arrives against playback, and what talking over it does |
| `triage`, `triageAppPath`, `triageHoldout` | The triage set by server VAD and by the phone's `audioStreamEnd` path, and lines the prompt wasn't tuned on |
| `questions`, `questionsAppPath`, `questionsHoldout` | The question set, with the awake validator over each transcript, and questions the prompt wasn't tuned on |
| `aspirinRoutes` | Aspirin questions at the wait, reached by a skip and by a dose. A reader checks that no answer promises or implies a dose |
| `ownVoice`, `patientShortOfBreath` | The app's own lines spoken back to the model on the step that says each, and a patient who says they can't breathe. Neither may report a collapse |
| `demoStory`, `demoStoryAppPath`, `pastTwoMinutes` | The awake story in one session then the arrest session, over both speech paths, and a session past two minutes |
| `reportsCarryNoKey` | Scans every report in the output folder for the key |

Each test asserts the bars a Mac can measure, and fails if its session never came up. The bars that take reading a transcript stay with whoever reads the reports. A plain `swift test` skips these, which isn't the same as passing them. `arrestEvals` fails today, at 17 of 20 against the M3 bar of 18, and the arrest prompt is frozen. The last full round's numbers are in `SAFETY.md`, under Live behaviour, measured on a Mac only.

This is synthesised speech and a Mac's network. It says nothing about the phone's mic, echo cancellation, client VAD, or a venue's network, which stay device checks in `docs/device_checks.md`.
