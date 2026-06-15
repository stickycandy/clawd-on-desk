#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    manifest: null,
    maxChangedRatio: 1,
    maxMeanDelta: Infinity,
    paths: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--max-changed-ratio") {
      const value = Number(argv[++i]);
      if (!Number.isFinite(value) || value < 0 || value > 1) {
        fail(`invalid --max-changed-ratio value: ${argv[i]}`);
      }
      args.maxChangedRatio = value;
    } else if (arg === "--manifest") {
      const value = argv[++i];
      if (!value) {
        fail("--manifest expects an output path");
      }
      args.manifest = value;
    } else if (arg === "--max-mean-delta") {
      const value = Number(argv[++i]);
      if (!Number.isFinite(value) || value < 0) {
        fail(`invalid --max-mean-delta value: ${argv[i]}`);
      }
      args.maxMeanDelta = value;
    } else if (arg.startsWith("--")) {
      fail(`unknown option: ${arg}`);
    } else {
      args.paths.push(arg);
    }
  }

  if (args.paths.length !== 2) {
    fail("expected exactly two PNG files or directories");
  }
  return args;
}

function collectPairs(leftInput, rightInput) {
  const leftStat = statOrFail(leftInput);
  const rightStat = statOrFail(rightInput);

  if (leftStat.isFile() || rightStat.isFile()) {
    if (!leftStat.isFile() || !rightStat.isFile()) {
      fail("file comparisons require both inputs to be files");
    }
    return [{ label: path.basename(leftInput), left: leftInput, right: rightInput }];
  }

  const leftFiles = collectPngMap(leftInput);
  const rightFiles = collectPngMap(rightInput);
  const pairs = [];
  for (const [relative, left] of leftFiles) {
    const right = rightFiles.get(relative);
    if (!right) fail(`missing matching PNG in right directory: ${relative}`);
    pairs.push({ label: relative, left, right });
  }
  for (const relative of rightFiles.keys()) {
    if (!leftFiles.has(relative)) fail(`extra PNG in right directory: ${relative}`);
  }
  return pairs.sort((a, b) => a.label.localeCompare(b.label));
}

function statOrFail(input) {
  if (!fs.existsSync(input)) fail(`path does not exist: ${input}`);
  return fs.statSync(input);
}

function collectPngMap(root) {
  const out = new Map();
  const stack = [root];
  while (stack.length > 0) {
    const item = stack.pop();
    const stat = fs.statSync(item);
    if (stat.isDirectory()) {
      for (const entry of fs.readdirSync(item)) {
        stack.push(path.join(item, entry));
      }
    } else if (stat.isFile() && item.toLowerCase().endsWith(".png")) {
      out.set(path.relative(root, item), item);
    }
  }
  if (out.size === 0) fail(`no PNG files found in: ${root}`);
  return out;
}

