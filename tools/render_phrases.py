#!/usr/bin/env python3
"""Renders clinical/phrases.v1.json and clinical/modules/*.json to App/Resources/phrases/<id>.wav, 24 kHz 16-bit mono.

Gemini TTS is the default engine. It needs GEMINI_API_KEY in Config/Secrets.xcconfig and a network,
and speaks in GEMINI_VOICE from Config/Demo.xcconfig, the voice both Live sessions use. Its clips
and manifest.json are committed, so every build ships the same voice without a key.

`--engine say` renders offline with macOS `say`. That output is for private rehearsal only. Older
macOS licenses restrict public or commercial use, so never commit those clips.

Runs on the Xcode build's /usr/bin/python3 (3.9) as well, since `--check` gates Release builds.
"""
import argparse
import array
import base64
import hashlib
import json
import math
import os
import pathlib
import random
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
PHRASES = ROOT / "clinical" / "phrases.v1.json"
MODULES = ROOT / "clinical" / "modules"
OUTPUT = ROOT / "App" / "Resources" / "phrases"
SECRETS = ROOT / "Config" / "Secrets.xcconfig"
DEMO_CONFIG = ROOT / "Config" / "Demo.xcconfig"
PREFERRED_VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Tessa"]
SAMPLE_RATE = 24_000

GEMINI_MODEL = "gemini-3.8-flash-tts"
API_BASE = "https://generativelanguage.googleapis.com/v1beta"
# The speech generation guide documents only Interactions for 3.8 TTS. The model page also lists
# generateContent with per-part speech_metadata, so that stays behind --api.
APIS = ("interactions", "generate-content")
DEFAULT_GEMINI_VOICE = "Kore"
GEMINI_VOICES = {
    "Zephyr": "Bright", "Puck": "Upbeat", "Charon": "Informative", "Kore": "Firm",
    "Fenrir": "Excitable", "Leda": "Youthful", "Orus": "Firm", "Aoede": "Breezy",
    "Callirrhoe": "Easy-going", "Autonoe": "Bright", "Enceladus": "Breathy", "Iapetus": "Clear",
    "Umbriel": "Easy-going", "Algieba": "Smooth", "Despina": "Smooth", "Erinome": "Clear",
    "Algenib": "Gravelly", "Rasalgethi": "Informative", "Laomedeia": "Upbeat", "Achernar": "Soft",
    "Alnilam": "Firm", "Schedar": "Even", "Gacrux": "Mature", "Pulcherrima": "Forward",
    "Achird": "Friendly", "Zubenelgenubi": "Casual", "Vindemiatrix": "Gentle", "Sadachbia": "Lively",
    "Sadaltager": "Knowledgeable", "Sulafat": "Warm",
}

# Delivery goes in speech_metadata.style only. 3.8 reads `text` as a verbatim transcript, so a
# direction placed there would be spoken. Short on purpose: long notes make the voice drift.
STYLES = {
    "command": "Calm, firm and decisive, with quiet authority. Brisk, steady pace.",
    "question": "Calm, firm, direct question. Brisk, steady pace.",
    "correction": "Calm, firm, matter-of-fact. Brisk, steady pace.",
}

# What the TTS hears, never what the phrase files or the screen say. 911 is never "nine eleven".
SPOKEN_FORMS = [
    (re.compile(r"\b911\b"), "9-1-1"),
    (re.compile(r"\bAEDs\b"), "A-E-Ds"),
    (re.compile(r"\bAED\b"), "A-E-D"),
    (re.compile(r"\bEMS\b"), "E-M-S"),
    (re.compile(r"\bCPR\b"), "C-P-R"),
    (re.compile(r"\b(\d+) ?mg\b"), r"\1 milligrams"),
]

