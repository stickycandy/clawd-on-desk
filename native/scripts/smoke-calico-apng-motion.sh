#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERIFY_SCREENSHOTS="$SCRIPT_DIR/verify-smoke-screenshots.js"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-calico-apng-motion-$RUN_ID}"
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

start_native() {
  local prefs_path="$SMOKE_ROOT/runtime/prefs.json"
  local runtime_path="$SMOKE_ROOT/runtime/runtime.json"
  local log_path="$SMOKE_ROOT/runtime/app.log"

  mkdir -p "$SMOKE_ROOT/runtime"
  CURRENT_LOG="$log_path"
  cat > "$prefs_path" <<JSON
{
  "positionSaved": true,
  "x": 220,
  "y": 320,
  "theme": "calico",
  "miniMode": false,
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
  local actual=""

  for _ in {1..80}; do
    actual="$(current_state)" || true
    if [[ "$actual" == "$expected" ]]; then
      return 0
    fi
    sleep 0.25
  done
  fail "state did not become $expected; last state: ${actual:-unknown}"
}

post_working() {
  curl -fsS \
    -X POST "http://127.0.0.1:$CURRENT_PORT/state" \
    -H "Content-Type: application/json" \
    --data '{"state":"working","session_id":"native-calico-apng-motion","event":"StateMatrix","agent_id":"codex","session_title":"calico apng motion","display_svg":"clawd-working-juggling.svg","cwd":"/tmp/clawd-native-calico-apng-motion"}' \
    >/dev/null || fail "could not inject working state"
}

capture_window() {
  local output="$1"
  local capture_region=""

  mkdir -p "$(dirname "$output")"
  osascript \
    -e 'tell application "System Events" to tell process "ClawdNative" to perform action "AXRaise" of window 1' \
    >/dev/null 2>&1 || true
  sleep 0.08
  capture_region="$(osascript -e 'tell application "System Events" to tell process "ClawdNative" to get {position, size} of window 1')" \
    || fail "could not resolve ClawdNative window frame"
  capture_region="${capture_region// /}"
  if ! [[ "$capture_region" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
    fail "invalid ClawdNative window frame: $capture_region"
  fi
  screencapture -x -R "$capture_region" "$output" || fail "screencapture failed: $output"
}

mkdir -p "$SMOKE_ROOT"
start_native
post_working
wait_current_state "working"
sleep 2.6
capture_window "$SMOKE_ROOT/calico-working-juggling-a.png"
sleep 1.2
capture_window "$SMOKE_ROOT/calico-working-juggling-b.png"
node "$VERIFY_SCREENSHOTS" \
  --min-images 2 \
  --manifest "$SMOKE_ROOT/manifest.json" \
  --motion-pair "$SMOKE_ROOT/calico-working-juggling-a.png" "$SMOKE_ROOT/calico-working-juggling-b.png" \
  --min-motion-ratio 0.005 \
  "$SMOKE_ROOT" \
  || fail "screenshot or motion verification failed"
cleanup_app
