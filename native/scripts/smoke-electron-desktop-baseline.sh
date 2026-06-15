#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERIFY_SCREENSHOTS="$SCRIPT_DIR/verify-smoke-screenshots.js"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-electron-desktop-baseline-$RUN_ID}"
CAPTURE_REGION="${CLAWD_ELECTRON_BASELINE_CAPTURE_REGION:-180,280,420,420}"
STABLE_DELAY="${CLAWD_ELECTRON_BASELINE_STABLE_DELAY:-0.75}"
APP_PID=""
CURRENT_LOG=""
CURRENT_PORT=""

cleanup_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    if command -v pgrep >/dev/null 2>&1; then
      while read -r child_pid; do
        [[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null || true
      done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
    fi
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
    echo "--- Electron log tail ---" >&2
    tail -n 80 "$CURRENT_LOG" >&2 || true
  fi
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_command node
require_command curl
require_command screencapture
[[ -f "$VERIFY_SCREENSHOTS" ]] || fail "missing screenshot verifier: $VERIFY_SCREENSHOTS"

if ! [[ "$CAPTURE_REGION" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
  fail "invalid capture region: $CAPTURE_REGION"
fi

start_electron() {
  local theme="$1"
  local case_dir="$2"
  local prefs_path="$case_dir/prefs.json"
  local runtime_path="$case_dir/runtime.json"
  local log_path="$case_dir/electron.log"

  mkdir -p "$case_dir"
  CURRENT_LOG="$log_path"
  cat >"$prefs_path" <<JSON
{
  "positionSaved": true,
  "x": 200,
  "y": 300,
  "size": "P:9",
  "keepSizeAcrossDisplays": true,
  "savedPixelWidth": 360,
  "savedPixelHeight": 360,
  "theme": "$theme",
  "miniMode": false,
  "sessionHudEnabled": true,
  "sessionHudPinned": false,
  "soundMuted": true,
  "showDock": false,
  "showTray": false
}
JSON

  cd "$REPO_ROOT"
  CLAWD_ELECTRON_PREFS_PATH="$prefs_path" \
  CLAWD_ELECTRON_RUNTIME_PATH="$runtime_path" \
  CLAWD_ELECTRON_SKIP_INTEGRATION_SYNC=1 \
  CLAWD_ELECTRON_ALLOW_PARALLEL=1 \
  node launch.js >"$log_path" 2>&1 &
  APP_PID="$!"

  for _ in {1..120}; do
    if [[ -s "$runtime_path" ]]; then
      break
    fi
    sleep 0.25
  done
  [[ -s "$runtime_path" ]] || fail "Electron runtime file was not written: $runtime_path"

  CURRENT_PORT="$(node -e 'const fs = require("fs"); const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).port; if (!value) process.exit(1); console.log(value);' "$runtime_path")" \
    || fail "could not parse Electron runtime port"

  for _ in {1..40}; do
    if curl -fsS "http://127.0.0.1:$CURRENT_PORT/state" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  curl -fsS "http://127.0.0.1:$CURRENT_PORT/state" >/dev/null || fail "Electron /state route did not become ready"
}

post_state() {
  local state="$1"
  local session_id="$2"
  local title="$3"
  local event="$4"
  curl -fsS \
    -X POST "http://127.0.0.1:$CURRENT_PORT/state" \
    -H "Content-Type: application/json" \
    --data "{\"state\":\"$state\",\"session_id\":\"$session_id\",\"event\":\"$event\",\"agent_id\":\"codex\",\"session_title\":\"$title\",\"cwd\":\"/tmp/clawd-electron-desktop-baseline\"}" \
    >/dev/null || fail "could not inject $state state"
}

capture_current() {
  local theme="$1"
  local state="$2"
  local screenshot_path="$SMOKE_ROOT/$theme-desktop/$theme-desktop-$state.png"
  mkdir -p "$(dirname "$screenshot_path")"
  sleep "$STABLE_DELAY"
  screencapture -x -R "$CAPTURE_REGION" "$screenshot_path" || fail "screencapture failed for $theme $state"
  echo "$screenshot_path"
}

capture_theme() {
  local theme="$1"

  cleanup_app
  start_electron "$theme" "$SMOKE_ROOT/$theme-runtime"
  capture_current "$theme" "idle"
  post_state "working" "electron-$theme-working" "$theme desktop working" "PreToolUse"
  capture_current "$theme" "working"
  post_state "notification" "electron-$theme-notification" "$theme desktop notification" "Notification"
  capture_current "$theme" "notification"
}

mkdir -p "$SMOKE_ROOT"

for theme in clawd calico cloudling; do
  capture_theme "$theme"
done

cleanup_app
EXPECTED_IMAGES=$((3 * 3))
node "$VERIFY_SCREENSHOTS" \
  --min-images "$EXPECTED_IMAGES" \
  --manifest "$SMOKE_ROOT/manifest.json" \
  "$SMOKE_ROOT" \
  || fail "screenshot verification failed"

node - "$SMOKE_ROOT/manifest.json" "$CAPTURE_REGION" <<'NODE'
const fs = require("fs");

const [manifestPath, captureRegion] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
manifest.captureRegion = captureRegion;
manifest.runtime = "electron";
manifest.scope = "desktop-baseline";
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

echo "Smoke root: $SMOKE_ROOT"
echo "Capture region: $CAPTURE_REGION"
echo "Images: $EXPECTED_IMAGES"
echo "Manifest: $SMOKE_ROOT/manifest.json"
