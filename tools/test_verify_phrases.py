#!/usr/bin/env python3
"""Run with `python3 tools/test_verify_phrases.py`. No test here touches the network or the real key."""
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

import render_phrases as rp
import verify_phrases as vp
from test_render_phrases import FAKE_KEY, FakeResponse, tone

MODEL = rp.GEMINI_MODEL


def state(state_id, kind, entry, timeout=None, question=None):
    document = {"id": state_id, "kind": kind, "entry_phrases": entry}
    if timeout is not None:
        document["timeout"] = {"seconds": timeout, "to": "next"}
    if question:
        document["question"] = question
    return document


# The shape of the shipped flows, with made-up lengths.
STATES = [
    state("call_911", "setup", ["call_911"], 5),
    state("position_patient", "setup", ["roll_flat"], 5),
    state("place_hands", "setup", ["hands_center"], 5),
    state("intake_responsive", "intake", ["ask_responsive"], 10, "responsive"),
    state("compressions", "cpr", ["start_compressions"]),
    state("triage", "triage", ["triage_ask"]),
    state("chest_call", "flow", ["chest_possible", "call_911", "chest_sit"], 15),
    state("chest_aspirin_check", "flow", ["aspirin_check"], 20, "aspirin_risk_reported"),
    state("limb_start", "flow", ["limb_possible"], 6),
    state("limb_flags", "flow", ["limb_danger_ask"], 10, "danger_signs"),
    state("limb_splint", "flow", ["limb_wound", "limb_support"], 10),
]

SECONDS = {
    "call_911": 4.0, "roll_flat": 3.0, "hands_center": 4.2, "ask_responsive": 3.0, "start_compressions": 3.0,
    "triage_ask": 2.9, "chest_possible": 1.5, "chest_sit": 3.0, "aspirin_check": 4.0,
    "limb_possible": 3.0, "limb_danger_ask": 4.0, "limb_wound": 2.5, "limb_support": 4.0,
}


def by_name(results):
    return {budget.name: budget for budget in results}


class NormalizeTests(unittest.TestCase):
    def test_spellings_a_transcript_may_choose_are_equal(self):
        pairs = [
            ("Call 911 now", "call nine one one now"),
            ("Call 911 now", "Call 9-1-1 now."),
            ("Call 911 now", "Call nine-one-one now"),
            ("one 325 mg aspirin", "one three hundred twenty-five milligrams aspirin"),
            ("one 325 mg aspirin", "One three hundred and twenty five milligram aspirin."),
            ("two 81 mg.", "two 81mg"),
            ("Look for an AED.", "Look for an A.E.D."),
            ("Look for an AED.", "look for an a-e-d"),
            ("Wait for EMS.", "Wait for E M S"),
            ("Start CPR", "start c.p.r."),
            ("Don't straighten it.", "Don’t straighten it"),
            ("Push hard, at least two inches.", "Push hard at least 2 inches"),
        ]
        for written, heard in pairs:
            self.assertEqual(vp.normalize(written), vp.normalize(heard), (written, heard))

    def test_nine_eleven_is_not_nine_one_one(self):
        self.assertNotEqual(vp.normalize("Call 911"), vp.normalize("Call nine eleven"))

    def test_number_words(self):
        self.assertEqual(vp.number_words(0), "zero")
        self.assertEqual(vp.number_words(81), "eighty one")
        self.assertEqual(vp.number_words(325), "three hundred twenty five")
        self.assertEqual(vp.number_words(2000), "two thousand")