# Bump when the audio processing changes, so every clip reads as stale.
RENDER_VERSION = 1
TRIM_LEAD_S = 0.06
TRIM_TAIL_S = 0.15
TRIM_FLOOR_DBFS = -45.0
TRIM_RELATIVE_DB = -40.0
FADE_S = 0.005
PEAK_DBFS = -1.5
MAX_GAIN = 4.0

MAX_ATTEMPTS = 5
CONTENT_ATTEMPTS = 3
TIMEOUT_S = 60
MIN_INTERVAL_S = 1.0
RETRY_CODES = {429, 500, 502, 503, 504}
AFCONVERT = "/usr/bin/afconvert"

SMOKE_PHRASE = "call_911"
AUDITION_PHRASES = ["call_911", "hands_center", "limb_danger_ask"]


def load_phrases():
    """Exits on an unreadable file or a duplicate id, so the stale-clip pass only ever sees the full set."""
    phrases = []
    owners = {}
    for source in [PHRASES, *sorted(MODULES.glob("*.json"))]:
        try:
            document = json.loads(source.read_text(encoding="utf-8"))
            # A module may bring no phrases of its own. Core always has them.
            listed = document["phrases"] if source == PHRASES else document.get("phrases", [])
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            sys.exit(f"{source.name}: {error!r}")
        if source == PHRASES and not listed:
            sys.exit(f"{source.name}: no phrases")
        for phrase in listed:
            if phrase["id"] in owners:
                sys.exit(f"Duplicate phrase id {phrase['id']!r} in {source.name}, already in {owners[phrase['id']]}")
            owners[phrase["id"]] = source.name
            phrases.append(phrase)
    return phrases


# Settings and the key


class ApiKey:
    """Holds the key so nothing formats it by accident. Only headers() hands the value out."""

    __slots__ = ("_value",)

    def __init__(self, value):
        self._value = value

    def __repr__(self):
        return "[redacted]"

    __str__ = __repr__

    def __format__(self, spec):
        return "[redacted]"

    def __reduce__(self):
        raise TypeError("ApiKey can't be pickled")

    def headers(self):
        return {"x-goog-api-key": self._value}

    def scrub(self, text):
        return text.replace(self._value, "<key>") if self._value else text


def read_setting(path, name):
    """The README's `awk -F' *= *' '/^NAME/{print $2}'`, stricter: the name must be followed by `=`.
    The last assignment wins, as in an xcconfig. Empty and unexpanded `$(...)` values are None."""
    try:
        lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    pattern = re.compile(rf"^{re.escape(name)}[ \t]*=[ \t]*(.*?)\s*$")
    value = None
    for line in lines:
        match = pattern.match(line)
        if match:
            value = match.group(1)
    if not value or value.startswith("$("):
        return None
    return value


_api_key = None


def load_api_key():
    """Read only when a request is about to go out, so `--check`, `--engine say` and tests need no key."""
    global _api_key
    if _api_key is None:
        value = read_setting(SECRETS, "GEMINI_API_KEY")
        if value is None:
            sys.exit("No GEMINI_API_KEY in Config/Secrets.xcconfig. Fill it in, or render with --engine say.")
        _api_key = ApiKey(value)
    return _api_key


def configured_voice():
    return read_setting(DEMO_CONFIG, "GEMINI_VOICE") or DEFAULT_GEMINI_VOICE


def installed_english_voices():
    listing = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    voices = []
    for line in listing.splitlines():
        match = re.match(r"^(.+?)\s+(en_[A-Z]{2})\s+#", line)
        if match:
            voices.append(match.group(1).strip())
    return voices


def choose_voice(requested, engine="say"):
    if engine == "gemini":
        wanted = requested or configured_voice()
        for name in GEMINI_VOICES:
            if name.lower() == wanted.lower():
                return name
        listed = ", ".join(f"{name} ({GEMINI_VOICES[name]})" for name in GEMINI_VOICES)
        sys.exit(f"Voice {wanted!r} is not a Gemini prebuilt voice. Voices: {listed}")
    voices = installed_english_voices()
    if requested:
        if requested not in voices:
            sys.exit(f"Voice {requested!r} is not installed. English voices: {', '.join(voices)}")
        return requested
    for voice in PREFERRED_VOICES:
        if voice in voices:
            return voice
    sys.exit("No preferred English voice is installed. Pass --voice, or add one in System Settings.")


