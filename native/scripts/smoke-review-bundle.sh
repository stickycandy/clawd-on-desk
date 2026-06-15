#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_SCRIPT="$SCRIPT_DIR/summarize-smoke-manifests.js"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/smoke-review-bundle.sh [output-dir] [suite ...]

Suites:
  motion        Targeted WebKit SVG, inline SVG, and APNG motion checks
  visual        Cross-theme desktop/mini visual smoke
  state         Cross-theme desktop/mini state matrix smoke
  transitions   Cross-theme transition smoke
  hud           Session HUD click-reveal smoke
  summary       Do not run suites; summarize existing manifests in output-dir

If no suites are passed, CLAWD_NATIVE_REVIEW_SUITES is used. If that variable is
unset, the default is: motion visual state transitions hud.

Environment:
  CLAWD_NATIVE_REVIEW_TRANSITION_CYCLES  Transition cycles, default 1
  CLAWD_NATIVE_REVIEW_MIN_MOTION_RATIO   Optional minimum motion ratio threshold
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
REVIEW_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-review-$RUN_ID}"
if [[ $# -gt 0 ]]; then
  shift
fi

if [[ $# -gt 0 ]]; then
  SUITES=("$@")
else
  # shellcheck disable=SC2206
  SUITES=(${CLAWD_NATIVE_REVIEW_SUITES:-motion visual state transitions hud})
fi

TRANSITION_CYCLES="${CLAWD_NATIVE_REVIEW_TRANSITION_CYCLES:-1}"
MIN_MOTION_RATIO="${CLAWD_NATIVE_REVIEW_MIN_MOTION_RATIO:-}"
SUMMARY_PATH="$REVIEW_ROOT/summary.md"
SUMMARY_JSON_PATH="$REVIEW_ROOT/summary.json"
REVIEW_MANIFEST_PATH="$REVIEW_ROOT/review-manifest.json"
STATUS_TSV="$REVIEW_ROOT/suite-status.tsv"
STATUS=0

mkdir -p "$REVIEW_ROOT"
: >"$STATUS_TSV"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_command node
[[ -f "$SUMMARY_SCRIPT" ]] || fail "missing summary script: $SUMMARY_SCRIPT"

record_suite() {
  local name="$1"
  local result="$2"
  local code="$3"
  local output="$4"
  local started_at="$5"
  local ended_at="$6"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$name" "$result" "$code" "$output" "$started_at" "$ended_at" >>"$STATUS_TSV"
}

run_suite() {
  local name="$1"
  local output="$2"
  shift 2

  local started_at
  local ended_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "==> Running $name"
  if "$@"; then
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record_suite "$name" "passed" "0" "$output" "$started_at" "$ended_at"
  else
    local code="$?"
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record_suite "$name" "failed" "$code" "$output" "$started_at" "$ended_at"
    STATUS=1
  fi
}

for suite in "${SUITES[@]}"; do
  case "$suite" in
    ""|"summary"|"summary-only"|"none")
      ;;
    "motion"|"motion-suite")
      run_suite "motion" "$REVIEW_ROOT/motion-suite" \
        bash "$SCRIPT_DIR/smoke-motion-suite.sh" "$REVIEW_ROOT/motion-suite"
      ;;
    "visual"|"visuals"|"cross-theme-visuals")
      run_suite "visual" "$REVIEW_ROOT/visual" \
        bash "$SCRIPT_DIR/smoke-cross-theme-visuals.sh" "$REVIEW_ROOT/visual"
      ;;
    "state"|"state-matrix")
      run_suite "state" "$REVIEW_ROOT/state-matrix" \
        bash "$SCRIPT_DIR/smoke-state-matrix.sh" "$REVIEW_ROOT/state-matrix"
      ;;
    "transition"|"transitions")
      run_suite "transitions" "$REVIEW_ROOT/transitions" \
        bash "$SCRIPT_DIR/smoke-cross-theme-transitions.sh" "$REVIEW_ROOT/transitions" "$TRANSITION_CYCLES"
      ;;
    "hud"|"session-hud")
      mkdir -p "$REVIEW_ROOT/session-hud"
      run_suite "session-hud" "$REVIEW_ROOT/session-hud" \
        bash "$SCRIPT_DIR/smoke-session-hud-click.sh" \
          "$REVIEW_ROOT/session-hud/session-hud-click.png" \
          "$REVIEW_ROOT/session-hud/manifest.json"
      ;;
    *)
      echo "error: unknown review suite: $suite" >&2
      record_suite "$suite" "failed" "64" "" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      STATUS=1
      ;;
  esac
done

node - "$REVIEW_ROOT" "$STATUS_TSV" "$REVIEW_MANIFEST_PATH" "$SUMMARY_PATH" "$SUMMARY_JSON_PATH" <<'NODE'
const fs = require("fs");
const path = require("path");

const [root, statusPath, manifestPath, summaryPath, summaryJsonPath] = process.argv.slice(2);
const rows = fs.readFileSync(statusPath, "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => {
    const [name, result, code, output, startedAt, endedAt] = line.split("\t");
    return { name, result, code: Number(code), output, startedAt, endedAt };
  });

fs.writeFileSync(manifestPath, `${JSON.stringify({
  generatedAt: new Date().toISOString(),
  root: path.resolve(root),
  summary: path.resolve(summaryPath),
  summaryJson: path.resolve(summaryJsonPath),
  suites: rows,
}, null, 2)}\n`);
NODE

MANIFEST_COUNT="$(find "$REVIEW_ROOT" -name manifest.json -type f | wc -l | tr -d '[:space:]')"
{
  echo "# Clawd Native Smoke Review"
  echo
  echo "- Root: $REVIEW_ROOT"
  echo "- Review manifest: $REVIEW_MANIFEST_PATH"
  echo "- Summary JSON: $SUMMARY_JSON_PATH"
  echo "- Transition cycles: $TRANSITION_CYCLES"
  if [[ -n "$MIN_MOTION_RATIO" ]]; then
    echo "- Min motion ratio: $MIN_MOTION_RATIO"
  fi
  echo
  echo "## Suite Status"
  echo
  echo "| Suite | Result | Exit | Output | Started | Ended |"
  echo "| --- | --- | ---: | --- | --- | --- |"
  if [[ -s "$STATUS_TSV" ]]; then
    while IFS=$'\t' read -r name result code output started_at ended_at; do
      echo "| $name | $result | $code | $output | $started_at | $ended_at |"
    done <"$STATUS_TSV"
  else
    echo "| summary | skipped | 0 | $REVIEW_ROOT | - | - |"
  fi
  echo
  echo "## Manifest Summary"
  echo
  if [[ "$MANIFEST_COUNT" -gt 0 ]]; then
    summary_args=("$SUMMARY_SCRIPT" --json "$SUMMARY_JSON_PATH")
    if [[ -n "$MIN_MOTION_RATIO" ]]; then
      summary_args+=(--min-motion-ratio "$MIN_MOTION_RATIO")
    fi
    if ! node "${summary_args[@]}" "$REVIEW_ROOT"; then
      STATUS=1
    fi
  else
    printf "{\n  \"generatedAt\": \"%s\",\n  \"count\": 0,\n  \"manifests\": []\n}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$SUMMARY_JSON_PATH"
    echo "No suite manifest.json files found."
  fi
} >"$SUMMARY_PATH"

echo "Review root: $REVIEW_ROOT"
echo "Review manifest: $REVIEW_MANIFEST_PATH"
echo "Summary: $SUMMARY_PATH"
echo "Summary JSON: $SUMMARY_JSON_PATH"
exit "$STATUS"