function parsePng(file) {
  const buffer = fs.readFileSync(file);
  if (buffer.length < PNG_SIGNATURE.length || !buffer.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    throw new Error(`${file}: not a PNG file`);
  }

  let offset = PNG_SIGNATURE.length;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  const idat = [];

  while (offset + 12 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const start = offset + 8;
    const end = start + length;
    if (end + 4 > buffer.length) throw new Error(`${file}: truncated PNG chunk`);
    if (type === "IHDR") {
      width = buffer.readUInt32BE(start);
      height = buffer.readUInt32BE(start + 4);
      bitDepth = buffer[start + 8];
      colorType = buffer[start + 9];
      const compression = buffer[start + 10];
      const filter = buffer[start + 11];
      const interlace = buffer[start + 12];
      if (compression !== 0 || filter !== 0 || interlace !== 0) {
        throw new Error(`${file}: unsupported PNG encoding`);
      }
    } else if (type === "IDAT") {
      idat.push(buffer.subarray(start, end));
    } else if (type === "IEND") {
      break;
    }
    offset = end + 4;
  }

  const channels = new Map([[0, 1], [2, 3], [4, 2], [6, 4]]).get(colorType);
  if (width <= 0 || height <= 0 || bitDepth !== 8 || idat.length === 0 || !channels) {
    throw new Error(`${file}: unsupported or empty PNG`);
  }

  const data = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const rows = [];
  let inputOffset = 0;
  let prev = Buffer.alloc(stride);

  for (let y = 0; y < height; y += 1) {
    const filter = data[inputOffset];
    inputOffset += 1;
    const raw = data.subarray(inputOffset, inputOffset + stride);
    inputOffset += stride;
    const row = Buffer.alloc(stride);
    for (let x = 0; x < stride; x += 1) {
      const left = x >= channels ? row[x - channels] : 0;
      const up = prev[x] || 0;
      const upLeft = x >= channels ? prev[x - channels] || 0 : 0;
      let value = raw[x];
      if (filter === 1) value += left;
      else if (filter === 2) value += up;
      else if (filter === 3) value += Math.floor((left + up) / 2);
      else if (filter === 4) value += paeth(left, up, upLeft);
      else if (filter !== 0) throw new Error(`${file}: unsupported PNG filter ${filter}`);
      row[x] = value & 0xff;
    }
    rows.push(row);
    prev = row;
  }

  return { width, height, colorType, channels, rows };
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

function readPixel(png, x, y) {
  const row = png.rows[y];
  const index = x * png.channels;
  if (png.colorType === 0) return [row[index], row[index], row[index], 255];
  if (png.colorType === 2) return [row[index], row[index + 1], row[index + 2], 255];
  if (png.colorType === 4) return [row[index], row[index], row[index], row[index + 1]];
  return [row[index], row[index + 1], row[index + 2], row[index + 3]];
}

function comparePair(pair) {
  const left = parsePng(pair.left);
  const right = parsePng(pair.right);
  if (left.width !== right.width || left.height !== right.height) {
    throw new Error(`${pair.label}: dimension mismatch ${left.width}x${left.height} vs ${right.width}x${right.height}`);
  }

  let changed = 0;
  let total = 0;
  let sum = 0;
  let maxDelta = 0;
  for (let y = 0; y < left.height; y += 1) {
    for (let x = 0; x < left.width; x += 1) {
      const a = readPixel(left, x, y);
      const b = readPixel(right, x, y);
      const delta = Math.abs(a[0] - b[0])
        + Math.abs(a[1] - b[1])
        + Math.abs(a[2] - b[2])
        + Math.abs(a[3] - b[3]);
      if (delta > 0) changed += 1;
      sum += delta;
      maxDelta = Math.max(maxDelta, delta);
      total += 1;
    }
  }

  return {
    label: pair.label,
    width: left.width,
    height: left.height,
    changed,
    total,
    changedRatio: total > 0 ? changed / total : 0,
    meanDelta: total > 0 ? sum / total : 0,
    maxDelta,
  };
}

function printMarkdown(rows) {
  console.log("| PNG | Size | Changed | Changed ratio | Mean delta | Max delta |");
  console.log("| --- | ---: | ---: | ---: | ---: | ---: |");
  for (const row of rows) {
    console.log(`| ${escapeMarkdown(row.label)} | ${row.width}x${row.height} | ${row.changed}/${row.total} | ${row.changedRatio.toFixed(6)} | ${row.meanDelta.toFixed(3)} | ${row.maxDelta} |`);
  }
}

function escapeMarkdown(value) {
  return String(value).replace(/\|/g, "\\|");
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const pairs = collectPairs(args.paths[0], args.paths[1]);
  const rows = pairs.map(comparePair);
  printMarkdown(rows);

  const failures = rows.filter((row) => row.changedRatio > args.maxChangedRatio || row.meanDelta > args.maxMeanDelta);
  const maxRatio = Math.max(...rows.map((row) => row.changedRatio));
  const maxMean = Math.max(...rows.map((row) => row.meanDelta));
  console.log(`\nCompared ${rows.length} PNG pair(s). maxChangedRatio=${maxRatio.toFixed(6)} maxMeanDelta=${maxMean.toFixed(3)}`);
  if (args.manifest) {
    fs.mkdirSync(path.dirname(args.manifest), { recursive: true });
    fs.writeFileSync(args.manifest, `${JSON.stringify({
      generatedAt: new Date().toISOString(),
      left: args.paths[0],
      right: args.paths[1],
      thresholds: {
        maxChangedRatio: args.maxChangedRatio,
        maxMeanDelta: Number.isFinite(args.maxMeanDelta) ? args.maxMeanDelta : null,
      },
      maxChangedRatio: maxRatio,
      maxMeanDelta: maxMean,
      passed: failures.length === 0,
      failures,
      results: rows,
    }, null, 2)}\n`);
    console.log(`Manifest: ${args.manifest}`);
  }
  if (failures.length > 0) {
    fail(`${failures.length} PNG pair(s) exceeded thresholds`);
  }
}

main();
