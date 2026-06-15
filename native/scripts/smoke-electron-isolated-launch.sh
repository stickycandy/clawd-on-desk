#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-electron-isolated-smoke-$RUN_ID}"
PREFS_PATH="$SMOKE_ROOT/prefs.json"
RUNTIME_PATH="$SMOKE_ROOT/runtime.json"
LOG_PATH="$SMOKE_ROOT/electron.log"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    # launch.js is a parent Node process. Best-effort kill its direct children
    # first so the Electron process does not outlive the smoke wrapper.
    if command -v pgrep >/dev/null 2>&1; then
      while read -r child_pid; do
        [[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null || true
      done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
    fi
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  if [[ -f "$LOG_PATH" ]]; then
    echo "--- Electron log tail ---" >&2
    tail -n 80 "$LOG_PATH" >&2 || true
  fi
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_command node
require_command curl

mkdir -p "$SMOKE_ROOT"
cat >"$PREFS_PATH" <<JSON
{
  "positionSaved": true,
  "x": 200,
  "y": 300,
  "theme": "clawd",
  "miniMode": false,
  "sessionHudEnabled": true,
  "sessionHudPinned": false,
  "soundMuted": true,
  "showDock": false,
  "showTray": false
}
JSON

cd "$REPO_ROOT"
CLAWD_ELECTRON_PREFS_PATH="$PREFS_PATH" \
CLAWD_ELECTRON_RUNTIME_PATH="$RUNTIME_PATH" \
CLAWD_ELECTRON_SKIP_INTEGRATION_SYNC=1 \
CLAWD_ELECTRON_ALLOW_PARALLEL=1 \
node launch.js >"$LOG_PATH" 2>&1 &
APP_PID="$!"

for _ in {1..120}; do
  if [[ -s "$RUNTIME_PATH" ]]; then
    break
  fi
  sleep 0.25
done
[[ -s "$RUNTIME_PATH" ]] || fail "Electron runtime file was not written: $RUNTIME_PATH"

PORT="$(node -e 'const fs = require("fs"); const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (!Number.isInteger(data.port)) process.exit(1); console.log(data.port);' "$RUNTIME_PATH")" \
  || fail "could not parse Electron runtime port"

for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:$PORT/state" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/state" >/dev/null || fail "Electron /state route did not become ready"

node - "$RUNTIME_PATH" "$PREFS_PATH" "$SMOKE_ROOT/manifest.json" <<'NODE'
const fs = require("fs");
const path = require("path");

const [runtimePath, prefsPath, manifestPath] = process.argv.slice(2);
const runtime = JSON.parse(fs.readFileSync(runtimePath, "utf8"));
fs.writeFileSync(manifestPath, `${JSON.stringify({
  generatedAt: new Date().toISOString(),
  runtimePath: path.resolve(runtimePath),
  prefsPath: path.resolve(prefsPath),
  port: runtime.port,
  app: runtime.app,
}, null, 2)}\n`);
NODE

echo "Smoke root: $SMOKE_ROOT"
echo "Runtime: $RUNTIME_PATH"
echo "Prefs: $PREFS_PATH"
echo "Log: $LOG_PATH"
echo "Manifest: $SMOKE_ROOT/manifest.json"