# What gets sent


def style_for(text):
    stripped = text.strip()
    if stripped.startswith("Correction."):
        return STYLES["correction"]
    if stripped.endswith("?"):
        return STYLES["question"]
    return STYLES["command"]


def spoken_text(text):
    for pattern, spoken in SPOKEN_FORMS:
        text = pattern.sub(spoken, text)
    return text


def fingerprint(text, engine, model, voice):
    """Everything that changes the audio. `say` gets the text as written and no style."""
    gemini = engine == "gemini"
    settings = {
        "render_version": RENDER_VERSION,
        "engine": engine,
        "model": model if gemini else None,
        "voice": voice,
        "style": style_for(text) if gemini else None,
        "spoken": spoken_text(text) if gemini else text,
    }
    return hashlib.sha256(json.dumps(settings, sort_keys=True).encode("utf-8")).hexdigest()


def interactions_body(text, voice, model):
    return {
        "model": model,
        "input": [{
            "type": "user_input",
            "content": [{
                "type": "text",
                "text": spoken_text(text),
                "annotations": [{"type": "speech_metadata", "style": style_for(text)}],
            }],
        }],
        "response_format": {"type": "audio", "mime_type": "audio/wav", "sample_rate": SAMPLE_RATE},
        "generation_config": {"speech_config": [{"voice": voice}]},
    }


def generate_content_body(text, voice):
    return {
        "contents": [{
            "role": "user",
            "parts": [{"text": spoken_text(text), "speech_metadata": {"style": style_for(text)}}],
        }],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
    }


def request_for(text, voice, model, api):
    if api == "generate-content":
        return f"{API_BASE}/models/{model}:generateContent", generate_content_body(text, voice)
    return f"{API_BASE}/interactions", interactions_body(text, voice, model)


# HTTP


_last_request = 0.0
_tls = None
SYSTEM_CA_FILE = "/etc/ssl/cert.pem"


def tls_context():
    """python.org's Python ships without CA certificates until its Install Certificates step runs,
    so fall back to the bundle macOS keeps. Verification stays on either way."""
    global _tls
    if _tls is None:
        _tls = ssl.create_default_context()
        if not _tls.get_ca_certs() and os.path.exists(SYSTEM_CA_FILE):
            paths = ssl.get_default_verify_paths()
            if not any(path and os.path.exists(path) for path in (paths.cafile, paths.capath)):
                _tls.load_verify_locations(cafile=SYSTEM_CA_FILE)
    return _tls


def retry_delay(body):
    """google.rpc.RetryInfo's retryDelay, such as "7s" or "1.5s", when the error carries one."""
    try:
        details = json.loads(body).get("error", {}).get("details", [])
        for detail in details:
            if str(detail.get("@type", "")).endswith("google.rpc.RetryInfo"):
                return min(120.0, float(str(detail["retryDelay"]).rstrip("s")))
    except (ValueError, TypeError, AttributeError, KeyError):
        pass
    return None


