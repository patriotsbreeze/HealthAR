#!/usr/bin/env python3
"""Checks the rendered phrase clips in App/Resources/phrases before they ship. Exits 1 on any failure.

Offline, always:
- every phrase has a 24 kHz 16-bit mono clip that matches its text, the render settings, and
  GEMINI_VOICE in Config/Demo.xcconfig, the voice Live speaks in
- the timing budgets the clip-gated Swift tests hold (MergedInvariantTests), plus the arrest setup
  steps, whose 5 s timers move on whatever is still being said
- a pace outside 1.7 to 3.8 words a second, as a warning

Online, unless --no-transcribe: Gemini Flash transcribes each clip blind, never sent the expected
text, and the transcript is compared word by word with the phrase. Transcription is a model too,
so a WARN needs a human listen. One word off on a long line warns, unless the word is a negation or
a number: "Do give aspirin" or "375 mg" fails. Transcripts are cached by clip sha256 in verify.json,
next to the clips, so a re-run only pays for clips that changed. A reply with no text isn't cached,
so the next run asks again.
"""
import argparse
import base64
import collections
import difflib
import hashlib
import json
import pathlib
import re
import sys

import render_phrases as rp

PROTOCOL = rp.ROOT / "clinical" / "adult_arrest.v1.json"
TRANSCRIBE_MODEL = "gemini-3.8-flash"
TRANSCRIBE_PROMPT = (
    "Transcribe the speech in this audio exactly, word for word. Write numbers as digits. Output only "
    "the transcript, no quotes or commentary. If there is no speech, output NONE."
)

AWAKE_KINDS = {"triage", "flow"}
# The first tap the panel takes lands this far into the step before, so that much of its speech is gone.
TAP_S = 0.6
QUESTION_WINDOW_S = 5.0
ASPIRIN_WINDOW_S = 4.0
# place_hands moves on at 5 s, and every Start CPR tap skips it, so hands_center has to fit with room.
HANDS_CENTER_MAX_S = 4.5
PACE_RANGE = (1.7, 3.8)

Budget = collections.namedtuple("Budget", "name detail margin ok")


def cache_path():
    return rp.OUTPUT / "verify.json"


# Timing


def load_states():
    """Core states, then every module's, as the merged bundle has them."""
    states = []
    for source in [PROTOCOL, *sorted(rp.MODULES.glob("*.json"))]:
        try:
            states.extend(json.loads(source.read_text(encoding="utf-8")).get("states", []))
        except (OSError, ValueError, AttributeError) as error:
            sys.exit(f"{source.name}: {error!r}")
    return states


def said(state, seconds):
    """Seconds of entry speech, or None if a clip is missing."""
    durations = [seconds.get(phrase) for phrase in state.get("entry_phrases", [])]
    return None if any(value is None for value in durations) else sum(durations)


def budgets(states, seconds):
    """Mirrors MergedInvariantTests everyTimedStepOutlastsItsOwnLines and aQuestionLeavesTimeToAnswerIt,
    with the overhang measured from triage_ask rather than pinned."""
    results = []
    by_id = {state["id"]: state for state in states}
    overhang = max(0.0, seconds.get("triage_ask", 0.0) - TAP_S)

    def missing(state):
        absent = [phrase for phrase in state.get("entry_phrases", []) if seconds.get(phrase) is None]
        return Budget(state["id"], f"no clip for {', '.join(absent)}", float("-inf"), False)

    for state in states:
        timeout = (state.get("timeout") or {}).get("seconds")
        if timeout is None:
            continue
        spoken = said(state, seconds)
        if state.get("kind") in AWAKE_KINDS:
            if spoken is None:
                results.append(missing(state))
                continue
            margin = timeout - spoken - overhang
            results.append(Budget(
                state["id"], f"{spoken:.2f} s said + {overhang:.2f} s overhang < {timeout:g} s step", margin, margin > 0))
            if state.get("question"):
                window = timeout - spoken
                results.append(Budget(
                    f"{state['id']} answer", f"{window:.2f} s to answer, needs {QUESTION_WINDOW_S:g}",
                    window - QUESTION_WINDOW_S, window >= QUESTION_WINDOW_S))
        elif state.get("kind") == "setup":
            if spoken is None:
                results.append(missing(state))
                continue
            margin = timeout - spoken
            results.append(Budget(state["id"], f"{spoken:.2f} s said < {timeout:g} s step", margin, margin > 0))

    call, check = by_id.get("chest_call"), by_id.get("chest_aspirin_check")
    if call and check and (check.get("timeout") or {}).get("seconds") is not None:
        before, asked = said(call, seconds), said(check, seconds)
        if before is None or asked is None:
            results.append(missing(call if before is None else check)._replace(name="chest_aspirin_check answer"))
        else:
            window = check["timeout"]["seconds"] - (before - TAP_S) - asked
            results.append(Budget(
                "chest_aspirin_check answer", f"{window:.2f} s to answer after a first tap, needs {ASPIRIN_WINDOW_S:g}",
                window - ASPIRIN_WINDOW_S, window >= ASPIRIN_WINDOW_S))

    if "hands_center" in seconds:
        length = seconds["hands_center"]
        results.append(Budget(
            "hands_center", f"{length:.2f} s, at most {HANDS_CENTER_MAX_S:g}", HANDS_CENTER_MAX_S - length, length <= HANDS_CENTER_MAX_S))
    return results


