#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERIFY_SCREENSHOTS="$SCRIPT_DIR/verify-smoke-screenshots.js"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-cross-theme-transition-smoke-$RUN_ID}"
CYCLE_COUNT="${2:-${CLAWD_NATIVE_TRANSITION_SMOKE_CYCLES:-2}}"
MID_DELAY="${CLAWD_NATIVE_TRANSITION_SMOKE_MID_DELAY:-0.12}"
STABLE_DELAY="${CLAWD_NATIVE_TRANSITION_SMOKE_STABLE_DELAY:-0.75}"
APP_PID=""
CURRENT_LOG=""
CURRENT_PORT=""

cleanup_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    sleep 0.5
  fi
  APP_PID=""
}

cleanup() {
  cleanup_app
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  if [[ -n "$CURRENT_LOG" && -f "$CURRENT_LOG" ]]; then
    echo "--- ClawdNative log tail ---" >&2
    tail -n 80 "$CURRENT_LOG" >&2 || true
  fi
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_command swift
require_command curl
require_command node
require_command osascript
require_command screencapture

if ! [[ "$CYCLE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  fail "cycle count must be a positive integer: $CYCLE_COUNT"
fi

json_bool() {
  if [[ "$1" == "true" ]]; then
    printf "true"
  else
    printf "false"
  fi
}

start_native() {
  local theme="$1"
  local mini_mode="$2"
  local case_dir="$3"
  local prefs_path="$case_dir/prefs.json"
  local runtime_path="$case_dir/runtime.json"
  local log_path="$case_dir/app.log"

  mkdir -p "$case_dir"
  CURRENT_LOG="$log_path"
  cat > "$prefs_path" <<JSON
{
  "positionSaved": true,
  "x": 200,
  "y": 300,
  "theme": "$theme",
  "miniMode": $(json_bool "$mini_mode"),
  "miniEdge": "right",
  "sessionHudEnabled": true,
  "sessionHudPinned": false,
  "soundMuted": true,
  "showDock": false
}
JSON

  cd "$NATIVE_DIR"
  CLAWD_PROJECT_ROOT="$REPO_ROOT" \
  CLAWD_NATIVE_PREFS_PATH="$prefs_path" \
  CLAWD_NATIVE_RUNTIME_PATH="$runtime_path" \
  CLAWD_NATIVE_SKIP_INTEGRATION_SYNC=1 \
  swift run ClawdNative >"$log_path" 2>&1 &
  APP_PID="$!"

  for _ in {1..120}; do
    if [[ -s "$runtime_path" ]]; then
      break
    fi
    sleep 0.25
  done
  [[ -s "$runtime_path" ]] || fail "native runtime file was not written: $runtime_path"

  CURRENT_PORT="$(node -e 'const fs = require("fs"); const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).port; if (!value) process.exit(1); console.log(value);' "$runtime_path")" \
    || fail "could not parse native runtime port"

  for _ in {1..40}; do
    if curl -fsS "http://127.0.0.1:$CURRENT_PORT/sessions" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  curl -fsS "http://127.0.0.1:$CURRENT_PORT/sessions" >/dev/null || fail "native HTTP sessions route did not become ready"
}

current_state() {
  curl -fsS "http://127.0.0.1:$CURRENT_PORT/sessions" \
    | node -e 'const fs = require("fs"); const data = JSON.parse(fs.readFileSync(0, "utf8")); console.log(data.currentState || "");'
}

wait_current_state() {
  local expected="$1"
  local attempts="${2:-80}"
  local actual=""

  for ((i = 0; i < attempts; i += 1)); do
    actual="$(current_state)" || true
    if [[ "$actual" == "$expected" ]]; then
      return 0
    fi
    sleep 0.25
  done
  fail "state did not become $expected; last state: ${actual:-unknown}"
}

post_state() {
  local state="$1"
  local session_id="$2"
  local title="$3"
  local event="$4"
  curl -fsS \
    -X POST "http://127.0.0.1:$CURRENT_PORT/state" \
    -H "Content-Type: application/json" \
    --data "{\"state\":\"$state\",\"session_id\":\"$session_id\",\"event\":\"$event\",\"agent_id\":\"codex\",\"session_title\":\"$title\",\"cwd\":\"/tmp/clawd-native-cross-theme-transition-smoke\"}" \
    >/dev/null || fail "could not inject $state state"
}

capture_current() {
  local theme="$1"
  local mode="$2"
  local phase="$3"
  local screenshot_path="$SMOKE_ROOT/$theme-$mode/$theme-$mode-$phase.png"
  mkdir -p "$(dirname "$screenshot_path")"
  osascript \
    -e 'tell application "System Events" to tell process "ClawdNative" to perform action "AXRaise" of window 1' \
    >/dev/null 2>&1 || true
  sleep 0.08
  screencapture -x "$screenshot_path" || fail "screencapture failed for $theme $mode $phase"
  echo "$screenshot_path"
}

transition_and_capture() {
  local theme="$1"
  local mode="$2"
  local cycle="$3"
  local state="$4"
  local event="$5"
  local expected="$6"
  local session_id="native-$theme-$mode-transition-$cycle"
  local phase="cycle-$cycle-$state"

  post_state "$state" "$session_id" "$theme $mode $state cycle $cycle" "$event"
  sleep "$MID_DELAY"
  capture_current "$theme" "$mode" "$phase-mid"
  wait_current_state "$expected"
  sleep "$STABLE_DELAY"
  capture_current "$theme" "$mode" "$phase-stable"
}

capture_theme_mode() {
  local theme="$1"
  local mode="$2"
  local mini_mode="$3"

  cleanup_app
  start_native "$theme" "$mini_mode" "$SMOKE_ROOT/$theme-$mode-runtime"
  wait_current_state "idle"
  capture_current "$theme" "$mode" "idle-start"

  for ((cycle = 1; cycle <= CYCLE_COUNT; cycle += 1)); do
    transition_and_capture "$theme" "$mode" "$cycle" "working" "PreToolUse" "working"
    transition_and_capture "$theme" "$mode" "$cycle" "notification" "Notification" "notification"
    transition_and_capture "$theme" "$mode" "$cycle" "idle" "Stop" "idle"
  done
}

mkdir -p "$SMOKE_ROOT"

for theme in clawd calico cloudling; do
  capture_theme_mode "$theme" "desktop" "false"
  capture_theme_mode "$theme" "mini" "true"
done

cleanup_app
EXPECTED_IMAGES=$((6 * (1 + CYCLE_COUNT * 6)))
node "$VERIFY_SCREENSHOTS" --min-images "$EXPECTED_IMAGES" "$SMOKE_ROOT" || fail "screenshot verification failed"
echo "Smoke root: $SMOKE_ROOT"
echo "Cycles: $CYCLE_COUNT"
