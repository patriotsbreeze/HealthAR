#!/usr/bin/env python3
"""Run with `python3 tools/test_render_phrases.py`. The stale-clip pass deletes files, so whatever it sees has to be whole.

No test here touches the network or the real key: urlopen is patched wherever a request could go out.
"""
import array
import base64
import io
import json
import math
import os
import pathlib
import pickle
import shutil
import ssl
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import wave
from unittest import mock

import render_phrases

FAKE_KEY = "AIzaFAKE-TEST-KEY-1234567890"
TOOLS = pathlib.Path(__file__).resolve().parent


class StaleClipTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = pathlib.Path(folder.name)
        self.core = root / "phrases.v1.json"
        self.modules = root / "modules"
        output = root / "phrases"
        output.mkdir()
        self.clip = output / "kept.wav"
        self.clip.write_bytes(b"clip")
        self.stale = output / "stale.wav"
        self.stale.write_bytes(b"clip")

        for patcher in [
            mock.patch.multiple(render_phrases, ROOT=root, PHRASES=self.core, MODULES=self.modules, OUTPUT=output),
            mock.patch.object(render_phrases, "choose_voice", return_value="Voice"),
            mock.patch.object(render_phrases, "render", return_value=1.0),
            mock.patch.object(sys, "argv", ["render_phrases.py"]),
            mock.patch("builtins.print"),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_core(self, document):
        self.core.write_text(json.dumps(document), encoding="utf-8")

    def write_module(self, name, document):
        self.modules.mkdir(exist_ok=True)
        (self.modules / f"{name}.json").write_text(json.dumps(document), encoding="utf-8")

    def expect_exit_keeping_clips(self):
        with self.assertRaises(SystemExit):
            render_phrases.main()
        self.assertTrue(self.clip.exists())
        self.assertTrue(self.stale.exists())

    def test_no_modules_folder_renders_core_alone(self):
        self.write_core({"phrases": [{"id": "kept", "text": "Hello."}]})
        render_phrases.main()
        self.assertTrue(self.clip.exists())
        self.assertFalse(self.stale.exists(), "the pass still runs on a whole set")

    def test_a_module_with_no_phrases_is_fine(self):
        self.write_core({"phrases": [{"id": "kept", "text": "Hello."}]})
        self.write_module("empty", {"states": []})
        render_phrases.main()
        self.assertTrue(self.clip.exists())

    def test_a_duplicate_id_deletes_nothing(self):
        self.write_core({"phrases": [{"id": "kept", "text": "Hello."}]})
        self.write_module("clash", {"phrases": [{"id": "kept", "text": "Again."}]})
        self.expect_exit_keeping_clips()

    def test_core_without_its_key_deletes_nothing(self):
        self.write_core({})
        self.expect_exit_keeping_clips()

    def test_core_with_an_empty_list_deletes_nothing(self):
        self.write_core({"phrases": []})
        self.expect_exit_keeping_clips()

    def test_core_with_the_wrong_shape_deletes_nothing(self):
        self.write_core([])
        self.expect_exit_keeping_clips()

    def test_a_module_that_doesnt_parse_deletes_nothing(self):
        self.write_core({"phrases": [{"id": "kept", "text": "Hello."}]})
        self.modules.mkdir()
        (self.modules / "bad.json").write_text("not json", encoding="utf-8")
        self.expect_exit_keeping_clips()


# Helpers


def tone(before=0.0, length=0.5, after=0.0, level=8000, rate=24_000):
    samples = array.array("h", [0] * int(before * rate))
    samples.extend(int(level * math.sin(2 * math.pi * 440 * n / rate)) for n in range(int(length * rate)))
    samples.extend([0] * int(after * rate))
    return samples


def wav_bytes(samples, rate=24_000, channels=1):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as clip:
        clip.setnchannels(channels)
        clip.setsampwidth(2)
        clip.setframerate(rate)
        clip.writeframes(samples.tobytes())
    return buffer.getvalue()


def interactions_response(blob, mime="audio/wav"):
    return {"steps": [
        {"type": "user_input", "content": [{"type": "text", "text": "Hello."}]},
        {"type": "model_output", "content": [{"type": "audio", "mime_type": mime, "data": base64.b64encode(blob).decode()}]},
    ]}


class FakeResponse:
    def __init__(self, document):
        self.body = json.dumps(document).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self.body


def http_error(code, body=""):
    return urllib.error.HTTPError("https://example.test", code, "error", {}, io.BytesIO(body.encode()))


class NetworkSafeTest(unittest.TestCase):
    """A fake key, no pacing waits, and a urlopen that fails loudly unless a test scripts it."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = pathlib.Path(folder.name)
        self.secrets = self.root / "Secrets.xcconfig"
        self.secrets.write_text(f"// Example\nGEMINI_API_KEY = {FAKE_KEY}\n", encoding="utf-8")
        self.demo = self.root / "Demo.xcconfig"
        self.demo.write_text("GEMINI_VOICE = Kore\n", encoding="utf-8")
        self.urlopen = mock.MagicMock(side_effect=AssertionError("unexpected network call"))
        self.sleep = mock.MagicMock()
        for patcher in [
            mock.patch.multiple(render_phrases, SECRETS=self.secrets, DEMO_CONFIG=self.demo, _api_key=None, _last_request=0.0),
            mock.patch.object(render_phrases.urllib.request, "urlopen", self.urlopen),
            mock.patch.object(render_phrases.time, "sleep", self.sleep),
            mock.patch("builtins.print"),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)


# The key


class ApiKeyTests(NetworkSafeTest):
    def test_every_format_is_redacted(self):
        key = render_phrases.ApiKey(FAKE_KEY)
        for text in [repr(key), str(key), f"{key}", f"{key!r}", "%s" % key, "{}".format(key), repr([key]), repr({"k": key})]:
            self.assertNotIn(FAKE_KEY, text)
        self.assertEqual(str(key), "[redacted]")
        self.assertFalse(hasattr(key, "__dict__"))
        with self.assertRaises(TypeError):
            pickle.dumps(key)

    def test_only_the_header_carries_it(self):
        key = render_phrases.ApiKey(FAKE_KEY)
        self.assertEqual(key.headers(), {"x-goog-api-key": FAKE_KEY})
        self.assertEqual(key.scrub(f"bad key {FAKE_KEY} here"), "bad key <key> here")

    def test_read_setting_matches_the_readme_awk(self):
        path = self.root / "settings.xcconfig"
        cases = [
            (f"GEMINI_API_KEY   =   {FAKE_KEY}  \n", FAKE_KEY),
            (f"// GEMINI_API_KEY = commented\nGEMINI_API_KEY={FAKE_KEY}\n", FAKE_KEY),
            ("GEMINI_API_KEY =\n", None),
            ("GEMINI_API_KEY = $(SOMETHING)\n", None),
            ("GEMINI_API_KEY_OLD = x\n", None),
            ("  GEMINI_API_KEY = indented\n", None),
            ("GEMINI_API_KEY = first\nGEMINI_API_KEY = second\n", "second"),
        ]
        for text, expected in cases:
            path.write_text(text, encoding="utf-8")
            self.assertEqual(render_phrases.read_setting(path, "GEMINI_API_KEY"), expected, text)
        self.assertIsNone(render_phrases.read_setting(self.root / "missing.xcconfig", "GEMINI_API_KEY"))

    def test_the_key_is_loaded_lazily_and_redacted(self):
        self.assertIsNone(render_phrases._api_key)
        key = render_phrases.load_api_key()
        self.assertEqual(key.headers()["x-goog-api-key"], FAKE_KEY)
        self.assertEqual(f"{key}", "[redacted]")

    def test_a_missing_key_exits_without_any_value(self):
        for text in ["GEMINI_API_KEY =\n", "GEMINI_API_KEY = $(X)\n", ""]:
            self.secrets.write_text(text, encoding="utf-8")
            render_phrases._api_key = None
            with self.assertRaises(SystemExit) as raised:
                render_phrases.load_api_key()
            self.assertIn("No GEMINI_API_KEY", str(raised.exception.code))


# What gets sent


class SpokenTextTests(unittest.TestCase):
    def test_pronunciations_reach_the_tts_only(self):
        cases = {
            "Call 911 now, on speaker.": "Call 9-1-1 now, on speaker.",
            "Have them find an AED.": "Have them find an A-E-D.",
            "Two AEDs here.": "Two A-E-Ds here.",
            "Wait for EMS.": "Wait for E-M-S.",
            "Start CPR.": "Start C-P-R.",
            "Chew and swallow one 325 mg aspirin, or two 81 mg.": "Chew and swallow one 325 milligrams aspirin, or two 81 milligrams.",
            "Push hard, at least two inches.": "Push hard, at least two inches.",
        }
        for text, spoken in cases.items():
            self.assertEqual(render_phrases.spoken_text(text), spoken)

    def test_style_follows_the_kind_of_line(self):
        styles = render_phrases.STYLES
        self.assertEqual(render_phrases.style_for("Are they breathing normally?"), styles["question"])
        self.assertEqual(render_phrases.style_for("Correction. I am an AI, not a doctor or nurse."), styles["correction"])
        self.assertEqual(render_phrases.style_for("Someone else here? Have them call 911."), styles["command"])
        self.assertEqual(styles["command"], "Calm, firm and decisive, with quiet authority. Brisk, steady pace.")
        for style in styles.values():
            self.assertNotIn("doctor", style.lower())

    def test_the_fingerprint_covers_text_voice_model_and_engine(self):
        base = render_phrases.fingerprint("Push hard.", "gemini", "m1", "Kore")
        self.assertEqual(base, render_phrases.fingerprint("Push hard.", "gemini", "m1", "Kore"))
        for changed in [
            render_phrases.fingerprint("Push harder.", "gemini", "m1", "Kore"),
            render_phrases.fingerprint("Push hard.", "gemini", "m2", "Kore"),
            render_phrases.fingerprint("Push hard.", "gemini", "m1", "Orus"),
            render_phrases.fingerprint("Push hard.", "say", None, "Kore"),
        ]:
            self.assertNotEqual(base, changed)
        with mock.patch.object(render_phrases, "RENDER_VERSION", 99):
            self.assertNotEqual(base, render_phrases.fingerprint("Push hard.", "gemini", "m1", "Kore"))


class GeminiRequestTests(unittest.TestCase):
    TEXT = "Call 911 now, on speaker. If someone is with you, have them call."

    def test_interactions_body_keeps_style_out_of_the_text(self):
        body = render_phrases.interactions_body(self.TEXT, "Kore", "gemini-3.8-flash-tts")
        self.assertEqual(body, {
            "model": "gemini-3.8-flash-tts",
            "input": [{"type": "user_input", "content": [{
                "type": "text",
                "text": "Call 9-1-1 now, on speaker. If someone is with you, have them call.",
                "annotations": [{"type": "speech_metadata", "style": render_phrases.STYLES["command"]}],
            }]}],
            "response_format": {"type": "audio", "mime_type": "audio/wav", "sample_rate": 24_000},
            "generation_config": {"speech_config": [{"voice": "Kore"}]},
        })

    def test_generate_content_body_uses_per_part_speech_metadata(self):
        body = render_phrases.generate_content_body("Are they breathing normally?", "Orus")
        part = body["contents"][0]["parts"][0]
        self.assertEqual(part["text"], "Are they breathing normally?")
        self.assertEqual(part["speech_metadata"], {"style": render_phrases.STYLES["question"]})
        self.assertEqual(body["generationConfig"]["responseModalities"], ["AUDIO"])
        self.assertEqual(body["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"]["voiceName"], "Orus")

    def test_urls_never_carry_a_key(self):
        interactions, _ = render_phrases.request_for(self.TEXT, "Kore", "gemini-3.8-flash-tts", "interactions")
        legacy, _ = render_phrases.request_for(self.TEXT, "Kore", "gemini-3.1-flash-tts-preview", "generate-content")
        self.assertEqual(interactions, "https://generativelanguage.googleapis.com/v1beta/interactions")
        self.assertEqual(legacy, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent")
        for url in [interactions, legacy]:
            self.assertNotIn("key=", url)

    def test_find_audio_reads_both_response_shapes(self):
        steps = interactions_response(b"ABC")
        self.assertEqual(render_phrases.find_audio(steps), ("QUJD", "audio/wav"))
        candidates = {"candidates": [{"content": {"parts": [
            {"text": "ignored"},
            {"inlineData": {"mimeType": "audio/L16;codec=pcm;rate=24000", "data": "QUJD"}},
        ]}}]}
        self.assertEqual(render_phrases.find_audio(candidates), ("QUJD", "audio/L16;codec=pcm;rate=24000"))
        self.assertIsNone(render_phrases.find_audio({"steps": [{"type": "model_output", "content": [{"type": "text", "text": "no"}]}]}))

    def test_a_wav_is_unwrapped_once(self):
        samples = tone(length=0.1)
        pcm, rate, channels, width = render_phrases.to_pcm(wav_bytes(samples), "audio/wav")
        self.assertEqual((rate, channels, width), (24_000, 1, 2))
        self.assertEqual(pcm, samples.tobytes(), "no header bytes inside the audio")

    def test_raw_l16_takes_its_rate_from_the_mime_type(self):
        pcm, rate, channels, width = render_phrases.to_pcm(b"\x01\x00\x02\x00", "audio/L16;codec=pcm;rate=16000")
        self.assertEqual((pcm, rate, channels, width), (b"\x01\x00\x02\x00", 16_000, 1, 2))
        self.assertEqual(render_phrases.to_pcm(b"\x01\x00", "audio/l16")[1], 24_000)
        with self.assertRaises(render_phrases.AudioFormatError):
            render_phrases.to_pcm(b"\x00\x01", "audio/mpeg")

    def test_parse_wav_reads_extensible_and_streamed_headers(self):
        pcm = tone(length=0.01).tobytes()
        fmt = (
            (0xFFFE).to_bytes(2, "little") + (1).to_bytes(2, "little") + (24_000).to_bytes(4, "little")
            + (48_000).to_bytes(4, "little") + (2).to_bytes(2, "little") + (16).to_bytes(2, "little")
            + (22).to_bytes(2, "little") + (16).to_bytes(2, "little") + (4).to_bytes(4, "little")
            + (1).to_bytes(2, "little") + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
        )
        blob = b"RIFF" + (0xFFFFFFFF).to_bytes(4, "little") + b"WAVE" + b"fmt " + len(fmt).to_bytes(4, "little") + fmt
        blob += b"data" + (0xFFFFFFFF).to_bytes(4, "little") + pcm
        self.assertEqual(render_phrases.parse_wav(blob), (pcm, 24_000, 1, 2))


# HTTP


class RetryTests(NetworkSafeTest):
    def post(self):
        return render_phrases.post_json("https://example.test/v1beta/interactions", {"a": 1}, render_phrases.load_api_key())

    def test_a_429_waits_its_retry_delay_then_succeeds(self):
        retry = json.dumps({"error": {"code": 429, "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "1.5s"}]}})
        self.urlopen.side_effect = [http_error(429, retry), FakeResponse({"ok": True})]
        self.assertEqual(self.post(), {"ok": True})
        self.assertEqual(self.urlopen.call_count, 2)
        self.assertIn(mock.call(1.5), self.sleep.call_args_list)

    def test_the_key_goes_in_a_header_never_the_url(self):
        self.urlopen.side_effect = [FakeResponse({"ok": True})]
        self.post()
        request = self.urlopen.call_args[0][0]
        self.assertEqual(request.get_header("X-goog-api-key"), FAKE_KEY)
        self.assertNotIn(FAKE_KEY, request.full_url)
        self.assertNotIn(FAKE_KEY, request.data.decode())

    def test_steady_503s_give_up_after_the_attempts(self):
        self.urlopen.side_effect = [http_error(503) for _ in range(render_phrases.MAX_ATTEMPTS)]
        with self.assertRaises(SystemExit) as raised:
            self.post()
        self.assertIn("HTTP 503", str(raised.exception.code))
        self.assertEqual(self.urlopen.call_count, render_phrases.MAX_ATTEMPTS)

    def test_a_400_exits_at_once_with_the_key_scrubbed(self):
        self.urlopen.side_effect = [http_error(400, f'{{"error": "API key {FAKE_KEY} not valid"}}')]
        with self.assertRaises(SystemExit) as raised:
            self.post()
        message = str(raised.exception.code)
        self.assertNotIn(FAKE_KEY, message)
        self.assertNotIn("AIza", message)
        self.assertIn("<key>", message)
        self.assertEqual(self.urlopen.call_count, 1)

    def test_a_certificate_failure_is_not_retried(self):
        self.urlopen.side_effect = [urllib.error.URLError(ssl.SSLCertVerificationError("certificate verify failed"))]
        with self.assertRaises(SystemExit):
            self.post()
        self.assertEqual(self.urlopen.call_count, 1)

    def test_a_dropped_connection_is_retried(self):
        self.urlopen.side_effect = [urllib.error.URLError(ConnectionResetError()), FakeResponse({"ok": True})]
        self.assertEqual(self.post(), {"ok": True})

    def test_a_response_with_no_audio_is_asked_again(self):
        samples = tone(length=0.4)
        self.urlopen.side_effect = [FakeResponse({"steps": []}), FakeResponse(interactions_response(wav_bytes(samples)))]
        result, source, resampled = render_phrases.synthesize("Push hard.", "Kore", "gemini-3.8-flash-tts", "interactions")
        self.assertEqual(len(result), len(samples))
        self.assertEqual(source, ("audio/wav", 24_000, 1, 2))
        self.assertFalse(resampled)
        self.assertEqual(self.urlopen.call_count, 2)


# Audio


class AudioTests(NetworkSafeTest):
    RATE = 24_000

    def test_trim_keeps_a_short_lead_and_tail(self):
        trimmed = render_phrases.trim_silence(tone(before=0.5, length=0.5, after=1.0))
        expected = render_phrases.TRIM_LEAD_S + 0.5 + render_phrases.TRIM_TAIL_S
        self.assertAlmostEqual(len(trimmed) / self.RATE, expected, delta=0.011)
        self.assertEqual(trimmed[0], 0, "faded in")
        self.assertEqual(trimmed[-1], 0, "faded out")

    def test_trim_leaves_a_silent_clip_alone(self):
        silence = array.array("h", [0] * 2400)
        self.assertEqual(render_phrases.trim_silence(silence), silence)

    def test_normalize_reaches_the_peak_target_with_gain_capped(self):
        target = 32767 * 10 ** (render_phrases.PEAK_DBFS / 20)
        loud = render_phrases.normalize_peak(tone(level=8000))
        self.assertAlmostEqual(render_phrases.peak_of(loud), target, delta=2)
        quiet = render_phrases.normalize_peak(tone(level=1000))
        self.assertLessEqual(render_phrases.peak_of(quiet), 4000)
        self.assertGreater(render_phrases.peak_of(quiet), 3990)

    def test_write_wav_is_24k_16_bit_mono_and_leaves_no_temp_file(self):
        target = self.root / "x.wav"
        render_phrases.write_wav(target, tone(length=0.2))
        with wave.open(str(target), "rb") as clip:
            self.assertEqual((clip.getframerate(), clip.getsampwidth(), clip.getnchannels()), (24_000, 2, 1))
        self.assertEqual([path.name for path in self.root.glob("*.tmp")], [])
        self.assertAlmostEqual(render_phrases.clip_seconds(target), 0.2, places=3)

    def test_clip_ok_rejects_anything_but_the_app_format(self):
        bad = self.root / "bad.wav"
        bad.write_bytes(b"clip")
        self.assertFalse(render_phrases.clip_ok(bad))
        slow = self.root / "slow.wav"
        slow.write_bytes(wav_bytes(tone(length=0.1, rate=16_000), rate=16_000))
        self.assertFalse(render_phrases.clip_ok(slow))
        self.assertFalse(render_phrases.clip_ok(self.root / "missing.wav"))

    @unittest.skipUnless(os.path.exists(render_phrases.AFCONVERT), "needs afconvert")
    def test_another_rate_is_resampled_through_afconvert(self):
        stereo = array.array("h")
        for value in tone(length=0.5, rate=48_000):
            stereo.extend([value, value])
        self.urlopen.side_effect = [FakeResponse(interactions_response(wav_bytes(stereo, rate=48_000, channels=2)))]
        samples, source, resampled = render_phrases.synthesize("Push hard.", "Kore", "gemini-3.8-flash-tts", "interactions")
        self.assertTrue(resampled)
        self.assertEqual(source[1:], (48_000, 2, 2))
        self.assertAlmostEqual(len(samples) / self.RATE, 0.5, delta=0.02)


class ChooseVoiceTests(NetworkSafeTest):
    def test_gemini_voices_are_checked_against_the_prebuilt_list(self):
        self.assertEqual(render_phrases.choose_voice("kore", "gemini"), "Kore")
        with self.assertRaises(SystemExit) as raised:
            render_phrases.choose_voice("Nope", "gemini")
        self.assertIn("Kore (Firm)", str(raised.exception.code))

    def test_the_default_is_gemini_voice_in_demo_xcconfig(self):
        self.demo.write_text('#include? "Secrets.xcconfig"\nGEMINI_VOICE = Orus\n', encoding="utf-8")
        self.assertEqual(render_phrases.choose_voice(None, "gemini"), "Orus")
        self.demo.unlink()
        self.assertEqual(render_phrases.choose_voice(None, "gemini"), "Kore")

    def test_the_repo_voice_is_a_prebuilt_one(self):
        repo_voice = render_phrases.read_setting(TOOLS.parent / "Config" / "Demo.xcconfig", "GEMINI_VOICE")
        self.assertIn(repo_voice, render_phrases.GEMINI_VOICES)


class SayEngineTests(NetworkSafeTest):
    def test_say_runs_exactly_as_before(self):
        def fake_say(arguments, check):
            target = pathlib.Path(arguments[arguments.index("-o") + 1])
            target.write_bytes(wav_bytes(tone(length=0.3)))
            return subprocess.CompletedProcess(arguments, 0)

        with mock.patch.object(render_phrases.subprocess, "run", side_effect=fake_say) as run:
            seconds = render_phrases.render("hello", "Hello.", "Samantha", self.root)
        self.assertAlmostEqual(seconds, 0.3, places=3)
        arguments = run.call_args[0][0]
        self.assertEqual(arguments, [
            "say", "-v", "Samantha", "-f", mock.ANY, "-o", str(self.root / "hello.wav"),
            "--file-format=WAVE", "--data-format=LEI16@24000", "--channels=1",
        ])
        self.urlopen.assert_not_called()


# Manifest, --only, --check


class ManifestTests(NetworkSafeTest):
    def setUp(self):
        super().setUp()
        self.core = self.root / "phrases.v1.json"
        self.modules = self.root / "modules"
        self.output = self.root / "phrases"
        self.output.mkdir()
        self.write_core([("a", "Push hard."), ("b", "Are they breathing?")])
        (self.output / "orphan.wav").write_bytes(wav_bytes(tone(length=0.1)))
        self.voice = "Kore"
        self.rendered = []

        def fake_render(phrase_id, text, voice, directory, engine="say", model=None, api=None):
            self.rendered.append(phrase_id)
            render_phrases.write_wav(pathlib.Path(directory) / f"{phrase_id}.wav", tone(length=0.25))
            return 0.25

        for patcher in [
            mock.patch.multiple(render_phrases, ROOT=self.root, PHRASES=self.core, MODULES=self.modules, OUTPUT=self.output),
            mock.patch.object(render_phrases, "choose_voice", side_effect=lambda requested, engine="say": requested or self.voice),
            mock.patch.object(render_phrases, "render", side_effect=fake_render),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_core(self, phrases):
        self.core.write_text(json.dumps({"phrases": [{"id": i, "text": t} for i, t in phrases]}), encoding="utf-8")

    def run_main(self, *arguments):
        self.rendered = []
        with mock.patch.object(sys, "argv", ["render_phrases.py", *arguments]):
            render_phrases.main()
        return self.rendered

    def run_check(self):
        with mock.patch.object(render_phrases, "load_api_key", side_effect=AssertionError("no key for --check")):
            with self.assertRaises(SystemExit) as raised:
                self.run_main("--check")
        self.urlopen.assert_not_called()
        return raised.exception.code

    def manifest(self):
        return json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))

    def test_unchanged_clips_are_kept(self):
        self.assertEqual(self.run_main(), ["a", "b"])
        self.assertFalse((self.output / "orphan.wav").exists())
        self.assertEqual(self.run_main(), [])
        self.assertEqual(self.run_main("--force"), ["a", "b"])

    def test_the_manifest_records_what_made_each_clip(self):
        self.run_main()
        entry = self.manifest()["clips"]["b"]
        self.assertEqual(entry["sha256"], render_phrases.fingerprint("Are they breathing?", "gemini", render_phrases.GEMINI_MODEL, "Kore"))
        self.assertEqual(entry["text"], "Are they breathing?")
        self.assertEqual((entry["engine"], entry["model"], entry["voice"]), ("gemini", render_phrases.GEMINI_MODEL, "Kore"))
        self.assertEqual(entry["style"], render_phrases.STYLES["question"])
        self.assertEqual(entry["seconds"], 0.25)
        self.assertEqual(self.manifest()["render_version"], render_phrases.RENDER_VERSION)

    def test_changed_text_renders_only_that_clip(self):
        self.run_main()
        self.write_core([("a", "Push hard and fast."), ("b", "Are they breathing?")])
        self.assertEqual(self.run_main(), ["a"])

    def test_a_changed_voice_renders_everything(self):
        self.run_main()
        self.voice = "Orus"
        self.assertEqual(self.run_main(), ["a", "b"])
        self.assertEqual(self.manifest()["clips"]["a"]["voice"], "Orus")

    def test_a_corrupt_manifest_counts_as_empty(self):
        self.run_main()
        (self.output / "manifest.json").write_text("{not json", encoding="utf-8")
        self.assertEqual(self.run_main(), ["a", "b"])
        (self.output / "manifest.json").write_text('{"clips": []}', encoding="utf-8")
        self.assertEqual(self.run_main(), ["a", "b"])

    def test_only_renders_those_and_never_runs_the_stale_pass(self):
        self.assertEqual(self.run_main("--only", "b"), ["b"])
        self.assertTrue((self.output / "orphan.wav").exists())
        self.assertEqual(list(self.manifest()["clips"]), ["b"])
        self.run_main()
        self.assertEqual(self.run_main("--only", "a", "--force"), ["a"])
        self.assertEqual(sorted(self.manifest()["clips"]), ["a", "b"])

    def test_an_unknown_only_id_renders_nothing(self):
        with self.assertRaises(SystemExit):
            self.run_main("--only", "a,nope")
        self.assertEqual(self.rendered, [])

    def test_a_full_run_drops_entries_for_phrases_that_are_gone(self):
        self.run_main()
        self.write_core([("a", "Push hard.")])
        self.run_main()
        self.assertEqual(list(self.manifest()["clips"]), ["a"])
        self.assertFalse((self.output / "b.wav").exists())

    def test_check_passes_on_a_whole_matching_set(self):
        self.run_main()
        self.assertEqual(self.run_check(), 0)

    def test_check_fails_on_missing_stale_or_bad_clips_without_key_or_network(self):
        self.run_main()
        self.write_core([("a", "Push hard and fast."), ("b", "Are they breathing?"), ("c", "New line.")])
        (self.output / "b.wav").write_bytes(b"clip")
        printed = []
        with mock.patch("builtins.print", side_effect=lambda *items: printed.append(" ".join(map(str, items)))):
            self.assertEqual(self.run_check(), 1)
        report = "\n".join(printed)
        self.assertIn("a: stale, text changed", report)
        self.assertIn("b: bad", report)
        self.assertIn("c: missing", report)
        self.assertEqual(self.rendered, [], "--check renders nothing")

    def test_check_fails_when_the_voice_is_not_gemini_voice(self):
        self.run_main()
        self.voice = "Orus"
        self.assertEqual(self.run_check(), 1)

    def test_a_failed_render_keeps_every_clip_and_the_manifest(self):
        self.run_main()
        before = {path.name: path.read_bytes() for path in self.output.iterdir()}
        self.write_core([("a", "Push hard and fast."), ("b", "Changed too.")])
        with mock.patch.object(render_phrases, "render", side_effect=SystemExit("HTTP 503")):
            with self.assertRaises(SystemExit):
                self.run_main()
        self.assertEqual({path.name: path.read_bytes() for path in self.output.iterdir()}, before)


# The Release build phase


class CheckScriptTests(unittest.TestCase):
    """tools/check_phrase_clips.sh against a throwaway copy of the files it reads."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = pathlib.Path(folder.name)
        (self.root / "tools").mkdir()
        for name in ["render_phrases.py", "check_phrase_clips.sh"]:
            shutil.copy2(TOOLS / name, self.root / "tools" / name)
        (self.root / "clinical" / "modules").mkdir(parents=True)
        (self.root / "Config").mkdir()
        (self.root / "Config" / "Demo.xcconfig").write_text("GEMINI_VOICE = Kore\n", encoding="utf-8")
        self.output = self.root / "App" / "Resources" / "phrases"
        self.output.mkdir(parents=True)
        self.write_phrases({"push": "Push hard."}, {"limb_ask": "Heavy bleeding?"})

    def write_phrases(self, core, module):
        (self.root / "clinical" / "phrases.v1.json").write_text(
            json.dumps({"phrases": [{"id": i, "text": t} for i, t in core.items()]}), encoding="utf-8")
        (self.root / "clinical" / "modules" / "limb.json").write_text(
            json.dumps({"phrases": [{"id": i, "text": t} for i, t in module.items()]}), encoding="utf-8")
        self.texts = dict(core, **module)

    def render_all(self, voice="Kore"):
        clips = {}
        for phrase_id, text in self.texts.items():
            render_phrases.write_wav(self.output / f"{phrase_id}.wav", tone(length=0.3))
            clips[phrase_id] = render_phrases.record(text, "gemini", render_phrases.GEMINI_MODEL, voice, 0.3)
        (self.output / "manifest.json").write_text(json.dumps({"render_version": 1, "clips": clips}), encoding="utf-8")

    def run_script(self, configuration="Release"):
        environment = {key: value for key, value in os.environ.items() if key not in ("SRCROOT", "CONFIGURATION")}
        if configuration:
            environment["CONFIGURATION"] = configuration
        result = subprocess.run(
            ["/bin/bash", str(self.root / "tools" / "check_phrase_clips.sh")],
            capture_output=True, text=True, env=environment, cwd=str(self.root),
        )
        return result.returncode, result.stdout + result.stderr

    def test_debug_builds_skip_it(self):
        code, output = self.run_script("Debug")
        self.assertEqual(code, 0)
        self.assertIn("skipped", output)

    def test_release_fails_with_no_clips(self):
        code, output = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("push: missing", output)
        self.assertIn("limb_ask: missing", output)
        self.assertIn("error: phrase clips are missing or stale", output)

    def test_release_passes_on_a_whole_current_set(self):
        self.render_all()
        self.assertEqual(self.run_script()[0], 0)
        self.assertEqual(self.run_script(configuration=None)[0], 0, "by hand, with no CONFIGURATION")

    def test_a_module_phrase_without_a_clip_fails(self):
        self.render_all()
        (self.output / "limb_ask.wav").unlink()
        code, output = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("limb_ask: missing", output)

    def test_changed_text_or_voice_fails(self):
        self.render_all()
        self.write_phrases({"push": "Push hard and fast."}, {"limb_ask": "Heavy bleeding?"})
        code, output = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("push: stale, text changed", output)

        self.render_all(voice="Orus")
        code, output = self.run_script()
        self.assertEqual(code, 1)
        self.assertIn("voice Orus, wanted Kore", output)

    def test_the_phase_is_in_project_yml_with_env_vars_hidden(self):
        project = (TOOLS.parent / "project.yml").read_text(encoding="utf-8")
        start = project.index("- name: Check phrase clips")
        block = project[start:project.index("- name:", start + 1)]
        self.assertIn("showEnvVars: false", block)
        self.assertIn("tools/check_phrase_clips.sh", block)
        self.assertIn("- name: Copy phrase clips", project, "the copy phase stays")


if __name__ == "__main__":
    unittest.main()