class ScoreTests(unittest.TestCase):
    LINE = "Heel of one hand on the center of the chest. Other hand on top."

    def test_an_exact_transcript_passes(self):
        self.assertEqual(vp.score(self.LINE, "Heel of one hand on the center of the chest, other hand on top.")[0], "PASS")

    def test_one_misheard_word_on_a_long_line_warns(self):
        self.assertEqual(vp.score(self.LINE, "Heel of one hand on the centre of the chest. Other hand on top.")[0], "WARN")

    def test_one_misheard_word_on_a_short_line_fails(self):
        self.assertEqual(vp.score("A bit faster.", "A bit after.")[0], "FAIL")

    def test_a_style_read_aloud_fails(self):
        status, why = vp.score("Sit them comfortably.", "In a calm voice, sit them comfortably.")
        self.assertEqual(status, "FAIL")
        self.assertIn("extra words", why)
        self.assertEqual(vp.score("Sit them comfortably.", "Sit them comfortably. Brisk steady pace.")[0], "FAIL")

    def test_no_speech_fails(self):
        for heard in [None, "", "NONE", "None."]:
            self.assertEqual(vp.score(self.LINE, heard)[0], "FAIL")

    def test_dropped_words_fail(self):
        self.assertEqual(vp.score(self.LINE, "Heel of one hand on the chest. Other hand on top.")[0], "FAIL")

    def test_a_dropped_negation_fails(self):
        cases = [
            ("Do not give aspirin. Wait for EMS.", "Do give aspirin. Wait for EMS."),
            ("Correction. Do not check for a pulse. Keep pushing.", "Correction. Do check for a pulse. Keep pushing."),
            ("If pressure does not stop it, tighten a tourniquet above the wound.", "If pressure does stop it, tighten a tourniquet above the wound."),
            ("Put gloves on only if they're in reach. Don't delay pressure.", "Put gloves on only if they're in reach. Do delay pressure."),
        ]
        for line, heard in cases:
            status, why = vp.score(line, heard)
            self.assertEqual(status, "FAIL", (line, heard))
            self.assertIn("negation or number", why)

    def test_a_changed_dose_fails(self):
        line = "Chew and swallow one 325 mg aspirin, or two 81 mg."
        self.assertEqual(vp.score(line, "Chew and swallow one 375 mg aspirin, or two 81 mg.")[0], "FAIL")
        self.assertEqual(vp.score(line, "Chew and swallow one 325 mg aspirin, or two 18 mg.")[0], "FAIL")
        self.assertEqual(vp.score(line, "Chew and swallow one three hundred twenty five milligrams aspirin, or two 81 mg.")[0], "PASS")


class TranscriptionRequestTests(unittest.TestCase):
    def test_the_request_never_carries_the_expected_text(self):
        blob = b"RIFF....WAVEfmt "
        body = vp.transcription_body(blob)
        sent = json.dumps(body)
        for phrase in rp.load_phrases():
            self.assertNotIn(phrase["text"], sent)
        parts = body["contents"][0]["parts"]
        self.assertEqual(parts[0]["inlineData"]["mimeType"], "audio/wav")
        self.assertEqual(parts[1]["text"], vp.TRANSCRIBE_PROMPT)
        self.assertEqual(body["generationConfig"]["temperature"], 0)

    def test_transcribe_skips_thought_parts_and_sends_the_key_as_a_header(self):
        response = {"candidates": [{"content": {"parts": [{"text": "thinking", "thought": True}, {"text": " Push hard. "}]}}]}
        urlopen = mock.MagicMock(return_value=FakeResponse(response))
        with mock.patch.object(rp.urllib.request, "urlopen", urlopen), mock.patch.object(rp.time, "sleep"):
            text = vp.transcribe(b"audio", rp.ApiKey(FAKE_KEY))
        self.assertEqual(text, "Push hard.")
        request = urlopen.call_args[0][0]
        self.assertTrue(request.full_url.endswith("/models/gemini-3.8-flash:generateContent"))
        self.assertNotIn(FAKE_KEY, request.full_url)
        self.assertEqual(request.get_header("X-goog-api-key"), FAKE_KEY)


