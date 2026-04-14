#!/usr/bin/env bash

# Shared xcodebuild hardening helpers for local wrapper scripts.
# Xcode 26 can deadlock when multiple builds overlap or when dev-shell
# environment variables leak into xcodebuild/SWBBuildService.

XCODEBUILD_LOCK_DIR_DEFAULT="${TMPDIR:-/tmp}/cmux-xcodebuild.lock"
XCODEBUILD_LOCK_DIR="${XCODEBUILD_LOCK_DIR:-$XCODEBUILD_LOCK_DIR_DEFAULT}"
XCODEBUILD_LOCK_WAIT_SECONDS="${XCODEBUILD_LOCK_WAIT_SECONDS:-2}"
XCODEBUILD_LOCK_ACQUIRED=0
XCODEBUILD_GUARD_CONTEXT=""
XCODEBUILD_GUARD_CHILD_PID=""
XCODEBUILD_GUARD_PATH=""

build_clean_xcodebuild_path() {
  local entry path_value=""
  local seen=":"
  local -a defaults
  local -a current_path_entries
  defaults=(
    /usr/local/bin
    /opt/homebrew/bin
    /usr/bin
    /bin
    /usr/sbin
    /sbin
    /Library/Apple/usr/bin
  )

  append_path_entry() {
    local candidate="$1"
    [[ -n "$candidate" && -d "$candidate" ]] || return 0
    if [[ "$seen" == *":$candidate:"* ]]; then
      return 0
    fi
    seen="${seen}${candidate}:"
    if [[ -n "$path_value" ]]; then
      path_value="${path_value}:$candidate"
    else
      path_value="$candidate"
    fi
  }

  IFS=':' read -r -a current_path_entries <<< "${PATH:-}"
  for entry in "${current_path_entries[@]}"; do
    [[ -n "$entry" ]] || continue
    case "$entry" in
      *"/.codex/"*|\
      *"/@openai/codex/"*|\
      "/Applications/cmux.app/Contents/Resources/bin"|\
      *"/codex.system/bootstrap/"*)
        continue
        ;;
    esac
    append_path_entry "$entry"
  done

  for entry in "${defaults[@]}"; do
    append_path_entry "$entry"
  done

  if [[ -z "$path_value" ]]; then
    path_value="/usr/bin:/bin:/usr/sbin:/sbin"
  fi

  printf '%s\n' "$path_value"
}

build_xcodebuild_env_cmd() {
  local clean_path user_name logname shell_path
  clean_path="$(build_clean_xcodebuild_path)"
  user_name="${USER:-$(id -un)}"
  logname="${LOGNAME:-$user_name}"
  shell_path="${SHELL:-/bin/bash}"
  XCODEBUILD_GUARD_PATH="$clean_path"

  XCODEBUILD_ENV_CMD=(
    env
    -i
    HOME="$HOME"
    PATH="$clean_path"
    TMPDIR="${TMPDIR:-/tmp}"
    USER="$user_name"
    LOGNAME="$logname"
    SHELL="$shell_path"
    LANG="${LANG:-en_US.UTF-8}"
    LC_ALL="${LC_ALL:-C.UTF-8}"
    LC_CTYPE="${LC_CTYPE:-C.UTF-8}"
    TERM=dumb
  )

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    XCODEBUILD_ENV_CMD+=(DEVELOPER_DIR="$DEVELOPER_DIR")
  fi
  if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    XCODEBUILD_ENV_CMD+=(SSH_AUTH_SOCK="$SSH_AUTH_SOCK")
  fi
}

xcodebuild_guard_metadata_path() {
  local name="$1"
  printf '%s/%s\n' "$XCODEBUILD_LOCK_DIR" "$name"
}

write_xcodebuild_guard_metadata() {
  local name="$1"
  local value="$2"
  printf '%s\n' "$value" > "$(xcodebuild_guard_metadata_path "$name")"
}

read_xcodebuild_guard_metadata() {
  local name="$1"
  local path
  path="$(xcodebuild_guard_metadata_path "$name")"
  if [[ -f "$path" ]]; then
    cat "$path"
  fi
}

prune_stale_xcodebuild_lock() {
  local owner_pid child_pid
  owner_pid="$(read_xcodebuild_guard_metadata owner_pid | tr -d '[:space:]')"
  child_pid="$(read_xcodebuild_guard_metadata child_pid | tr -d '[:space:]')"

  if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
    return 1
  fi
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    return 1
  fi

  rm -rf "$XCODEBUILD_LOCK_DIR"
  return 0
}

