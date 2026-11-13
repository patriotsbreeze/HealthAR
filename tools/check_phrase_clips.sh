#!/bin/bash
# Fails a Release build when a phrase has no clip, or its clip no longer matches its text, the render
# settings, or GEMINI_VOICE. A missing clip would play in on-device speech, in another voice.
# Debug builds skip it, so a checkout without clips still runs. Runs by hand too, with no
# CONFIGURATION set. Needs no key and no network, and never prints build settings.
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [[ -n "${CONFIGURATION:-}" && "$CONFIGURATION" != "Release" ]]; then
  echo "Phrase clip check skipped: a $CONFIGURATION build."
  exit 0
fi

# The Xcode build's python3, so the check behaves the same in a build and by hand.
if ! "${PYTHON:-/usr/bin/python3}" "$ROOT/tools/render_phrases.py" --check; then
  echo "error: phrase clips are missing or stale. Run python3 tools/render_phrases.py, then python3 tools/verify_phrases.py, and commit the clips."
  exit 1
fi