class BudgetTests(unittest.TestCase):
    def test_the_shipped_shape_fits(self):
        results = vp.budgets(STATES, SECONDS)
        self.assertTrue(all(budget.ok for budget in results), [b for b in results if not b.ok])
        names = by_name(results)
        for name in ["call_911", "position_patient", "place_hands", "hands_center", "chest_call", "limb_start",
                     "limb_splint", "limb_flags answer", "chest_aspirin_check answer"]:
            self.assertIn(name, names)
        self.assertNotIn("intake_responsive", names, "printed for review, not gated")

    def test_the_overhang_is_triage_asks_length_less_the_tap(self):
        # chest_call says 8.5 s: with a 2.9 s triage_ask, 8.5 + 2.3 = 10.8 of 15.
        self.assertAlmostEqual(by_name(vp.budgets(STATES, SECONDS))["chest_call"].margin, 15 - 8.5 - 2.3)
        longer = dict(SECONDS, triage_ask=4.0)
        self.assertAlmostEqual(by_name(vp.budgets(STATES, longer))["limb_start"].margin, 6 - 3.0 - 3.4)

    def test_a_timed_step_must_outlast_its_lines_strictly(self):
        exact = dict(SECONDS, limb_possible=3.7)  # 3.7 + 2.3 == 6
        self.assertFalse(by_name(vp.budgets(STATES, exact))["limb_start"].ok)
        splint = dict(SECONDS, limb_support=5.5)
        self.assertFalse(by_name(vp.budgets(STATES, splint))["limb_splint"].ok)

    def test_a_question_leaves_five_seconds_to_answer(self):
        self.assertTrue(by_name(vp.budgets(STATES, dict(SECONDS, limb_danger_ask=5.0)))["limb_flags answer"].ok)
        self.assertFalse(by_name(vp.budgets(STATES, dict(SECONDS, limb_danger_ask=5.1)))["limb_flags answer"].ok)

    def test_the_aspirin_answer_counts_what_the_tap_kept(self):
        # 20 - (8.5 - 0.6) - 4.0 = 8.1 s.
        self.assertAlmostEqual(by_name(vp.budgets(STATES, SECONDS))["chest_aspirin_check answer"].margin, 8.1 - 4)
        long_check = dict(SECONDS, aspirin_check=8.2)
        self.assertFalse(by_name(vp.budgets(STATES, long_check))["chest_aspirin_check answer"].ok)

    def test_the_arrest_setup_steps(self):
        self.assertFalse(by_name(vp.budgets(STATES, dict(SECONDS, call_911=5.0)))["call_911"].ok)
        self.assertFalse(by_name(vp.budgets(STATES, dict(SECONDS, roll_flat=5.2)))["position_patient"].ok)
        results = by_name(vp.budgets(STATES, dict(SECONDS, hands_center=4.6)))
        self.assertTrue(results["place_hands"].ok)
        self.assertFalse(results["hands_center"].ok, "4.5 s at most, under the 5 s step")
        self.assertTrue(by_name(vp.budgets(STATES, dict(SECONDS, hands_center=4.5)))["hands_center"].ok)

    def test_a_missing_clip_fails_its_budget(self):
        seconds = dict(SECONDS)
        del seconds["chest_sit"]
        budget = by_name(vp.budgets(STATES, seconds))["chest_call"]
        self.assertFalse(budget.ok)
        self.assertIn("chest_sit", budget.detail)

    def test_the_real_protocol_files_load(self):
        names = {item["id"] for item in vp.load_states()}
        self.assertTrue({"call_911", "place_hands", "chest_call", "limb_splint", "triage"} <= names)


