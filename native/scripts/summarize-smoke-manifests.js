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
    minMotionRatio: null,
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
    } else if (arg === "--min-motion-ratio") {
      const value = Number(argv[++i]);
      if (!Number.isFinite(value) || value < 0 || value > 1) {
        fail(`invalid --min-motion-ratio value: ${argv[i]}`);
      }
      args.minMotionRatio = value;
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
  console.log("Usage: node scripts/summarize-smoke-manifests.js [--json output.json] [--min-motion-ratio 0..1] <smoke-dir-or-manifest> [...]");
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

function summarizeCompareManifest(manifest) {
  const compareStatus = manifest.compareStatus && typeof manifest.compareStatus === "object"
    ? manifest.compareStatus
    : null;
  const directResults = Array.isArray(manifest.results) ? manifest.results : null;
  const directFailures = Array.isArray(manifest.failures) ? manifest.failures : null;
  const hasCompare = !!compareStatus || !!directResults;
  const pairs = compareStatus && Number.isFinite(compareStatus.results)
    ? compareStatus.results
    : (directResults ? directResults.length : 0);
  const failures = compareStatus && Number.isFinite(compareStatus.failures)
    ? compareStatus.failures
    : (directFailures ? directFailures.length : 0);
  const passed = hasCompare
    ? (
        compareStatus && typeof compareStatus.passed === "boolean"
          ? compareStatus.passed
          : (typeof manifest.passed === "boolean" ? manifest.passed : null)
      )
    : null;

  return {
    comparePairs: pairs,
    maxChangedRatio: finiteOrNull(compareStatus?.maxChangedRatio ?? manifest.maxChangedRatio),
    maxMeanDelta: finiteOrNull(compareStatus?.maxMeanDelta ?? manifest.maxMeanDelta),
    compareFailures: failures,
    comparePassed: passed,
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
  const compare = summarizeCompareManifest(manifest);
  return {
    file,
    generatedAt: manifest.generatedAt || "-",
    ...summary,
    ...compare,
  };
}

function printMarkdown(rows) {
  console.log("| Manifest | Generated | Screenshots | Min colors | Min luminance | Motion ratios | Compare pairs | Max changed | Max mean | Compare failures |");
  console.log("| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |");
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
      numberOrDash(row.comparePairs),
      numberOrDash(row.maxChangedRatio, 6),
      numberOrDash(row.maxMeanDelta, 3),
      numberOrDash(row.compareFailures),
    ].join(" | ").replace(/^/, "| ").replace(/$/, " |"));
  }
}

function findMotionFailures(rows, minMotionRatio) {
  if (!Number.isFinite(minMotionRatio)) return [];
  const failures = [];
  for (const row of rows) {
    for (const ratio of row.motionRatios) {
      if (ratio < minMotionRatio) {
        failures.push({
          file: row.file,
          ratio,
          minMotionRatio,
        });
      }
    }
  }
  return failures;
}

function findCompareFailures(rows) {
  return rows
    .filter((row) => row.comparePassed === false || row.compareFailures > 0)
    .map((row) => ({
      file: row.file,
      passed: row.comparePassed,
      failures: row.compareFailures,
      maxChangedRatio: row.maxChangedRatio,
      maxMeanDelta: row.maxMeanDelta,
    }));
}

function writeJson(file, rows, options = {}) {
  const minMotionRatio = Number.isFinite(options.minMotionRatio)
    ? options.minMotionRatio
    : null;
  const motionFailures = options.motionFailures || [];
  const compareFailures = options.compareFailures || [];
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({
    generatedAt: new Date().toISOString(),
    count: rows.length,
    thresholds: {
      minMotionRatio,
    },
    passed: motionFailures.length === 0 && compareFailures.length === 0,
    motionFailures,
    compareFailures,
    manifests: rows.map((row) => ({
      file: row.file,
      relativeFile: path.relative(process.cwd(), row.file) || path.basename(row.file),
      sourceGeneratedAt: row.generatedAt,
      screenshots: row.screenshots,
      minUniqueColors: finiteOrNull(row.minUniqueColors),
      minLuminanceRange: finiteOrNull(row.minLuminanceRange),
      motionRatios: row.motionRatios,
      comparePairs: row.comparePairs,
      maxChangedRatio: row.maxChangedRatio,
      maxMeanDelta: row.maxMeanDelta,
      compareFailures: row.compareFailures,
      comparePassed: row.comparePassed,
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
  const motionFailures = findMotionFailures(rows, args.minMotionRatio);
  const compareFailures = findCompareFailures(rows);
  if (args.json) {
    writeJson(args.json, rows, {
      minMotionRatio: args.minMotionRatio,
      motionFailures,
      compareFailures,
    });
  }
  printMarkdown(rows);
  console.log(`\nFound ${rows.length} manifest(s).`);
  if (Number.isFinite(args.minMotionRatio)) {
    console.log(`Motion threshold: minMotionRatio=${args.minMotionRatio.toFixed(4)} failures=${motionFailures.length}`);
  }
  if (motionFailures.length > 0) {
    fail(`${motionFailures.length} motion ratio(s) below threshold ${args.minMotionRatio}`);
  }
  if (compareFailures.length > 0) {
    fail(`${compareFailures.length} compare manifest(s) failed`);
  }
}

main();