def post_json(url, body, key, label="Gemini TTS"):
    """The key goes in a header, never the URL. Error text is scrubbed before it's cut, so a cut
    can't leave part of the key behind."""
    global _last_request
    payload = json.dumps(body).encode("utf-8")
    for attempt in range(MAX_ATTEMPTS):
        wait = _last_request + MIN_INTERVAL_S - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _last_request = time.monotonic()
        headers = {"Content-Type": "application/json"}
        headers.update(key.headers())
        request = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        last = attempt == MAX_ATTEMPTS - 1
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_S, context=tls_context()) as response:
                text = response.read().decode("utf-8")
            try:
                return json.loads(text)
            except ValueError:
                sys.exit(f"{label} sent a response that isn't JSON.")
        except urllib.error.HTTPError as error:
            detail = key.scrub(error.read().decode("utf-8", "replace"))
            if error.code not in RETRY_CODES or last:
                sys.exit(f"{label} returned HTTP {error.code}: {detail[:300]}")
            delay = retry_delay(detail)
            if delay is None:
                delay = min(60.0, 2 ** attempt + random.uniform(0, 1))
            print(f"  HTTP {error.code}, retrying in {delay:.1f} s")
        except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError) as error:
            reason = getattr(error, "reason", error)
            # A certificate problem won't fix itself on a retry.
            if last or isinstance(reason, ssl.SSLError):
                sys.exit(f"Could not reach {label}: {key.scrub(str(reason))[:200]}")
            delay = min(60.0, 2 ** attempt + random.uniform(0, 1))
            print(f"  {type(error).__name__}, retrying in {delay:.1f} s")
        time.sleep(delay)
    sys.exit(f"{label}: out of attempts.")


