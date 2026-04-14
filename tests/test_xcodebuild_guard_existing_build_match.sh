#!/usr/bin/env bash
# Regression test for the local xcodebuild concurrency guard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/xcodebuild-guard.sh"

ps() {
  cat <<'EOF'
123 00:10 xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build
124 00:05 /usr/bin/xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release build
125 00:04 xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -configuration Debug test
126 00:02 /usr/bin/xcodebuild -project Other.xcodeproj -scheme cmux -configuration Debug build
EOF
}

output="$(list_running_cmux_xcodebuilds)"

if ! grep -Fq "123 00:10 xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build" <<<"$output"; then
  echo "FAIL: expected plain xcodebuild cmux build to be detected"
  exit 1
fi

if ! grep -Fq "124 00:05 /usr/bin/xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release build" <<<"$output"; then
  echo "FAIL: expected absolute-path xcodebuild cmux build to be detected"
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

echo "PASS: xcodebuild guard matches both plain and absolute-path cmux builds"
