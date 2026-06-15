#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SMOKE_ROOT="${1:-${TMPDIR:-/tmp}/clawd-native-motion-suite-$RUN_ID}"

mkdir -p "$SMOKE_ROOT"

bash "$SCRIPT_DIR/smoke-cloudling-webkit-motion.sh" "$SMOKE_ROOT/cloudling-webkit"
bash "$SCRIPT_DIR/smoke-clawd-svg-motion.sh" "$SMOKE_ROOT/clawd-svg"
bash "$SCRIPT_DIR/smoke-calico-apng-motion.sh" "$SMOKE_ROOT/calico-apng"

node - "$SMOKE_ROOT" <<'NODE'
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
const checks = [
  { name: "cloudling-webkit", channel: "trusted-scripted-svg" },
  { name: "clawd-svg", channel: "inline-svg" },
  { name: "calico-apng", channel: "image-apng" },
].map((entry) => {
  const manifestPath = path.join(root, entry.name, "manifest.json");
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`missing child manifest: ${manifestPath}`);
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  return {
    ...entry,
    manifest: manifestPath,
    screenshots: manifest.screenshots.length,
    motionPairs: manifest.motionPairs,
  };
});

const output = {
  generatedAt: new Date().toISOString(),
  root,
  checks,
};
fs.writeFileSync(path.join(root, "manifest.json"), `${JSON.stringify(output, null, 2)}\n`);
NODE

echo "Motion suite root: $SMOKE_ROOT"
echo "Motion suite manifest: $SMOKE_ROOT/manifest.json"