def find_audio(document):
    """Base64 audio and its MIME type, from Interactions' steps[].content[] or generateContent's
    candidates[].content.parts[].inlineData. The last one wins, as in the guide's jq filter."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            mime = node.get("mime_type") or node.get("mimeType") or ""
            if isinstance(node.get("data"), str) and (node.get("type") == "audio" or str(mime).startswith("audio/")):
                found.append((node["data"], str(mime)))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(document)
    return found[-1] if found else None


# Audio


class AudioFormatError(Exception):
    pass


def parse_wav(blob):
    """(pcm, rate, channels, width) from a RIFF WAVE. Reads extensible headers too, which Python
    3.9's wave module can't, and a data size past the end, as streamed WAV headers have."""
    if len(blob) < 12 or blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        raise AudioFormatError("not a RIFF WAVE")
    offset = 12
    shape = None
    while offset + 8 <= len(blob):
        tag = blob[offset:offset + 4]
        size = int.from_bytes(blob[offset + 4:offset + 8], "little")
        start = offset + 8
        if tag == b"fmt ":
            fmt = blob[start:start + size]
            if len(fmt) < 16:
                raise AudioFormatError("short fmt chunk")
            code = int.from_bytes(fmt[0:2], "little")
            if code == 0xFFFE and len(fmt) >= 26:
                code = int.from_bytes(fmt[24:26], "little")
            if code != 1:
                raise AudioFormatError(f"WAVE format {code}, not PCM")
            channels = int.from_bytes(fmt[2:4], "little")
            rate = int.from_bytes(fmt[4:8], "little")
            width = int.from_bytes(fmt[14:16], "little") // 8
            shape = (rate, channels, width)
        elif tag == b"data":
            if shape is None:
                raise AudioFormatError("data before fmt")
            return (blob[start:start + size],) + shape
        offset = start + size + size % 2
    raise AudioFormatError("no data chunk")


def to_pcm(blob, mime):
    """Gemini 3.8 returns WAV on unary calls, and earlier models raw little-endian L16. A WAV is
    unwrapped once, so a header never ends up inside the audio."""
    if blob[:4] == b"RIFF":
        return parse_wav(blob)
    lowered = mime.lower()
    if "l16" in lowered or "pcm" in lowered:
        rate = re.search(r"rate=(\d+)", lowered)
        channels = re.search(r"channels=(\d+)", lowered)
        return blob, int(rate.group(1)) if rate else SAMPLE_RATE, int(channels.group(1)) if channels else 1, 2
    raise AudioFormatError(f"unsupported audio type {mime or 'unknown'}")


def to_samples(pcm):
    samples = array.array("h")
    samples.frombytes(pcm[:len(pcm) - len(pcm) % 2])
    if sys.byteorder == "big":
        samples.byteswap()
    return samples


def write_pcm_wav(path, pcm, rate, channels, width):
    with wave.open(str(path), "wb") as clip:
        clip.setnchannels(channels)
        clip.setsampwidth(width)
        clip.setframerate(rate)
        clip.writeframes(pcm)


def resample(pcm, rate, channels, width):
    """Through afconvert, since Python 3.13 dropped audioop."""
    with tempfile.TemporaryDirectory() as folder:
        source = pathlib.Path(folder) / "in.wav"
        target = pathlib.Path(folder) / "out.wav"
        write_pcm_wav(source, pcm, rate, channels, width)
        subprocess.run(
            [AFCONVERT, "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(source), str(target)],
            check=True, capture_output=True,
        )
        converted = parse_wav(target.read_bytes())
    if converted[1:] != (SAMPLE_RATE, 1, 2):
        raise AudioFormatError(f"afconvert gave {converted[1:]}")
    return converted[0]


def peak_of(samples):
    return max((abs(value) for value in samples), default=0)


def dbfs(level):
    return 20 * math.log10(level / 32768) if level > 0 else float("-inf")


def trim_silence(samples, rate=SAMPLE_RATE):
    """Keeps a short lead and tail around the speech, with a 5 ms fade at each cut."""
    if not samples:
        return samples
    threshold = max(peak_of(samples) * 10 ** (TRIM_RELATIVE_DB / 20), 32768 * 10 ** (TRIM_FLOOR_DBFS / 20))
    window = max(1, int(rate * FADE_S))
    loud = [start for start in range(0, len(samples), window) if peak_of(samples[start:start + window]) >= threshold]
    if not loud:
        return samples
    begin = max(0, loud[0] - int(rate * TRIM_LEAD_S))
    end = min(len(samples), loud[-1] + window + int(rate * TRIM_TAIL_S))
    trimmed = samples[begin:end]
    fade = min(window, len(trimmed) // 2)
    for index in range(fade):
        trimmed[index] = int(trimmed[index] * index / fade)
        trimmed[-1 - index] = int(trimmed[-1 - index] * index / fade)
    return trimmed


def normalize_peak(samples):
    """To PEAK_DBFS, with gain capped so a quiet clip's noise isn't pulled up with it."""
    peak = peak_of(samples)
    if peak == 0:
        return samples
    gain = min(32767 * 10 ** (PEAK_DBFS / 20) / peak, MAX_GAIN)
    return array.array("h", (max(-32768, min(32767, int(round(value * gain)))) for value in samples))


def write_wav(path, samples, rate=SAMPLE_RATE):
    """Through a temp file in the same folder, so a failed render never leaves half a clip."""
    path = pathlib.Path(path)
    data = array.array("h", samples)
    if sys.byteorder == "big":
        data.byteswap()
    handle, temp = tempfile.mkstemp(prefix=f".{path.stem}.", suffix=".tmp", dir=str(path.parent))
    os.close(handle)
    try:
        write_pcm_wav(temp, data.tobytes(), rate, 1, 2)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def clip_seconds(path):
    """None for a missing clip or one that isn't 24 kHz, 16-bit mono."""
    try:
        pcm, rate, channels, width = parse_wav(pathlib.Path(path).read_bytes())
    except (OSError, AudioFormatError):
        return None
    if (rate, channels, width) != (SAMPLE_RATE, 1, 2) or not pcm:
        return None
    return len(pcm) / (SAMPLE_RATE * 2)


def clip_ok(path):
    return clip_seconds(path) is not None


# Rendering


