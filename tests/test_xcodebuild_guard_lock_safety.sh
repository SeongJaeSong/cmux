#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/scripts/xcodebuild-guard.sh"

XCODEBUILD_LOCK_DIR="$TMP_DIR/cmux-xcodebuild.lock"
XCODEBUILD_LOCK_STALE_GRACE_SECONDS=60

TOOLCHAINS="swift-snapshot-testing"
build_xcodebuild_env_cmd
env_output="$(printf '%s\n' "${XCODEBUILD_ENV_CMD[@]}")"

if ! grep -Fq "TOOLCHAINS=$TOOLCHAINS" <<<"$env_output"; then
  echo "FAIL: sanitized xcodebuild env must preserve TOOLCHAINS"
  exit 1
fi

mkdir "$XCODEBUILD_LOCK_DIR"

if prune_stale_xcodebuild_lock; then
  echo "FAIL: a freshly created lock without metadata must be preserved briefly"
  exit 1
fi

if [[ ! -d "$XCODEBUILD_LOCK_DIR" ]]; then
  echo "FAIL: recent metadata-free lock should remain on disk"
  exit 1
fi

touch -t 200001010000 "$XCODEBUILD_LOCK_DIR"
XCODEBUILD_LOCK_STALE_GRACE_SECONDS=0

if ! prune_stale_xcodebuild_lock; then
  echo "FAIL: an old metadata-free lock should be pruned"
  exit 1
fi

if [[ -d "$XCODEBUILD_LOCK_DIR" ]]; then
  echo "FAIL: pruning an old metadata-free lock should remove it from disk"
  exit 1
fi

mkdir "$XCODEBUILD_LOCK_DIR"
write_xcodebuild_guard_metadata owner_pid "$$"
write_xcodebuild_guard_metadata owner_command "$(ps -p $$ -o command=)"

if prune_stale_xcodebuild_lock; then
  echo "FAIL: a live owner process with matching command must keep the lock"
  exit 1
fi

rm -rf "$XCODEBUILD_LOCK_DIR"
mkdir "$XCODEBUILD_LOCK_DIR"
write_xcodebuild_guard_metadata owner_pid "$$"
write_xcodebuild_guard_metadata owner_command "definitely-not-the-current-command"

if ! prune_stale_xcodebuild_lock; then
  echo "FAIL: a reused owner PID with a different command should be pruned"
  exit 1
fi

if [[ -d "$XCODEBUILD_LOCK_DIR" ]]; then
  echo "FAIL: pruning a reused owner PID lock should remove it from disk"
  exit 1
fi

mkdir "$XCODEBUILD_LOCK_DIR"
write_xcodebuild_guard_metadata child_pid "$$"

if ! prune_stale_xcodebuild_lock; then
  echo "FAIL: a reused child PID that is not xcodebuild should be pruned"
  exit 1
fi

if [[ -d "$XCODEBUILD_LOCK_DIR" ]]; then
  echo "FAIL: pruning a reused child PID lock should remove it from disk"
  exit 1
fi

echo "PASS: xcodebuild guard preserves TOOLCHAINS and prunes only truly stale locks"
