#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    json: null,
    inputs: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") {
      const value = argv[++i];
      if (!value) {
        fail("--json expects an output path");
      }
      args.json = value;
    } else if (arg === "-h" || arg === "--help") {
      printUsage();
      process.exit(0);
    } else if (arg.startsWith("--")) {
      fail(`unknown option: ${arg}`);
    } else {
      args.inputs.push(arg);
    }
  }

  return args;
}

function printUsage() {
  console.log("Usage: node scripts/summarize-smoke-manifests.js [--json output.json] <smoke-dir-or-manifest> [...]");
}

function collectManifestPaths(inputs) {
  const manifests = new Set();
  const stack = inputs.map((item) => ({ item, direct: true }));

  while (stack.length > 0) {
    const { item, direct } = stack.pop();
    if (!fs.existsSync(item)) {
      fail(`path does not exist: ${item}`);
    }
    const stat = fs.statSync(item);
    if (stat.isDirectory()) {
      for (const entry of fs.readdirSync(item)) {
        stack.push({ item: path.join(item, entry), direct: false });
      }
    } else if (
      stat.isFile()
      && (path.basename(item) === "manifest.json" || (direct && item.toLowerCase().endsWith(".json")))
    ) {
      manifests.add(path.resolve(item));
    }
  }

  return [...manifests].sort();
}

function numberOrDash(value, digits = 0) {
  if (!Number.isFinite(value)) return "-";
  return digits > 0 ? value.toFixed(digits) : String(value);
}

function summarizeVerifierManifest(manifest) {
  const screenshots = Array.isArray(manifest.screenshots) ? manifest.screenshots : [];
  const motionPairs = Array.isArray(manifest.motionPairs) ? manifest.motionPairs : [];
  return {
    screenshots: screenshots.length,
    minUniqueColors: minOf(screenshots, "uniqueColors"),
    minLuminanceRange: minOf(screenshots, "luminanceRange"),
    motionRatios: motionPairs.map((pair) => pair.ratio).filter(Number.isFinite),
  };
}

function summarizeSuiteManifest(manifest) {
  const checks = Array.isArray(manifest.checks) ? manifest.checks : [];
  const motionRatios = [];
  let screenshots = 0;

  for (const check of checks) {
    screenshots += Number.isFinite(check.screenshots) ? check.screenshots : 0;
    for (const pair of check.motionPairs || []) {
      if (Number.isFinite(pair.ratio)) motionRatios.push(pair.ratio);
    }
  }

  return {
    screenshots,
    minUniqueColors: NaN,
    minLuminanceRange: NaN,
    motionRatios,
  };
}

function minOf(items, key) {
  const values = items.map((item) => item[key]).filter(Number.isFinite);
  return values.length > 0 ? Math.min(...values) : NaN;
}

function summarizeManifest(file) {
  const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  const summary = Array.isArray(manifest.checks)
    ? summarizeSuiteManifest(manifest)
    : summarizeVerifierManifest(manifest);
  return {
    file,
    generatedAt: manifest.generatedAt || "-",
    ...summary,
  };
}

function printMarkdown(rows) {
  console.log("| Manifest | Generated | Screenshots | Min colors | Min luminance | Motion ratios |");
  console.log("| --- | --- | ---: | ---: | ---: | --- |");
  for (const row of rows) {
    const motion = row.motionRatios.length > 0
      ? row.motionRatios.map((ratio) => ratio.toFixed(4)).join(", ")
      : "-";
    console.log([
      escapeMarkdown(path.relative(process.cwd(), row.file) || path.basename(row.file)),
      escapeMarkdown(row.generatedAt),
      row.screenshots,
      numberOrDash(row.minUniqueColors),
      numberOrDash(row.minLuminanceRange),
      escapeMarkdown(motion),
    ].join(" | ").replace(/^/, "| ").replace(/$/, " |"));
  }
}

function writeJson(file, rows) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({
    generatedAt: new Date().toISOString(),
    count: rows.length,
    manifests: rows.map((row) => ({
      file: row.file,
      relativeFile: path.relative(process.cwd(), row.file) || path.basename(row.file),
      sourceGeneratedAt: row.generatedAt,
      screenshots: row.screenshots,
      minUniqueColors: finiteOrNull(row.minUniqueColors),
      minLuminanceRange: finiteOrNull(row.minLuminanceRange),
      motionRatios: row.motionRatios,
    })),
  }, null, 2)}\n`);
}

function finiteOrNull(value) {
  return Number.isFinite(value) ? value : null;
}

function escapeMarkdown(value) {
  return String(value).replace(/\|/g, "\\|");
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.inputs.length === 0) {
    fail("expected one or more smoke output directories or manifest.json files");
  }

  const manifestPaths = collectManifestPaths(args.inputs);
  if (manifestPaths.length === 0) {
    fail("no manifest.json files found");
  }

  const rows = manifestPaths.map(summarizeManifest);
  if (args.json) {
    writeJson(args.json, rows);
  }
  printMarkdown(rows);
  console.log(`\nFound ${rows.length} manifest(s).`);
}

main();
