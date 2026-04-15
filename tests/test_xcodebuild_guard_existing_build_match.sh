#!/usr/bin/env bash
# Regression test for the local xcodebuild concurrency guard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/xcodebuild-guard.sh"

ps() {
  cat <<'EOF'
    123       00:10 xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build
    124       00:05 /usr/bin/xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release build
    125       00:04 xcodebuild -scheme cmux -project /Users/austinwang/My Checkout/cmux1/GhosttyTabs.xcodeproj -configuration Debug build
    126       00:03 xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug test
    127       00:02 /usr/bin/xcodebuild -project Other.xcodeproj -scheme cmux -configuration Debug build
    128       00:01 xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
EOF
}

output="$(list_running_cmux_xcodebuilds)"

if ! grep -Fq "123 00:10 xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build" <<<"$output"; then
  echo "FAIL: expected plain xcodebuild cmux build to be detected"
  exit 1
fi

if ! grep -Fq "124 00:05 /usr/bin/xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release build" <<<"$output"; then
  echo "FAIL: expected /usr/bin/xcodebuild cmux build to be detected"
  exit 1
fi

if ! grep -Fq "125 00:04 xcodebuild -scheme cmux -project /Users/austinwang/My Checkout/cmux1/GhosttyTabs.xcodeproj -configuration Debug build" <<<"$output"; then
  echo "FAIL: expected reordered cmux build with spaces in project path to be detected"
  exit 1
fi

if ! grep -Fq "128 00:01 xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build" <<<"$output"; then
  echo "FAIL: expected cmux build without -project to be detected"
  exit 1
fi

if grep -Fq "cmux-unit" <<<"$output"; then
  echo "FAIL: cmux-unit test builds must not be treated as reload.sh cmux app builds"
  exit 1
fi

if grep -Fq "Other.xcodeproj" <<<"$output"; then
  echo "FAIL: unrelated projects must not be treated as cmux app builds"
  exit 1
fi

XCODEBUILD_GUARD_CHILD_PID="123"
output="$(list_running_cmux_xcodebuilds)"

if grep -Fq "123 00:10" <<<"$output"; then
  echo "FAIL: guard should ignore its own tracked child pid"
  exit 1
fi

if ! grep -Fq "124 00:05" <<<"$output"; then
  echo "FAIL: guard should continue reporting other matching builds"
  exit 1
fi

if ! grep -Fq "125 00:04" <<<"$output"; then
  echo "FAIL: guard should continue reporting reordered project-path builds"
  exit 1
fi

if ! grep -Fq "128 00:01" <<<"$output"; then
  echo "FAIL: guard should continue reporting matching builds without -project"
  exit 1
fi

XCODEBUILD_GUARD_CHILD_PID="456"
XCODEBUILD_LOCK_ACQUIRED=0
release_xcodebuild_lock

if [[ -n "$XCODEBUILD_GUARD_CHILD_PID" ]]; then
  echo "FAIL: releasing without an acquired lock must still clear the tracked child pid"
  exit 1
fi

echo "PASS: xcodebuild guard matches all supported cmux build layouts and clears stale child tracking"
