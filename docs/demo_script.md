# Demo script, two runs

**SIMULATION. Nobody compresses a real person. Nobody takes real aspirin or is splinted. No build used here can dial 911.** Read `SAFETY.md` first. Make no clinical claims when presenting.

Run 1 is about 3 minutes: a possible heart attack that becomes a cardiac arrest. Run 2 is about 45 s: a possible broken arm.

## Cast

| Role | Does |
|---|---|
| Rescuer | Talks to the phone and the patient, then compresses the manikin. Never touches the volunteer's chest |
| Helper | Holds the phone and camera. Runs the mock dispatcher sheet, the room scan, the pin, and the operator panel. Places any call from their own phone, never the demo phone |
| Volunteer | Consenting adult, written consent covering video sent to Google. Plays the patient: sits clutching their chest in run 1, then slumps onto the mat and lies still. Holds their forearm in run 2. Takes no real aspirin, and nothing is splinted or tied to them |
| Dispatcher | Teammate on their own phone, across the room. Hears Read Aloud and answers as a dispatcher. No call connects to the demo phone |
| Paramedic | Teammate who arrives at the end of run 1 and takes the card |

## Set up before going on

- Chair for the volunteer with a mat in front of it, and a manikin beside the mat. AED trainer in plain view on a table, with disposable gloves and a towel beside it.
- Props: an aspirin bottle with nothing in it to swallow, and for run 2 a towel and a pillow in plain view, not on anyone. Nobody wears or holds anything towel-coloured near the patient, since the callouts look for it.
- App already through onboarding, with camera, mic, and location granted. Permissions are never asked during the flow.
- The build carries the committed Gemini clips, and `python3 tools/render_phrases.py --check` passes, so the app's lines are clips in the same voice as the AI and not slow on-device speech. A Release archive won't build otherwise.
- Phone locked, volume full, Bluetooth off, Do Not Disturb on.
- The link pill on the top row reads **Live** in a quick check, then force quit and relaunch to reset the run. Lock the phone. If it won't read Live, use the fallback at the end.

## Stage rules

- Tap **Yes** at "Are they responding?" early, within 10 s, or the timeout takes the CPR path. The volunteer nods rather than answering out loud until Yes is tapped, or the helper taps Yes as they answer. The arrest session is listening there, and a spoken "Yes" it reports before the tap lands is turned away by the gate, which then says "If you are sure, tap yes. If not, we start CPR." Nobody says anything about breathing before that tap: on that question a breathing word heard by the AI goes straight to the call step. After the tap, a report from before it is ignored.
- The helper places any call from a second phone, to a teammate only. A call on the demo phone closes the mic and the AI. An alert row reads "Call active, tap Speaker" on any step, and another adds "AI paused during call" on the awake steps only.
- Close the dispatcher sheet as soon as Read Aloud has finished. While it's open the AI can't hear, and an awake step's timer waits for it.
- The AI hears everyone, the volunteer included. Rehearse the volunteer saying "I'm fine, no ambulance", and what the AI says back, before doing anything like it on stage.
- Once the patient has collapsed, don't say "Yes, he's breathing fine" or "How long do I keep doing this?". Both are known misses in the frozen arrest prompt: the first came back as abnormal breathing in every Mac run, and the second got no answer in 2 of 3, once heard as a dispatcher, which closes the mic for 30 s. Leave out "Should I check his pulse?" too, unless it answers reliably in rehearsal on the phone: it got no answer in 2 of 3 Mac runs.
- The screen says "possible" and "Not a diagnosis". Never say "diagnose" on stage, and don't say "prevents", "safe", "accurate", or anything clinical. Sentinel constrains.
- Props only. The aspirin is never swallowed, compressions go on the manikin, and nothing is splinted.
- Say "simulation" at the start of each run and "seeded" before each seeded beat. If the panel was used for anything beyond the two seeded beats, say so. The amber strip reads OPERATOR USED from the first use until the rescue restarts.
- If a report moves the step while the AI is still answering, the local phrase cuts the answer off. That's expected. Rehearse it so nobody stops.

## Run 1: chest pain, then collapse. About 3 minutes

Times are targets, and the engine keeps its own: the intake question moves on after 10 s, `chest_call` after 15 s, the aspirin question after 20 s, the scan after 20 s, and each setup step after 5 s. "Seeded" means a person triggered it. The detection and the response are real.

