#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERIFY_SCREENSHOTS="$SCRIPT_DIR/verify-smoke-screenshots.js"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_DIR="${TMPDIR:-/tmp}/clawd-native-session-hud-smoke-$RUN_ID"
PREFS_PATH="$SMOKE_DIR/prefs.json"
RUNTIME_PATH="$SMOKE_DIR/runtime.json"
LOG_PATH="$SMOKE_DIR/app.log"
SCREENSHOT_PATH="${1:-$SMOKE_DIR/session-hud-click.png}"
MANIFEST_PATH="${2:-$SMOKE_DIR/manifest.json}"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  if [[ -f "$LOG_PATH" ]]; then
    echo "--- ClawdNative log tail ---" >&2
    tail -n 80 "$LOG_PATH" >&2 || true
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

mkdir -p "$SMOKE_DIR" "$(dirname "$SCREENSHOT_PATH")" "$(dirname "$MANIFEST_PATH")"
cat > "$PREFS_PATH" <<JSON
{
  "positionSaved": true,
  "x": 200,
  "y": 300,
  "theme": "clawd",
  "sessionHudEnabled": true,
  "sessionHudPinned": false,
  "soundMuted": true,
  "showDock": false
}
JSON

cd "$NATIVE_DIR"
CLAWD_PROJECT_ROOT="$REPO_ROOT" \
CLAWD_NATIVE_PREFS_PATH="$PREFS_PATH" \
CLAWD_NATIVE_RUNTIME_PATH="$RUNTIME_PATH" \
CLAWD_NATIVE_SKIP_INTEGRATION_SYNC=1 \
swift run ClawdNative >"$LOG_PATH" 2>&1 &
APP_PID="$!"

for _ in {1..120}; do
  if [[ -s "$RUNTIME_PATH" ]]; then
    break
  fi
  sleep 0.25
done
[[ -s "$RUNTIME_PATH" ]] || fail "native runtime file was not written: $RUNTIME_PATH"

PORT="$(node -e 'const fs = require("fs"); const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).port; if (!value) process.exit(1); console.log(value);' "$RUNTIME_PATH")" \
  || fail "could not parse native runtime port"

for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:$PORT/sessions" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/sessions" >/dev/null || fail "native HTTP sessions route did not become ready"

curl -fsS \
  -X POST "http://127.0.0.1:$PORT/state" \
  -H "Content-Type: application/json" \
  --data '{"state":"working","session_id":"native-smoke-session","event":"PreToolUse","agent_id":"codex","session_title":"Native HUD Smoke","cwd":"/tmp/clawd-native-smoke"}' \
  >/dev/null || fail "could not inject smoke session"

osascript \
  -e 'tell application "System Events" to tell process "ClawdNative" to set position of window 1 to {200, 300}' \
  >/dev/null || fail "could not position ClawdNative window"

# Clawd working hitbox center for the 180px window at AX top-left {200, 300}.
osascript \
  -e 'tell application "System Events" to click at {293, 408}' \
  >/dev/null || fail "could not click ClawdNative pet"

sleep 0.3
osascript \
  -e 'tell application "System Events" to tell process "ClawdNative" to perform action "AXRaise" of window 1' \
  >/dev/null 2>&1 || true
sleep 0.2
screencapture -x "$SCREENSHOT_PATH" || fail "screencapture failed"
node "$VERIFY_SCREENSHOTS" \
  --min-images 1 \
  --manifest "$MANIFEST_PATH" \
  "$SCREENSHOT_PATH" \
  || fail "screenshot verification failed"

echo "Runtime: $RUNTIME_PATH"
echo "Log: $LOG_PATH"
echo "Screenshot: $SCREENSHOT_PATH"
echo "Manifest: $MANIFEST_PATH"
