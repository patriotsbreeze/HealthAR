#!/bin/bash
# Fails if a real emergency number can be dialed from this build. See SAFETY.md, invariant 9.
# Runs by hand, in CI, and as an Xcode build phase, where it also scans the built app.
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

SCHEMES='(tel|telprompt|sms|smsto|facetime|facetime-audio|callto)'
PATTERN="${SCHEMES}:(//)?\+?[0-9]{0,2}[-. ]?(911|112|999|000|110|119|118|933)([^0-9]|\$)"
SCAN=(App Packages Config clinical contracts)
status=0

# Test sources are excluded: they assert these URLs are rejected, and they never ship.
if hits=$(grep -RInE "$PATTERN" "${SCAN[@]}" --exclude-dir=Tests --exclude-dir=.build --exclude=Info.plist 2>/dev/null); then
  echo "error: emergency dial URL found in source:"
  echo "$hits"
  status=1
fi

# Only DialPolicy may build a dial URL, so the allowlist can't be bypassed.
if hits=$(grep -RInE "\"${SCHEMES}:|[Ss]cheme[[:space:]]*[:=][[:space:]]*\"${SCHEMES}\"" App Packages --include='*.swift' --exclude-dir=Tests --exclude-dir=.build --exclude=DialPolicy.swift 2>/dev/null); then
  echo "error: dial URL built outside DialPolicy.swift:"
  echo "$hits"
  status=1
fi

# Nothing here opens a URL today, and anything that starts to should be looked at first.
if hits=$(grep -RInE 'UIApplication\.shared\.open|openURL' App Packages --include='*.swift' --exclude-dir=Tests --exclude-dir=.build 2>/dev/null); then
  echo "error: URL opened from app code:"
  echo "$hits"
  status=1
fi

# Every Mach-O in the app. In Debug the main executable is a stub, and the code is in a dylib.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" && -d "$TARGET_BUILD_DIR/$WRAPPER_NAME" ]]; then
  scanned=0
  while IFS= read -r -d '' file; do
    [[ "$(file -b "$file")" == Mach-O* ]] || continue
    scanned=$((scanned + 1))
    if hits=$(strings "$file" | grep -E "$PATTERN"); then
      echo "error: emergency dial URL found in $file:"
      echo "$hits"
      status=1
    fi
  done < <(find "$TARGET_BUILD_DIR/$WRAPPER_NAME" -type f -print0)
  if [[ $scanned -eq 0 ]]; then
    echo "error: no binary found to scan in $TARGET_BUILD_DIR/$WRAPPER_NAME"
    status=1
  else
    echo "Scanned $scanned binaries in $WRAPPER_NAME."
  fi
fi

[[ $status -eq 0 ]] && echo "OK: no emergency dial URL found."
exit $status
