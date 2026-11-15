# Clinical content

Everything here is a DRAFT until a named reviewer signs it. Every file has `status: DRAFT` and `reviewer: null` until then. See `SAFETY.md`, Waiting on review.

| File | What it is |
|---|---|
| `adult_arrest.v1.json` | The arrest protocol: states, transitions, timeouts, and the speech gate |
| `phrases.v1.json` | The arrest protocol's phrases, each with a citation |
| `modules/triage.v1.json` | Assess, triage after a person taps that the patient is responding, and Something else |
| `modules/possible_heart_attack.v1.json` | The possible heart attack flow, with the aspirin check and the one approved dose |
| `modules/possible_broken_bone.v1.json` | The possible broken bone flow, with its danger step for bleeding and neck or back injury |
| `modules/possible_choking.v1.json` | The possible choking flow: the cough question, back blows and abdominal thrusts in turn, and the check after |
| `knowledge_pack.v1.json` | Approved text the AI voice draws on in the awake states, paraphrased from the guidelines with a source on each topic and no milligram doses |

The arrest files are frozen. Modules merge over them at load, in the order above, and a module that fails the loader's checks is dropped whole and named on the operator panel, with the arrest path exactly as shipped. Without the knowledge pack the flows still run by their local phrases, and the AI voice stays closed. `BundleValidator` in `Packages/RescueCore` holds the checks, and `SAFETY.md` the invariants they keep.

## Cues and the material scan

A module's awake step may point at the body or at something in the room while it runs. Core's files have neither field, and a core state that carries one makes the protocol unrunnable.

`cues` is a list on a state. Each cue is `{ phrase, material?, body?, placement?, callout? }`:

| Field | Values | Meaning |
|---|---|---|
| `phrase` | a phrase id | The line the cue points from. It must be one of the state's `entry_phrases` or `allowed_say`, and a phrase of the same module |
| `material` | `towel`, `pillow`, `gloves`, `aed` | What to look for in the room. The line must name it, for example "cloth" for a towel |
| `body` | `injured_limb`, `injury_site` | Where on the patient. Both hang off the injury pin, so the state needs `"overlay": "injury_site"` |
| `placement` | `under`, `on`, `behind` | Where the material goes against that body part. Needs a `body` |
| `callout` | text | The chip drawn by the material, word for word. 1 to 4 words, not counting "·" or punctuation, every word taken from the cue's phrase, one of them naming the material. It needs a `material` and must pass the same rules as a phrase |

A line listed in `allowed_say` only so a cue can point from it, like `limb_support` on `limb_wait`, is never the model's to say, and the brief leaves it out. A value the loader doesn't know is refused by name, for example `cue body upper_back is not known: limb_splint`.

`locate_materials: true` lets the app send single frozen frames to the one-shot locator on that step, never to the Live session, and never during a call. It asks for every material the cues of the step's flow name, not only the step's own, because a locate takes seconds and a towel or pillow should already be found when the step that points at it starts. The broken bone flow sets it on all five steps, so the scan starts at `limb_start`. `frame_uplink` is unchanged and still false on every limb step. The model never sees cues or materials: its tools, `Resource`, and `LocatableObject` are unchanged.

How the app draws a step's cues: `injured_limb` is a capsule along the limb nearest the pin, `injury_site` the ring where hands press at the pin, and a step with no body cue keeps the ring at the pin. A material's callout shows only once the locator has seen it twice at about one spot, for 60 s at most for a towel, pillow, or gloves, with a pointer from the band's edge when it's off screen. `placement` isn't drawn yet. The AED keeps its own arrow and is never a callout.

Sources: the 2024 AHA and Red Cross First Aid guidelines, 2025 AHA CPR, and 2025 ILCOR. A clinician must confirm every line.