def synthesize(text, voice, model, api):
    """One Gemini call, as 24 kHz mono samples, untrimmed. Also says what came back."""
    url, body = request_for(text, voice, model, api)
    for attempt in range(CONTENT_ATTEMPTS):
        audio = find_audio(post_json(url, body, load_api_key()))
        if audio is None:
            print(f"  no audio in the response, attempt {attempt + 1} of {CONTENT_ATTEMPTS}")
            continue
        data, mime = audio
        try:
            pcm, rate, channels, width = to_pcm(base64.b64decode(data), mime)
        except (ValueError, AudioFormatError) as error:
            sys.exit(f"Gemini TTS audio: {error}")
        source = (mime or "audio/wav", rate, channels, width)
        resampled = (rate, channels, width) != (SAMPLE_RATE, 1, 2)
        if resampled:
            pcm = resample(pcm, rate, channels, width)
        return to_samples(pcm), source, resampled
    sys.exit("Gemini TTS sent no audio.")


def longest_plausible(text):
    """A clip far past this has likely gained words, or read its style aloud."""
    return len(text.split()) / 2.5 * 1.6 + 1.0


def render_gemini(phrase_id, text, voice, directory, model=GEMINI_MODEL, api=APIS[0]):
    target = pathlib.Path(directory) / f"{phrase_id}.wav"
    for attempt in range(CONTENT_ATTEMPTS):
        samples, _, _ = synthesize(text, voice, model, api)
        samples = normalize_peak(trim_silence(samples))
        seconds = len(samples) / SAMPLE_RATE
        if 0.25 <= seconds <= longest_plausible(text):
            break
        print(f"  {phrase_id}: {seconds:.2f} s is out of range, attempt {attempt + 1} of {CONTENT_ATTEMPTS}")
    else:
        print(f"  warning: {phrase_id} kept at {seconds:.2f} s. Listen to it, and run tools/verify_phrases.py.")
    write_wav(target, samples)
    return seconds


def render(phrase_id, text, voice, directory, engine="say", model=None, api=APIS[0]):
    if engine == "gemini":
        return render_gemini(phrase_id, text, voice, directory, model or GEMINI_MODEL, api)
    target = directory / f"{phrase_id}.wav"
    # Text goes through a file, so a phrase can never be read as a command-line option.
    with tempfile.NamedTemporaryFile("w", suffix=".txt", encoding="utf-8") as script:
        script.write(text)
        script.flush()
        subprocess.run(
            [
                "say", "-v", voice, "-f", script.name, "-o", str(target),
                "--file-format=WAVE", f"--data-format=LEI16@{SAMPLE_RATE}", "--channels=1",
            ],
            check=True,
        )
    with wave.open(str(target), "rb") as clip:
        shape = (clip.getframerate(), clip.getsampwidth(), clip.getnchannels())
        if shape != (SAMPLE_RATE, 2, 1) or clip.getnframes() == 0:
            sys.exit(f"{target.name}: expected {SAMPLE_RATE} Hz, 16-bit, mono audio, got {shape}")
        return clip.getnframes() / clip.getframerate()


# Manifest


def manifest_path():
    return OUTPUT / "manifest.json"


def load_manifest():
    """Anything unreadable counts as empty, so the worst case is a full render."""
    try:
        document = json.loads(manifest_path().read_text(encoding="utf-8"))
        clips = document["clips"]
        if isinstance(clips, dict) and all(isinstance(entry, dict) for entry in clips.values()):
            return {"render_version": RENDER_VERSION, "clips": dict(clips)}
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {"render_version": RENDER_VERSION, "clips": {}}


