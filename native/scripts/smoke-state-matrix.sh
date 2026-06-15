#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERIFY_SCREENSHOTS="$SCRIPT_DIR/verify-smoke-screenshots.js"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-state-matrix-smoke-$RUN_ID}"
STABLE_DELAY="${CLAWD_NATIVE_STATE_MATRIX_STABLE_DELAY:-0.75}"
APP_PID=""
CURRENT_LOG=""
CURRENT_PORT=""

DESKTOP_STATES=(
  idle
  thinking
  working
  juggling
  carrying
  attention
  sweeping
  notification
  error
)

MINI_SOURCE_STATES=(
  idle
  thinking
  working
  attention
  notification
  error
)

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
  local theme="$1"
  local mode="$2"
  local state="$3"
  local event="$4"
  local session_id="native-$theme-$mode-state-matrix"
  curl -fsS \
    -X POST "http://127.0.0.1:$CURRENT_PORT/state" \
    -H "Content-Type: application/json" \
    --data "{\"state\":\"$state\",\"session_id\":\"$session_id\",\"event\":\"$event\",\"agent_id\":\"codex\",\"session_title\":\"$theme $mode $state\",\"cwd\":\"/tmp/clawd-native-state-matrix-smoke\"}" \
    >/dev/null || fail "could not inject $state state"
}

capture_current() {
  local theme="$1"
  local mode="$2"
  local state="$3"
  local screenshot_path="$SMOKE_ROOT/$theme-$mode/$theme-$mode-$state.png"
  local capture_region=""
  mkdir -p "$(dirname "$screenshot_path")"
  sleep "$STABLE_DELAY"
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
  screencapture -x -R "$capture_region" "$screenshot_path" || fail "screencapture failed for $theme $mode $state"
  echo "$screenshot_path"
}

capture_state() {
  local theme="$1"
  local mode="$2"
  local state="$3"

  if [[ "$state" != "idle" ]]; then
    post_state "$theme" "$mode" "$state" "StateMatrix"
  fi
  wait_current_state "$state"
  capture_current "$theme" "$mode" "$state"
}

capture_theme_mode() {
  local theme="$1"
  local mode="$2"
  local mini_mode="$3"
  shift 3
  local states=("$@")

  cleanup_app
  start_native "$theme" "$mini_mode" "$SMOKE_ROOT/$theme-$mode-runtime"

  for state in "${states[@]}"; do
    capture_state "$theme" "$mode" "$state"
  done
}

mkdir -p "$SMOKE_ROOT"

for theme in clawd calico cloudling; do
  capture_theme_mode "$theme" "desktop" "false" "${DESKTOP_STATES[@]}"
  capture_theme_mode "$theme" "mini" "true" "${MINI_SOURCE_STATES[@]}"
done

cleanup_app
EXPECTED_IMAGES=$((3 * (${#DESKTOP_STATES[@]} + ${#MINI_SOURCE_STATES[@]})))
node "$VERIFY_SCREENSHOTS" \
  --min-images "$EXPECTED_IMAGES" \
  --manifest "$SMOKE_ROOT/manifest.json" \
  "$SMOKE_ROOT" \
  || fail "screenshot verification failed"
echo "Smoke root: $SMOKE_ROOT"
echo "Images: $EXPECTED_IMAGES"
echo "Manifest: $SMOKE_ROOT/manifest.json"
