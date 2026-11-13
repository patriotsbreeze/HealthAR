#!/bin/bash
# Fails if a build transcript would carry the Gemini key. See SAFETY.md: "never logged".
# Builds a throwaway copy with a made-up key in Secrets.xcconfig, the path the real key takes, so
# no real key and no file in this repo is involved. From clean, so it takes a few minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/healthai-keycheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SENTINEL="NOTAREALKEY$RANDOM$RANDOM"
COPY="$WORK/repo"
LOG="$WORK/build.log"

rsync -a --exclude .git --exclude .build --exclude .swiftpm --exclude '*.xcodeproj' \
  --exclude Config/Secrets.xcconfig --exclude App/Resources "$ROOT/" "$COPY/"
printf 'GEMINI_API_KEY = %s\n' "$SENTINEL" > "$COPY/Config/Secrets.xcconfig"
(cd "$COPY" && xcodegen generate >/dev/null)

if ! xcodebuild -project "$COPY/HealthAI.xcodeproj" -scheme HealthAIDemo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO build >"$LOG" 2>&1; then
  tail -20 "$LOG"
  echo "error: the build failed, so the key check says nothing."
  exit 1
fi

# A clean transcript means nothing unless the key really was in this build.
PLIST="$WORK/dd/Build/Products/Debug-iphonesimulator/HealthAISim.app/Info.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :GeminiAPIKey' "$PLIST")" != "$SENTINEL" ]]; then
  echo "error: the test key never reached the build, so the key check says nothing."
  exit 1
fi

if hits=$(grep -c "$SENTINEL" "$LOG"); then
  echo "error: the key appears on $hits line(s) of the build transcript:"
  grep -n "$SENTINEL" "$LOG" | sed "s/$SENTINEL/<test key>/g" | cut -c1-160
  exit 1
fi
echo "OK: key not in the build transcript ($(wc -l <"$LOG" | tr -d ' ') lines checked)."