def save_manifest(manifest):
    path = manifest_path()
    text = json.dumps({"render_version": RENDER_VERSION, "clips": manifest["clips"]}, indent=2, sort_keys=True) + "\n"
    handle, temp = tempfile.mkstemp(prefix=".manifest.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            file.write(text)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def record(text, engine, model, voice, seconds):
    gemini = engine == "gemini"
    return {
        "sha256": fingerprint(text, engine, model, voice),
        "text": text,
        "engine": engine,
        "model": model if gemini else None,
        "voice": voice,
        "style": style_for(text) if gemini else None,
        "seconds": round(seconds, 3),
    }


def clip_status(phrase, entry, engine, model, voice, directory=None):
    """("ok" | "missing" | "bad" | "unrecorded" | "stale", why)."""
    path = pathlib.Path(directory or OUTPUT) / f"{phrase['id']}.wav"
    if not path.exists():
        return "missing", "no clip"
    if not clip_ok(path):
        return "bad", "not 24 kHz 16-bit mono"
    if not entry:
        return "unrecorded", "not in the manifest"
    if entry.get("sha256") == fingerprint(phrase["text"], engine, model, voice):
        return "ok", ""
    reasons = []
    if entry.get("text") != phrase["text"]:
        reasons.append("text changed")
    if entry.get("engine") != engine:
        reasons.append(f"engine {entry.get('engine')}, wanted {engine}")
    if entry.get("voice") != voice:
        reasons.append(f"voice {entry.get('voice')}, wanted {voice}")
    if engine == "gemini" and entry.get("model") != model:
        reasons.append(f"model {entry.get('model')}, wanted {model}")
    return "stale", ", ".join(reasons) or "render settings changed"


def check(phrases, engine, model, voice):
    """Never needs the key or a network. Returns the number of clips that need a render."""
    manifest = load_manifest()["clips"]
    problems = []
    for phrase in phrases:
        status, why = clip_status(phrase, manifest.get(phrase["id"]), engine, model, voice)
        if status != "ok":
            problems.append(f"  {phrase['id']}: {status}, {why}")
    wanted = {f"{phrase['id']}.wav" for phrase in phrases}
    extra = sorted(path.name for path in OUTPUT.glob("*.wav") if path.name not in wanted) if OUTPUT.exists() else []
    settings = f"{engine}, {model + ', ' if engine == 'gemini' else ''}{voice}"
    if extra:
        print(f"Clips no phrase uses, removed by the next full render: {', '.join(extra)}")
    if problems:
        print(f"{len(problems)} of {len(phrases)} clips don't match their phrase and {settings}:")
        print("\n".join(problems))
        print("Render them with: python3 tools/render_phrases.py")
    else:
        print(f"OK: all {len(phrases)} clips match their phrase and {settings}.")
    return len(problems)


# Smoke and audition


def smoke(phrases, voice, model, api):
    phrase = next((item for item in phrases if item["id"] == SMOKE_PHRASE), phrases[0])
    folder = pathlib.Path(tempfile.mkdtemp(prefix="healthai_tts_smoke_"))
    samples, (mime, rate, channels, width), resampled = synthesize(phrase["text"], voice, model, api)
    raw = len(samples) / SAMPLE_RATE
    finished = normalize_peak(trim_silence(samples))
    target = folder / f"{phrase['id']}.wav"
    write_wav(target, finished)
    print(f"Smoke OK: {api}, {model}, {voice}, phrase {phrase['id']}")
    print(f"  response {mime}, {rate} Hz, {width * 8}-bit, {channels} channel(s){', resampled to 24 kHz mono' if resampled else ''}")
    print(f"  {raw:.2f} s as sent, {len(finished) / SAMPLE_RATE:.2f} s trimmed, peak {dbfs(peak_of(samples)):.1f} dBFS as sent")
    print(f"  clip_ok: {clip_ok(target)}, at {target}")


def audition(phrases, voices, model, api, folder):
    by_id = {phrase["id"]: phrase for phrase in phrases}
    chosen = [by_id[name] for name in AUDITION_PHRASES if name in by_id]
    for voice in voices:
        directory = pathlib.Path(folder) / voice
        directory.mkdir(parents=True, exist_ok=True)
        timings = []
        for phrase in chosen:
            seconds = render_gemini(phrase["id"], phrase["text"], voice, directory, model, api)
            timings.append(f"{phrase['id']} {seconds:.2f} s")
        print(f"{voice} ({GEMINI_VOICES[voice]}): {', '.join(timings)}")
    print(f"Audition clips in {folder}")


# Main


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", choices=["gemini", "say"], default="gemini")
    parser.add_argument("--voice", help="Gemini: a prebuilt voice, default GEMINI_VOICE in Config/Demo.xcconfig. say: an installed macOS voice.")
    parser.add_argument("--model", default=GEMINI_MODEL)
    parser.add_argument("--api", choices=APIS, default=APIS[0], help="Gemini request style. Default: interactions.")
    parser.add_argument("--only", help="Comma-separated phrase ids. Skips the stale-clip pass.")
    parser.add_argument("--force", action="store_true", help="Render even clips that match the manifest.")
    parser.add_argument("--check", action="store_true", help="Report missing or stale clips and exit 1 if any. No key, no network.")
    parser.add_argument("--smoke", action="store_true", help="Render one phrase to a temp folder and report its format.")
    parser.add_argument("--audition", metavar="V1,V2", help="Render a few phrases in each voice, to compare by ear.")
    parser.add_argument("--audition-dir", default=os.environ.get("HEALTHAI_AUDITION_DIR") or os.path.join(tempfile.gettempdir(), "healthai_audition"))
    args = parser.parse_args()

    phrases = load_phrases()
    engine = args.engine
    model = args.model if engine == "gemini" else None

    if args.smoke or args.audition:
        if engine != "gemini":
            sys.exit("--smoke and --audition are for the Gemini engine.")
        if args.smoke:
            smoke(phrases, choose_voice(args.voice, "gemini"), args.model, args.api)
        if args.audition:
            voices = [choose_voice(name.strip(), "gemini") for name in args.audition.split(",") if name.strip()]
            audition(phrases, voices, args.model, args.api, args.audition_dir)
        return

    voice = choose_voice(args.voice, engine)
    if args.check:
        sys.exit(1 if check(phrases, engine, model, voice) else 0)

    selected = phrases
    if args.only:
        wanted = [name.strip() for name in args.only.split(",") if name.strip()]
        known = {phrase["id"] for phrase in phrases}
        unknown = [name for name in wanted if name not in known]
        if unknown:
            sys.exit(f"Unknown phrase id(s): {', '.join(unknown)}")
        selected = [phrase for phrase in phrases if phrase["id"] in wanted]

    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    rendered = kept = 0
    total = 0.0
    for phrase in selected:
        entry = manifest["clips"].get(phrase["id"])
        status, why = clip_status(phrase, entry, engine, model, voice)
        if status == "ok" and not args.force:
            kept += 1
            total += clip_seconds(OUTPUT / f"{phrase['id']}.wav") or 0
            continue
        seconds = render(phrase["id"], phrase["text"], voice, OUTPUT, engine=engine, model=model, api=args.api)
        print(f"{phrase['id']}: {seconds:.2f} s{f' ({why})' if why and status != 'missing' else ''}")
        manifest["clips"][phrase["id"]] = record(phrase["text"], engine, model, voice, seconds)
        save_manifest(manifest)
        rendered += 1
        total += seconds

    # Only on the whole set, so a partial run never deletes another phrase's clip.
    if not args.only:
        wanted = {f"{phrase['id']}.wav" for phrase in phrases}
        for stale in OUTPUT.glob("*.wav"):
            if stale.name not in wanted:
                stale.unlink()
        ids = {phrase["id"] for phrase in phrases}
        manifest["clips"] = {name: entry for name, entry in manifest["clips"].items() if name in ids}
        save_manifest(manifest)

    settings = f"{engine}, {model + ', ' if model else ''}{voice}"
    print(f"Rendered {rendered} and kept {kept} unchanged, with {settings}, {total:.1f} s in total, to {OUTPUT.relative_to(ROOT)}")
    if engine == "gemini" and voice != configured_voice():
        print(f"warning: {voice} isn't GEMINI_VOICE ({configured_voice()}) in Config/Demo.xcconfig, so the Live voice won't match.")
    if engine == "say":
        print("These say clips are for private rehearsal only. Don't commit them.")


if __name__ == "__main__":
    main()
