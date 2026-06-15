#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-motion-suite-$RUN_ID}"

mkdir -p "$SMOKE_ROOT"

bash "$SCRIPT_DIR/smoke-cloudling-webkit-motion.sh" "$SMOKE_ROOT/cloudling-webkit"
bash "$SCRIPT_DIR/smoke-clawd-svg-motion.sh" "$SMOKE_ROOT/clawd-svg"
bash "$SCRIPT_DIR/smoke-calico-apng-motion.sh" "$SMOKE_ROOT/calico-apng"

echo "Motion suite root: $SMOKE_ROOT"
