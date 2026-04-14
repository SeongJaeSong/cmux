#!/usr/bin/env bash
set -euo pipefail

source "$PWD/scripts/xcodebuild-guard.sh"
HOST_ARCH="$(uname -m)"

cleanup_reloadp_xcodebuild_state() {
  kill_owned_xcodebuild_child
  release_xcodebuild_lock
}

trap cleanup_reloadp_xcodebuild_state EXIT INT TERM

acquire_xcodebuild_lock "reloadp.sh cwd=$PWD"
wait_for_existing_cmux_xcodebuilds
set +e
"${XCODEBUILD_ENV_CMD[@]}" xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination "platform=macOS,arch=${HOST_ARCH}" CC="$PWD/scripts/clang-xcodebuild-wrapper.sh" build
XCODE_EXIT=$?
release_xcodebuild_lock
set -e
if [[ "$XCODE_EXIT" -ne 0 ]]; then
  exit "$XCODE_EXIT"
fi
pkill -x cmux || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "cmux.app not found in DerivedData" >&2
  exit 1
fi

echo "Release app:"
echo "  ${APP_PATH}"

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"

APP_PROCESS_PATH="${APP_PATH}/Contents/MacOS/cmux"
ATTEMPT=0
MAX_ATTEMPTS=20
while [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; do
  if pgrep -f "$APP_PROCESS_PATH" >/dev/null 2>&1; then
    echo "Release launch status:"
    echo "  running: ${APP_PROCESS_PATH}"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 0.25
done

echo "warning: Release app launch was requested, but no running process was observed for:" >&2
echo "  ${APP_PROCESS_PATH}" >&2