acquire_xcodebuild_lock() {
  local context="$1"
  local owner_pid owner_context owner_started_at
  XCODEBUILD_GUARD_CONTEXT="$context"

  while ! mkdir "$XCODEBUILD_LOCK_DIR" 2>/dev/null; do
    if prune_stale_xcodebuild_lock; then
      continue
    fi

    owner_pid="$(read_xcodebuild_guard_metadata owner_pid | tr -d '[:space:]')"
    owner_context="$(read_xcodebuild_guard_metadata context | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    owner_started_at="$(read_xcodebuild_guard_metadata started_at | tr '\n' ' ')"

    if [[ -n "$owner_pid" || -n "$owner_context" ]]; then
      echo "Waiting for cmux xcodebuild lock..." >&2
      if [[ -n "$owner_pid" ]]; then
        echo "  owner pid: $owner_pid" >&2
      fi
      if [[ -n "$owner_context" ]]; then
        echo "  owner: $owner_context" >&2
      fi
      if [[ -n "$owner_started_at" ]]; then
        echo "  started: $owner_started_at" >&2
      fi
    else
      echo "Waiting for cmux xcodebuild lock..." >&2
    fi
    sleep "$XCODEBUILD_LOCK_WAIT_SECONDS"
  done

  XCODEBUILD_LOCK_ACQUIRED=1
  write_xcodebuild_guard_metadata owner_pid "$$"
  write_xcodebuild_guard_metadata context "$context"
  write_xcodebuild_guard_metadata started_at "$(date '+%Y-%m-%d %H:%M:%S %z')"
  build_xcodebuild_env_cmd
  write_xcodebuild_guard_metadata path "$XCODEBUILD_GUARD_PATH"
}

list_running_cmux_xcodebuilds() {
  local pid etime command
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pid="${line%% *}"
    line="${line#* }"
    etime="${line%% *}"
    command="${line#* }"
    case "$command" in
      xcodebuild\ -project\ GhosttyTabs.xcodeproj\ -scheme\ cmux\ *|\
      */xcodebuild\ -project\ GhosttyTabs.xcodeproj\ -scheme\ cmux\ *)
        if [[ -n "$XCODEBUILD_GUARD_CHILD_PID" && "$pid" == "$XCODEBUILD_GUARD_CHILD_PID" ]]; then
          continue
        fi
        printf '%s %s %s\n' "$pid" "$etime" "$command"
        ;;
    esac
  done < <(ps -axo pid=,etime=,command=)
}

wait_for_existing_cmux_xcodebuilds() {
  local active_builds
  while true; do
    active_builds="$(list_running_cmux_xcodebuilds)"
    if [[ -z "$active_builds" ]]; then
      return 0
    fi
    echo "Waiting for existing cmux xcodebuild to finish before starting a new one..." >&2
    printf '%s\n' "$active_builds" | sed 's/^/  /' >&2
    sleep "$XCODEBUILD_LOCK_WAIT_SECONDS"
  done
}

note_xcodebuild_child_pid() {
  local child_pid="$1"
  XCODEBUILD_GUARD_CHILD_PID="$child_pid"
  if [[ "$XCODEBUILD_LOCK_ACQUIRED" -eq 1 ]]; then
    write_xcodebuild_guard_metadata child_pid "$child_pid"
  fi
}

release_xcodebuild_lock() {
  local owner_pid
  [[ "$XCODEBUILD_LOCK_ACQUIRED" -eq 1 ]] || return 0
  owner_pid="$(read_xcodebuild_guard_metadata owner_pid | tr -d '[:space:]')"
  if [[ "$owner_pid" == "$$" ]]; then
    rm -rf "$XCODEBUILD_LOCK_DIR"
  fi
  XCODEBUILD_LOCK_ACQUIRED=0
  XCODEBUILD_GUARD_CHILD_PID=""
}

kill_owned_xcodebuild_child() {
  if [[ -n "$XCODEBUILD_GUARD_CHILD_PID" ]] && kill -0 "$XCODEBUILD_GUARD_CHILD_PID" 2>/dev/null; then
    kill "$XCODEBUILD_GUARD_CHILD_PID" 2>/dev/null || true
  fi
}
