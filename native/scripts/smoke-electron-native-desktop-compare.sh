#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELECTRON_SMOKE="$SCRIPT_DIR/smoke-electron-desktop-baseline.sh"
NATIVE_SMOKE="$SCRIPT_DIR/smoke-cross-theme-visuals.sh"
COMPARE_SCRIPT="$SCRIPT_DIR/compare-smoke-screenshots.js"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/smoke-electron-native-desktop-compare.sh [output-dir]

Captures the Electron desktop baseline, captures the native desktop visual
subset, compares matching PNG paths, and writes manifest.json plus
compare-manifest.json in output-dir.

Environment:
  CLAWD_ELECTRON_NATIVE_COMPARE_ELECTRON_CAPTURE_REGION  Electron crop, default 180,280,420,420
  CLAWD_ELECTRON_NATIVE_COMPARE_NATIVE_CAPTURE_REGION    Native crop, default derived from primary AppKit screen
  CLAWD_ELECTRON_NATIVE_COMPARE_MAX_CHANGED_RATIO        Optional compare threshold, 0..1
  CLAWD_ELECTRON_NATIVE_COMPARE_MAX_MEAN_DELTA           Optional compare threshold
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-electron-native-desktop-compare-$RUN_ID}"
ELECTRON_ROOT="$SMOKE_ROOT/electron"
NATIVE_ROOT="$SMOKE_ROOT/native"
MANIFEST_PATH="$SMOKE_ROOT/manifest.json"
COMPARE_MANIFEST_PATH="$SMOKE_ROOT/compare-manifest.json"
ELECTRON_CAPTURE_REGION="${CLAWD_ELECTRON_NATIVE_COMPARE_ELECTRON_CAPTURE_REGION:-180,280,420,420}"
NATIVE_CAPTURE_REGION="${CLAWD_ELECTRON_NATIVE_COMPARE_NATIVE_CAPTURE_REGION:-}"
COMPARE_MAX_CHANGED_RATIO="${CLAWD_ELECTRON_NATIVE_COMPARE_MAX_CHANGED_RATIO:-}"
COMPARE_MAX_MEAN_DELTA="${CLAWD_ELECTRON_NATIVE_COMPARE_MAX_MEAN_DELTA:-}"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

validate_capture_region() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
    fail "invalid $name capture region: $value"
  fi
}

derive_native_capture_region() {
  swift -e 'import AppKit
let windowX = 200.0
let windowY = 300.0
let windowSize = 180.0
let padding = 20.0
let captureSize = 420.0
if let screen = NSScreen.screens.first(where: { $0.frame.origin.x == 0 && $0.frame.origin.y == 0 }) ?? NSScreen.main {
  let x = Int(windowX - padding)
  let y = Int(screen.frame.height - windowY - windowSize - padding)
  print("\(x),\(y),\(Int(captureSize)),\(Int(captureSize))")
}'
}

require_command bash
require_command node
require_command swift
[[ -x "$ELECTRON_SMOKE" ]] || fail "missing Electron smoke script: $ELECTRON_SMOKE"
[[ -x "$NATIVE_SMOKE" ]] || fail "missing native smoke script: $NATIVE_SMOKE"
[[ -f "$COMPARE_SCRIPT" ]] || fail "missing compare script: $COMPARE_SCRIPT"

validate_capture_region "Electron" "$ELECTRON_CAPTURE_REGION"
if [[ -z "$NATIVE_CAPTURE_REGION" ]]; then
  NATIVE_CAPTURE_REGION="$(derive_native_capture_region)"
fi
validate_capture_region "native" "$NATIVE_CAPTURE_REGION"

mkdir -p "$SMOKE_ROOT"

echo "==> Capturing Electron desktop baseline"
CLAWD_ELECTRON_BASELINE_CAPTURE_REGION="$ELECTRON_CAPTURE_REGION" \
  bash "$ELECTRON_SMOKE" "$ELECTRON_ROOT"

echo "==> Capturing native desktop visual subset"
CLAWD_NATIVE_VISUAL_SCOPE=desktop \
CLAWD_NATIVE_VISUAL_CAPTURE_REGION="$NATIVE_CAPTURE_REGION" \
  bash "$NATIVE_SMOKE" "$NATIVE_ROOT"

echo "==> Comparing Electron and native desktop screenshots"
compare_args=(node "$COMPARE_SCRIPT" --manifest "$COMPARE_MANIFEST_PATH")
if [[ -n "$COMPARE_MAX_CHANGED_RATIO" ]]; then
  compare_args+=(--max-changed-ratio "$COMPARE_MAX_CHANGED_RATIO")
fi
if [[ -n "$COMPARE_MAX_MEAN_DELTA" ]]; then
  compare_args+=(--max-mean-delta "$COMPARE_MAX_MEAN_DELTA")
fi

set +e
"${compare_args[@]}" "$ELECTRON_ROOT" "$NATIVE_ROOT"
COMPARE_STATUS="$?"
set -e

node - "$MANIFEST_PATH" "$SMOKE_ROOT" "$ELECTRON_ROOT" "$NATIVE_ROOT" "$COMPARE_MANIFEST_PATH" "$ELECTRON_CAPTURE_REGION" "$NATIVE_CAPTURE_REGION" "$COMPARE_STATUS" <<'NODE'
const fs = require("fs");
const path = require("path");

const [
  manifestPath,
  smokeRoot,
  electronRoot,
  nativeRoot,
  compareManifestPath,
  electronCaptureRegion,
  nativeCaptureRegion,
  compareStatus,
] = process.argv.slice(2);

function readJsonIfExists(file) {
  if (!file || !fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

const compare = readJsonIfExists(compareManifestPath);
const compareExitCode = Number(compareStatus);
const manifest = {
  generatedAt: new Date().toISOString(),
  root: path.resolve(smokeRoot),
  electronBaseline: path.resolve(electronRoot),
  nativeVisual: path.resolve(nativeRoot),
  electronCaptureRegion,
  nativeCaptureRegion,
  compareManifest: path.resolve(compareManifestPath),
  compareExitCode,
  compareStatus: compare
    ? {
        passed: compare.passed === true,
        results: Array.isArray(compare.results) ? compare.results.length : 0,
        maxChangedRatio: compare.maxChangedRatio,
        maxMeanDelta: compare.maxMeanDelta,
        failures: Array.isArray(compare.failures) ? compare.failures.length : 0,
      }
    : null,
};
manifest.passed = compareExitCode === 0 && (!manifest.compareStatus || manifest.compareStatus.passed === true);

fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

echo "Smoke root: $SMOKE_ROOT"
echo "Electron baseline: $ELECTRON_ROOT"
echo "Native visual: $NATIVE_ROOT"
echo "Electron capture region: $ELECTRON_CAPTURE_REGION"
echo "Native capture region: $NATIVE_CAPTURE_REGION"
echo "Compare manifest: $COMPARE_MANIFEST_PATH"
echo "Manifest: $MANIFEST_PATH"
exit "$COMPARE_STATUS"
