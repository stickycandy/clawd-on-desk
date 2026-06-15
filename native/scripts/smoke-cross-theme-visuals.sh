#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERIFY_SCREENSHOTS="$SCRIPT_DIR/verify-smoke-screenshots.js"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-cross-theme-smoke-$RUN_ID}"
CAPTURE_REGION="${CLAWD_NATIVE_VISUAL_CAPTURE_REGION:-}"
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

if [[ -n "$CAPTURE_REGION" && ! "$CAPTURE_REGION" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
  fail "invalid capture region: $CAPTURE_REGION"
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

post_state() {
  local port="$1"
  local state="$2"
  local session_id="$3"
  local title="$4"
  local event="$5"
  curl -fsS \
    -X POST "http://127.0.0.1:$port/state" \
    -H "Content-Type: application/json" \
    --data "{\"state\":\"$state\",\"session_id\":\"$session_id\",\"event\":\"$event\",\"agent_id\":\"codex\",\"session_title\":\"$title\",\"cwd\":\"/tmp/clawd-native-cross-theme-smoke\"}" \
    >/dev/null || fail "could not inject $state state"
}

capture_current() {
  local theme="$1"
  local case_name="$2"
  local screenshot_path="$SMOKE_ROOT/$theme-$case_name/$theme-$case_name.png"
  mkdir -p "$(dirname "$screenshot_path")"
  sleep 0.6
  osascript \
    -e 'tell application "System Events" to tell process "ClawdNative" to perform action "AXRaise" of window 1' \
    >/dev/null 2>&1 || true
  sleep 0.2
  if [[ -n "$CAPTURE_REGION" ]]; then
    screencapture -x -R "$CAPTURE_REGION" "$screenshot_path" || fail "screencapture failed for $theme $case_name"
  else
    screencapture -x "$screenshot_path" || fail "screencapture failed for $theme $case_name"
  fi
  echo "$screenshot_path"
}

capture_theme_group() {
  local theme="$1"

  cleanup_app
  start_native "$theme" "false" "$SMOKE_ROOT/$theme-desktop"
  capture_current "$theme" "desktop-idle"
  post_state "$CURRENT_PORT" "working" "native-$theme-desktop-working" "$theme desktop working" "PreToolUse"
  capture_current "$theme" "desktop-working"
  post_state "$CURRENT_PORT" "notification" "native-$theme-desktop-alert" "$theme desktop alert" "Notification"
  capture_current "$theme" "desktop-alert"

  cleanup_app
  start_native "$theme" "true" "$SMOKE_ROOT/$theme-mini"
  capture_current "$theme" "mini-idle"
  post_state "$CURRENT_PORT" "working" "native-$theme-mini-working" "$theme mini working" "PreToolUse"
  capture_current "$theme" "mini-working"
}

mkdir -p "$SMOKE_ROOT"

for theme in clawd calico cloudling; do
  capture_theme_group "$theme"
done

cleanup_app
node "$VERIFY_SCREENSHOTS" \
  --min-images 15 \
  --manifest "$SMOKE_ROOT/manifest.json" \
  "$SMOKE_ROOT" \
  || fail "screenshot verification failed"

node - "$SMOKE_ROOT/manifest.json" "$CAPTURE_REGION" <<'NODE'
const fs = require("fs");

const [manifestPath, captureRegion] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
manifest.runtime = "native";
manifest.scope = "cross-theme-visual";
if (captureRegion) {
  manifest.captureRegion = captureRegion;
}
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

echo "Smoke root: $SMOKE_ROOT"
if [[ -n "$CAPTURE_REGION" ]]; then
  echo "Capture region: $CAPTURE_REGION"
fi
echo "Manifest: $SMOKE_ROOT/manifest.json"