| Time | Who | Does | Phone does | Real or seeded |
|---|---|---|---|---|
| 0:00 | Volunteer | Sits in the chair, clutching their chest | | Staged |
| 0:02 | Helper | Unlocks the phone and opens HealthAI SIM. Says "simulation" out loud | Amber strip, "SIMULATION, will not call 911". Voice: "Tap their shoulders and shout. Are they responding?" | Real, local |
| 0:06 | Rescuer, Helper | Rescuer asks "Can you hear me?", volunteer nods. Helper taps **Yes** at once | Voice: "Tell me what's happening, or tap below." The link pill may read "AI switching, can't hear" for a moment | Real, tap |
| 0:12 | | | The AI speaks first: it says it's an AI and asks what they can see | Real AI voice |
| 0:16 | Volunteer | As the patient: "My chest really hurts. It feels like something heavy is sitting on me." | AI heard: chest pain. The deck's command is the call prompt, with "Possible heart attack. Not a diagnosis." in the why row under it, tagged AI chose. Voice: "Possible heart attack.", the call prompt, then "Sit them comfortably. Cushion behind their back." Sit-and-rest card | Real AI hearing, engine decides |
| 0:30 | Helper | Taps **CALL MOCK DISPATCHER**, **Confirm address**, **Read Aloud**. Taps **Close** as soon as Read Aloud has finished | Mic and AI voice close while the sheet is open, and the step waits. On-device voice says it is an AI assistant, then reads the script, which names a possible heart attack, to the Dispatcher | Real script, **mock dispatcher**, no call placed |
| 0:50 | Helper | Taps **Called** | Voice: "Any aspirin allergy, injury, doctor's warning, or not fully alert?" The answers wait 2 s | Real, local |
| 0:55 | Volunteer, Helper | Volunteer shakes their head. Helper taps **No** | Voice: "Chew and swallow one 325 mg aspirin, or two 81 mg." The volunteer holds the prop bottle and swallows nothing. Helper taps **Done, next** | Real, local, **prop** |
| 1:05 | | | Voice: "Stay with them until EMS arrives. If they collapse, tap Not responding now." The AI can talk again | Real, local |
| 1:08 | Helper | Taps **Scan room**, pans to the AED on the table. Taps **Done, next** once the brackets hold | Voice: "Sweep the phone around. Look for an AED, in case they collapse." White brackets and "AED" lock on the AED in the band above the deck, or a pointer at the band's edge says which way and how far. After Done, or 20 s with no tap, "Stay with them until EMS arrives..." plays again | Real, cloud locate calls every 2 s until one lands, plus a local anchor |
| 1:30 | Rescuer | Once the wait line has finished, asks "Should he lie down flat or stay sitting up?", then "Are you a doctor?" | The AI answers in a sentence or two: whatever position is comfortable, and that it's an AI, not a doctor. It may add its own not-medical-advice line. An answer that arrives while the app is speaking waits for it to finish | Real AI voice |
| 1:50 | Volunteer, Rescuer | Volunteer slumps and slides down onto the mat. Rescuer: "He's not responding!" | AI reports it, and the phrase playing is cut. Voice: "Are they breathing normally? Gasping does not count." The AI switches to the arrest session | Real AI hearing, engine decides |
| 1:55 | Helper | Taps **No**, then aims at the volunteer's chest, in the band above the deck | Voice: the call prompt, roll flat, then hand placement. On hand placement the deck goes compact, and a cyan chest zone with stacked ghost hands sits on the volunteer's chest for the whole step, dashed while pose is only estimating | Real, local, pose on the phone |
| 2:10 | Rescuer | Moves to the manikin. Says "we never compress a real person" | Compressions, three 5 s steps after the No. Metronome starts, and the ghost rescuer pushes on its beat, or the small beat dot in the corner if the ghost can't show. The AED pointer is already there, beside the beat, reading "AED seen earlier" | Real, local, arrow from the scan |
| 2:15 | Helper | Says "here is a seeded failure". Holds the amber strip for 1.5 s to open the operator panel. Taps **Force hand placement**, then **Seed bad AI line**. If Force hand placement is grey, hand placement is still up, so go straight to Seed bad AI line | Beat stops while hand placement is forced, the ghost hands come back on the chest, and the AED pointer is gone until compressions come back. On-device voice: "Seeded test line. Check his pulse first." Then: "Correction. Do not check for a pulse." Compressions resume by themselves after 5 s, pointer and all | **Seeded line and forced state**, real validator and correction |
| 2:25 | Helper | Says "and a seeded stop report". Taps **Seed stop report**. Then taps **Show Sentinel** on the panel | Nothing changes for the rescuer. The Sentinel lane shows `report_finding(breathing_normally)` rejected, `cannot_lower_urgency`, tagged SEEDED | **Seeded report**, real safety gate |
| 2:35 | Presenter | Reads the Sentinel caption: it constrains, it does not prevent | Voice, Sentinel, and Protocol lanes | Real |
| 2:40 | Helper | Closes the panel, follows the pointer to the AED trainer and brings it. Taps **AED here**, then **Done, next**, and frames the manikin's chest in the band | Voice: "Turn the AED on". Pads 1 and 2 drawn on the manikin's chest, numbered, reading "Pad zones, coarse. Manikin only.", or the pad diagram if pose finds nothing. The deck stays compact. The pointer is gone from here on | Real logic, pose on the phone, **trainer prop** |
| 2:50 | Rescuer | Sticks pads on the manikin. Helper taps **Pads on** | Metronome and pulse stop. AED trainer takes over. Voice: "Follow the AED now" | Real logic, **trainer prop** |
| 2:55 | Helper | Turns on airplane mode in Control Center, in full view | The link pill changes to **Offline protocol**. Guidance carries on | Real |
| 3:00 | Helper | When the trainer says to push, taps **AED says push**. Taps **Shock marked** if it shocked | Voice: "Start pushing again now". Pulse returns. Metronome stays off unless toggled | Real logic |
| 3:10 | Paramedic | Arrives. Helper holds **EMS arrived** for 2 s, then taps **Yes, stop CPR** | Handoff card, DRAFT, with source tags, a Concern row for the possible heart attack, and "Aspirin advised, not confirmed taken" | Real, from the event log |
| 3:15 | Helper | Taps **Read card aloud**, hands over the phone | On-device voice reads the card | Real |