def review_lines(states, seconds):
    """The other arrest timers, such as the 10 s intake questions. No test pins these, so they're
    printed for a person to judge rather than failed."""
    lines = []
    for state in states:
        timeout = (state.get("timeout") or {}).get("seconds")
        if timeout is None or state.get("kind") in AWAKE_KINDS or state.get("kind") == "setup":
            continue
        spoken = said(state, seconds)
        if spoken is not None and state.get("entry_phrases"):
            lines.append(f"  {state['id']}: {spoken:.2f} s said, {timeout:g} s step, {timeout - spoken:.2f} s left")
    return lines


# Transcripts


ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
ACRONYMS = ["aed", "ems", "cpr"]
# One of these misheard changes what the line tells someone to do: a dropped "not", "do" for "don't",
# or a dose. A one-word slip anywhere else is only a spelling, as "centre" for "center".
MEANING_WORDS = {"not", "no", "never", "dont", "doesnt", "cant", "wont", "isnt", "do", "does", "stop",
                 "hundred", "thousand"} | set(ONES) | {word for word in TENS if word}


def number_words(number):
    """0 to 9999, with no "and", as in "three hundred twenty five"."""
    if number < 20:
        return ONES[number]
    if number < 100:
        return TENS[number // 10] + ("" if number % 10 == 0 else " " + ONES[number % 10])
    if number < 1000:
        rest = number % 100
        return ONES[number // 100] + " hundred" + ("" if rest == 0 else " " + number_words(rest))
    rest = number % 1000
    return number_words(number // 1000) + " thousand" + ("" if rest == 0 else " " + number_words(rest))


def normalize(text):
    """Lowercase words, with the spellings a transcript may choose made equal."""
    text = text.lower().replace("’", "'").replace("‘", "'")
    text = re.sub(r"\b(9-1-1|911|9 1 1|nine[- ]one[- ]one)\b", " nine one one ", text)
    for word in ACRONYMS:
        text = re.sub(r"\b" + r"\.?[\s-]*".join(word) + r"\.?(s?)\b\.?", lambda match: f" {word}{match.group(1)} ", text)
    text = re.sub(r"(\d)([a-z])", r"\1 \2", text)
    text = re.sub(r"\b(mg|milligrams?)\b", "milligrams", text)
    text = re.sub(r"\d+", lambda match: f" {number_words(int(match.group()))} " if len(match.group()) <= 4 else match.group(), text)
    text = re.sub(r"\b(hundred|thousand) and\b", r"\1", text)
    text = text.replace("'", "")
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return " ".join(text.split())


def score(reference, transcript):
    """("PASS" | "WARN" | "FAIL", why). Extra words at either end fail, since that is how a style
    read aloud would show."""
    if transcript is None or transcript.strip().strip(".").upper() in ("", "NONE"):
        return "FAIL", "no speech heard"
    expected, heard = normalize(reference).split(), normalize(transcript).split()
    operations = [op for op in difflib.SequenceMatcher(a=expected, b=heard, autojunk=False).get_opcodes() if op[0] != "equal"]
    if not operations:
        return "PASS", ""
    first, last = operations[0], operations[-1]
    if (first[0] == "insert" and first[1] == 0) or (last[0] == "insert" and last[1] == len(expected)):
        return "FAIL", "extra words at the start or end"
    edits = sum(max(i2 - i1, j2 - j1) for _, i1, i2, j1, j2 in operations)
    if edits == 1 and len(expected) >= 6:
        _, i1, i2, j1, j2 = operations[0]
        touched = set(expected[i1:i2]) | set(heard[j1:j2])
        if touched & MEANING_WORDS or any(word.isdigit() for word in touched):
            return "FAIL", f"a negation or number differs: {' '.join(sorted(touched))}"
        return "WARN", "one word differs"
    return "FAIL", f"{edits} words differ"


def transcription_body(blob):
    """The audio and the instruction only. The expected text never goes, so the check stays blind."""
    return {
        "contents": [{"role": "user", "parts": [
            {"inlineData": {"mimeType": "audio/wav", "data": base64.b64encode(blob).decode("ascii")}},
            {"text": TRANSCRIBE_PROMPT},
        ]}],
        "generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingLevel": "LOW"}},
    }


def transcribe(blob, key, model=TRANSCRIBE_MODEL):
    url = f"{rp.API_BASE}/models/{model}:generateContent"
    response = rp.post_json(url, transcription_body(blob), key, label="Gemini transcription")
    try:
        parts = response["candidates"][0]["content"]["parts"]
    except (KeyError, IndexError, TypeError):
        return None
    text = "".join(part.get("text", "") for part in parts if isinstance(part, dict) and not part.get("thought"))
    return text.strip() or None


def load_cache():
    try:
        document = json.loads(cache_path().read_text(encoding="utf-8"))
        if isinstance(document.get("transcripts"), dict):
            return document
    except (OSError, ValueError, AttributeError):
        pass
    return {"transcripts": {}}


def save_cache(cache):
    cache_path().write_text(json.dumps(cache, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# Main


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-transcribe", action="store_true", help="Local and timing checks only. No key, no network.")
    parser.add_argument("--transcribe-model", default=TRANSCRIBE_MODEL)
    parser.add_argument("--engine", choices=["gemini", "say"], default="gemini", help="What the clips should have been rendered with.")
    parser.add_argument("--voice", help="Default: GEMINI_VOICE in Config/Demo.xcconfig.")
    parser.add_argument("--model", default=rp.GEMINI_MODEL, help="The TTS model the clips should come from.")
    args = parser.parse_args()

    phrases = rp.load_phrases()
    engine = args.engine
    model = args.model if engine == "gemini" else None
    voice = rp.choose_voice(args.voice, engine)
    manifest = rp.load_manifest()["clips"]
    failures = []

    # Each clip against its phrase, the render settings and the Live voice.
    for phrase in phrases:
        status, why = rp.clip_status(phrase, manifest.get(phrase["id"]), engine, model, voice)
        if status != "ok":
            failures.append(f"{phrase['id']}: {status}, {why}")
    if engine == "gemini":
        configured = rp.configured_voice()
        if voice != configured:
            failures.append(f"voice {voice} isn't GEMINI_VOICE ({configured}), so clips and Live won't match")
        others = sorted(name for name, entry in manifest.items() if entry.get("voice") != configured)
        if others:
            failures.append(f"manifest voice isn't GEMINI_VOICE ({configured}) for: {', '.join(others)}")

    seconds = {}
    for phrase in phrases:
        length = rp.clip_seconds(rp.OUTPUT / f"{phrase['id']}.wav")
        if length is not None:
            seconds[phrase["id"]] = length
            pace = len(phrase["text"].split()) / length
            if not PACE_RANGE[0] <= pace <= PACE_RANGE[1]:
                print(f"warning: {phrase['id']} is {pace:.1f} words a second, {length:.2f} s")

    states = load_states()
    print("Timing budgets:")
    for budget in budgets(states, seconds):
        margin = f", margin {budget.margin:.2f} s" if budget.margin != float("-inf") else ""
        print(f"  {'ok  ' if budget.ok else 'FAIL'} {budget.name}: {budget.detail}{margin}")
        if not budget.ok:
            failures.append(f"budget {budget.name}: {budget.detail}")
    review = review_lines(states, seconds)
    if review:
        print("Other arrest timers, for review:")
        print("\n".join(review))

    if not args.no_transcribe:
        cache = load_cache()
        key = rp.load_api_key()
        counts = collections.Counter()
        for phrase in phrases:
            path = rp.OUTPUT / f"{phrase['id']}.wav"
            if phrase["id"] not in seconds:
                continue
            blob = path.read_bytes()
            digest = hashlib.sha256(blob).hexdigest()
            cached = cache["transcripts"].get(digest)
            # A reply with no text is asked again on the next run, never kept, or a good clip stays red.
            if not cached or cached.get("model") != args.transcribe_model or cached.get("transcript") is None:
                heard = transcribe(blob, key, args.transcribe_model)
                cached = {"id": phrase["id"], "model": args.transcribe_model, "transcript": heard}
                if heard is not None:
                    cache["transcripts"][digest] = cached
                    save_cache(cache)
            status, why = score(phrase["text"], cached["transcript"])
            counts[status] += 1
            if status != "PASS":
                print(f"  {status} {phrase['id']}: {why}. Heard: {cached['transcript']!r}")
            if status == "FAIL":
                failures.append(f"{phrase['id']}: transcript {why}")
        print(f"Transcripts: {counts['PASS']} pass, {counts['WARN']} warn, {counts['FAIL']} fail")

    if failures:
        print(f"{len(failures)} problem(s):")
        for failure in failures:
            print(f"  {failure}")
        sys.exit(1)
    print(f"OK: {len(phrases)} clips, {engine}, {model + ', ' if model else ''}{voice}.")


if __name__ == "__main__":
    main()