class MainTests(unittest.TestCase):
    """main() against a throwaway set of phrase files, clips and manifest."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = pathlib.Path(folder.name)
        self.output = root / "phrases"
        self.output.mkdir()
        modules = root / "modules"
        modules.mkdir()
        self.demo = root / "Demo.xcconfig"
        self.demo.write_text("GEMINI_VOICE = Kore\n", encoding="utf-8")
        secrets = root / "Secrets.xcconfig"
        secrets.write_text(f"GEMINI_API_KEY = {FAKE_KEY}\n", encoding="utf-8")
        protocol = root / "adult_arrest.v1.json"
        protocol.write_text(json.dumps({"states": [state("call_911", "setup", ["call_911"], 5)]}), encoding="utf-8")
        (modules / "limb.json").write_text(json.dumps({"states": [state("limb_start", "flow", ["limb_possible"], 6)]}), encoding="utf-8")
        self.texts = {"call_911": "Call 911 now, on speaker.", "triage_ask": "Tell me what's happening.", "limb_possible": "Possible broken bone. Keep it as found."}
        core = root / "phrases.v1.json"
        core.write_text(json.dumps({"phrases": [{"id": i, "text": t} for i, t in self.texts.items()]}), encoding="utf-8")
        self.lengths = {"call_911": 2.0, "triage_ask": 1.5, "limb_possible": 2.5}
        self.urlopen = mock.MagicMock(side_effect=AssertionError("unexpected network call"))
        self.printed = []
        for patcher in [
            mock.patch.multiple(rp, ROOT=root, PHRASES=core, MODULES=modules, OUTPUT=self.output,
                                DEMO_CONFIG=self.demo, SECRETS=secrets, _api_key=None, _last_request=0.0),
            mock.patch.object(vp, "PROTOCOL", protocol),
            mock.patch.object(rp.urllib.request, "urlopen", self.urlopen),
            mock.patch.object(rp.time, "sleep"),
            mock.patch("builtins.print", side_effect=lambda *items: self.printed.append(" ".join(map(str, items)))),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def render(self, voice="Kore"):
        clips = {}
        for phrase_id, text in self.texts.items():
            rp.write_wav(self.output / f"{phrase_id}.wav", tone(length=self.lengths[phrase_id], level=8000))
            clips[phrase_id] = rp.record(text, "gemini", MODEL, voice, self.lengths[phrase_id])
        (self.output / "manifest.json").write_text(json.dumps({"render_version": 1, "clips": clips}), encoding="utf-8")

    def run_main(self, *arguments):
        self.printed.clear()
        with mock.patch.object(sys, "argv", ["verify_phrases.py", *arguments]):
            try:
                vp.main()
            except SystemExit as exit:
                return exit.code
        return 0

    def heard(self, transcripts):
        def respond(request, timeout, context):
            body = json.loads(request.data)
            self.assertNotIn("Call 911", json.dumps(body))
            return FakeResponse({"candidates": [{"content": {"parts": [{"text": transcripts.pop(0)}]}}]})
        self.urlopen.side_effect = respond

    def test_offline_checks_pass_on_a_good_set_without_key_or_network(self):
        self.render()
        with mock.patch.object(rp, "load_api_key", side_effect=AssertionError("no key offline")):
            self.assertEqual(self.run_main("--no-transcribe"), 0)
        self.urlopen.assert_not_called()
        self.assertIn("ok   limb_start", "\n".join(self.printed))

    def test_a_budget_miss_fails(self):
        self.lengths["limb_possible"] = 5.2  # + 0.9 s overhang > 6
        self.render()
        self.assertEqual(self.run_main("--no-transcribe"), 1)
        self.assertIn("budget limb_start", "\n".join(self.printed))

    def test_a_manifest_voice_other_than_gemini_voice_fails(self):
        self.render(voice="Orus")
        self.assertEqual(self.run_main("--no-transcribe", "--voice", "Orus"), 1)
        report = "\n".join(self.printed)
        self.assertIn("isn't GEMINI_VOICE (Kore)", report)
        self.assertIn("manifest voice isn't GEMINI_VOICE (Kore) for: call_911, limb_possible, triage_ask", report)

    def test_a_stale_or_missing_clip_fails(self):
        self.render()
        (self.output / "triage_ask.wav").unlink()
        self.assertEqual(self.run_main("--no-transcribe"), 1)
        self.assertIn("triage_ask: missing", "\n".join(self.printed))

    def test_transcripts_are_scored_and_cached(self):
        self.render()
        self.heard(["Call nine one one now, on speaker.", "Tell me what's happening.", "Possible broken bone. Keep it as found."])
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.urlopen.call_count, 3)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.urlopen.call_count, 3, "cached by clip sha256")

    def test_a_reply_with_no_text_is_asked_again_next_run(self):
        self.render()
        replies = [
            {"candidates": []},
            {"candidates": [{"content": {"parts": [{"text": "Tell me what's happening."}]}}]},
            {"candidates": [{"content": {"parts": [{"text": "Possible broken bone. Keep it as found."}]}}]},
            {"candidates": [{"content": {"parts": [{"text": "Call nine one one now, on speaker."}]}}]},
        ]
        self.urlopen.side_effect = lambda request, timeout, context: FakeResponse(replies.pop(0))
        self.assertEqual(self.run_main(), 1, "no speech heard, this run")
        self.assertEqual(self.urlopen.call_count, 3)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.urlopen.call_count, 4, "only the one with no answer is asked again")
        cached = json.loads((self.output / "verify.json").read_text(encoding="utf-8"))["transcripts"]
        self.assertTrue(all(entry["transcript"] for entry in cached.values()))

    def test_a_wrong_transcript_fails(self):
        self.render()
        self.heard(["Call nine eleven now, on speaker.", "Tell me what's happening.", "Possible broken bone. Keep it as found."])
        self.assertEqual(self.run_main(), 1)
        self.assertIn("FAIL call_911", "\n".join(self.printed))


if __name__ == "__main__":
    unittest.main()