The aspirin question asks about risks, so its answers run the other way from a usual check. **Yes means a risk, and gives no aspirin:** "No aspirin. Wait for EMS." No means no risk, and gives the dose. A Yes tapped by habit, a Not sure, or no answer in 20 s all give no aspirin, which is the safe way round. Carry on.

Between runs, turn airplane mode off, force quit, and relaunch, then wait for the link pill to read Live.

The Start CPR shortcut, from either breathing question, skips hand placement. Then compressions open with the same chest zone and ghost hands for 8 s, with the deck compact and the beat docked beside them, and the full arrest panels come back after that.

## Run 2: injured arm. About 45 s

The engine keeps its own times: `limb_start` moves on after 6 s, the danger question after 10 s, and `limb_splint` after 10 s. The room scan for the towel, pillow, and gloves starts at `limb_start`, and a callout shows once the locator has seen its object twice, usually 8 to 16 s in, so expect the callouts on `limb_splint` or `limb_wait` and not before.

| Time | Who | Does | Phone does | Real or seeded |
|---|---|---|---|---|
| 0:00 | Volunteer | Sits holding their forearm | | Staged |
| 0:02 | Helper | Opens HealthAI SIM. Says "simulation" | Voice: "Tap their shoulders and shout. Are they responding?" | Real, local |
| 0:05 | Volunteer, Helper | Volunteer nods. Helper taps **Yes** at once | Voice: "Tell me what's happening, or tap below." The AI may start to say it's an AI, and the tap at 0:08 cuts it off or stops it. That's expected | Real, tap |
| 0:08 | Helper | Taps **Injured arm or leg**, then pans once across the room, past the towel and pillow, and back to the arm | The command reads "Possible broken bone. Keep it as found.", with "Possible broken bone. Not a diagnosis." in the why row, tagged You tapped. Voice: "Possible broken bone. Keep it as found." Hint: "Tap the injury on screen". The room scan starts, on frozen frames only | Real, local, cloud locate |
| 0:10 | Helper | Frames the forearm in the band above the deck and taps the injury on screen | Cyan ring at the tap: "Possible break. Keep as found" | Real, on-device |
| 0:14 | Volunteer, Helper | Phone asks the danger question. Volunteer says "No". Helper taps **No** | Voice: "Heavy bleeding? Neck or back pain? Limb blue or pale?" The answers wait 2 s. No answer in 10 s takes the danger branch | Real, local |
| 0:18 | Helper, Rescuer | Helper keeps the arm and the towel in the band. Rescuer slides the towel the callout points at under the forearm as the volunteer holds it. Nothing is tied or splinted | Voice: "Cover open wounds with clean cloth." Then "Don't straighten it. Pad under it: towel, pillow." A cyan capsule along the forearm, white brackets on the towel reading "Pad under · Towel", and the pillow's callout, "Pad under · Pillow", or a pointer to it from the band's edge. Support card picture in the corner | Real, local, pose and cloud locate, **prop** |
| 0:28 | | | Voice: "They need medical care. Call 911 if unsure or it gets worse." The capsule and the callouts stay. The AI can talk again | Real, local |
| 0:30 | Helper | The pin's ring comes down 20 s after it was placed, and the hint comes back. The capsule stays while the arm is in view. Taps the injury again if the capsule has gone too | The ring is back, and its 20 s starts over | Real, on-device |
| 0:35 | Rescuer | Asks "Should I put some ice on it?" | The AI says to leave the arm as it is | Real AI voice |
| 0:45 | Presenter | Ends the run | | |

If the AI routes from what the volunteer says before the helper taps, the screen reads AI chose. Carry on from the pin. A Yes at the danger question goes to `limb_danger`, where the ring is where hands press, with "Press · Cloth" on the towel and "Put on · Gloves" on the gloves.

## If something goes wrong

| What happens | Do this |
|---|---|
| "If you are sure, tap yes. If not, we start CPR." plays at the first question | The gate turned away an AI report that the patient is responding, since only a tap can lower urgency. Tap **Yes** and carry on |
| The link pill doesn't read **Live** before a run, or drops mid-run | Run both flows by taps, which work offline. Run 1: **Yes**, **Chest pain or heart symptoms**, **Called**, **No**, **Done, next**, then skip the scan, since there's no arrow without the network. At the slump tap **Not responding now**, then **No**, and carry on as written, tapping **AED here** when the AED comes. Run 2 runs as written, since the pin is on-device. Skip the AI questions. Say the AI is offline |
| AI doesn't speak first after "Tell me what's happening" | An alert row reads "AI quiet, use the buttons" after 4 s. Tap **Chest pain or heart symptoms** |
| AI doesn't move to the heart attack step on the patient's words | Tap **Chest pain or heart symptoms**. The screen then reads You tapped |
| Wrong flow tapped | Hold **Not this, go back** for 2 s, then tap the right button |
| A step won't move on | Check the dispatcher sheet is closed. An awake step waits while it's open |
| The AI hears a risk in the aspirin answer | The phone says "Do not give aspirin. Wait for EMS." and aspirin is off for the rest of the run. That's the safe way round. Carry on |
| The AI adds "not medical advice, see a healthcare professional" | It's told not to now, but did in about 4 answers in 10 on the older prompt. Carry on |
| The AI says something wrong and nothing corrects it | Expected. The awake checks are kept short for the demo, so most wrong answers are heard in full. Carry on |
| A correction plays after a right answer | The validators sometimes flag a right line. Carry on |
| AI misses "He's not responding!" for more than about 3 s | Tap **Not responding now** |
| Brackets don't lock during the scan | Carry on. In compressions, tap **Scan room** and pan to the AED, as on the arrest path, or tap **AED here** and point at it |
| No pointer in compressions | AR was reset, or the scan found nothing. Same as above |
| No towel or pillow callout in run 2 | Carry on. The voice has said it, and callouts gate nothing. Pan once past them if there's time. With no key there are none |
| A callout lands on the wrong thing | Ignore it and say so. The locator can be wrong, which is why the voice leads |
| "Hold the phone steady" | The marks went for more than 0.5 s. Hold still and frame the body or the object in the band again |
| Pin says "Couldn't place the pin. Tap again." | Move closer so the arm fills more of the band, and tap again. The pin gates nothing |
| Ghost hands or pads don't appear | Say so and carry on, since the voice has already given the step. They never hold anything up. Pads fall back to the diagram |
| AED trainer talks over the app | Tap **Pads on** if pads are on. If the model reports the AED, the phone pauses by itself for 8 s and an alert row shows "AED talking". Otherwise use the panel's **AED talking** to pause audio, and say so |
| An alert row reads "Mic problem, AI can't hear" | Carry on with the tap buttons. The AI isn't hearing anything, even if the link pill reads Live. Say so |
| An alert row reads "Call active, tap Speaker", with "AI paused during call" on an awake step | A call is up on the demo phone. End it. Calls go from the helper's phone |
| Speech lags behind the buttons | A tap drops whatever hadn't started, except the call prompt, and the phrase already playing finishes. So it lags by at most one or two phrases. The screen is always current |
| App crashes or hangs | Relaunch. The rescue restarts from the top |
