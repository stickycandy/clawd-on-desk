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
    minImages: 1,
    minMotionRatio: 0,
    motionPairs: [],
    paths: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--min-images") {
      const value = Number(argv[++i]);
      if (!Number.isInteger(value) || value < 1) {
        fail(`invalid --min-images value: ${argv[i]}`);
      }
      args.minImages = value;
    } else if (arg === "--manifest") {
      const value = argv[++i];
      if (!value) {
        fail("--manifest expects an output path");
      }
      args.manifest = value;
    } else if (arg === "--min-motion-ratio") {
      const value = Number(argv[++i]);
      if (!Number.isFinite(value) || value < 0 || value > 1) {
        fail(`invalid --min-motion-ratio value: ${argv[i]}`);
      }
      args.minMotionRatio = value;
    } else if (arg === "--motion-pair") {
      const first = argv[++i];
      const second = argv[++i];
      if (!first || !second) {
        fail("--motion-pair expects two PNG paths");
      }
      args.motionPairs.push([first, second]);
    } else if (arg.startsWith("--")) {
      fail(`unknown option: ${arg}`);
    } else {
      args.paths.push(arg);
    }
  }

  if (args.paths.length === 0) {
    fail("expected one or more PNG files or directories");
  }
  return args;
}

function collectPngs(inputs) {
  const results = [];
  const stack = [...inputs];

  while (stack.length > 0) {
    const item = stack.pop();
    const stat = fs.statSync(item);
    if (stat.isDirectory()) {
      for (const entry of fs.readdirSync(item)) {
        stack.push(path.join(item, entry));
      }
    } else if (stat.isFile() && item.toLowerCase().endsWith(".png")) {
      results.push(item);
    }
  }

  return results.sort();
}

function parsePng(buffer, file) {
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
    if (end + 4 > buffer.length) {
      throw new Error(`${file}: truncated PNG chunk`);
    }

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

  if (width <= 0 || height <= 0 || bitDepth !== 8 || idat.length === 0) {
    throw new Error(`${file}: unsupported or empty PNG`);
  }

  const channelsByType = new Map([
    [0, 1],
    [2, 3],
    [4, 2],
    [6, 4],
  ]);
  const channels = channelsByType.get(colorType);
  if (!channels) {
    throw new Error(`${file}: unsupported PNG color type ${colorType}`);
  }

  const data = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const expected = (stride + 1) * height;
  if (data.length < expected) {
    throw new Error(`${file}: inflated data is shorter than expected`);
  }

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
      let value;
      switch (filter) {
        case 0:
          value = raw[x];
          break;
        case 1:
          value = raw[x] + left;
          break;
        case 2:
          value = raw[x] + up;
          break;
        case 3:
          value = raw[x] + Math.floor((left + up) / 2);
          break;
        case 4:
          value = raw[x] + paeth(left, up, upLeft);
          break;
        default:
          throw new Error(`${file}: unsupported PNG filter ${filter}`);
      }
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

function metrics(png) {
  const strideX = Math.max(1, Math.floor(png.width / 240));
  const strideY = Math.max(1, Math.floor(png.height / 160));
  const colors = new Set();
  let samples = 0;
  let minLum = 255;
  let maxLum = 0;
  let nonTransparent = 0;

  for (let y = 0; y < png.height; y += strideY) {
    const row = png.rows[y];
    for (let x = 0; x < png.width; x += strideX) {
      const index = x * png.channels;
      const rgba = readPixel(row, index, png.colorType);
      samples += 1;
      if (rgba.a > 0) nonTransparent += 1;
      const lum = Math.round((rgba.r * 299 + rgba.g * 587 + rgba.b * 114) / 1000);
      minLum = Math.min(minLum, lum);
      maxLum = Math.max(maxLum, lum);
      if (colors.size <= 4096) {
        colors.add(`${rgba.r},${rgba.g},${rgba.b},${rgba.a}`);
      }
    }
  }

  return {
    samples,
    uniqueColors: colors.size,
    luminanceRange: maxLum - minLum,
    nonTransparent,
  };
}

function readPixel(row, index, colorType) {
  if (colorType === 0) {
    const gray = row[index];
    return { r: gray, g: gray, b: gray, a: 255 };
  }
  if (colorType === 2) {
    return { r: row[index], g: row[index + 1], b: row[index + 2], a: 255 };
  }
  if (colorType === 4) {
    const gray = row[index];
    return { r: gray, g: gray, b: gray, a: row[index + 1] };
  }
  return { r: row[index], g: row[index + 1], b: row[index + 2], a: row[index + 3] };
}

function validate(file) {
  const buffer = fs.readFileSync(file);
  const png = parsePng(buffer, file);
  const m = metrics(png);
  const reasons = [];

  if (png.width < 64 || png.height < 64) reasons.push(`tiny image ${png.width}x${png.height}`);
  if (buffer.length < 1024) reasons.push(`tiny file ${buffer.length} bytes`);
  if (m.samples < 100) reasons.push("too few sampled pixels");
  if (m.uniqueColors < 16) reasons.push(`low color diversity ${m.uniqueColors}`);
  if (m.luminanceRange < 12) reasons.push(`low luminance range ${m.luminanceRange}`);
  if (m.nonTransparent === 0) reasons.push("fully transparent image");
  reasons.push(...targetedVisualChecks(file, png));

  if (reasons.length > 0) {
    throw new Error(`${file}: ${reasons.join(", ")}`);
  }
  return { file, width: png.width, height: png.height, ...m };
}

function targetedVisualChecks(file, png) {
  const normalized = file.split(path.sep).join("/");
  if (!/cloudling-desktop\/cloudling-desktop-(carrying|sweeping)\.png$/.test(normalized)) {
    return [];
  }

  const blue = centralBlueMetrics(png);
  if (blue.ratio < 0.01 || blue.count < 120) {
    return [`missing Cloudling body/glow blue pixels in center region (${blue.count}/${blue.total})`];
  }
  return [];
}

function centralBlueMetrics(png) {
  const x0 = Math.floor(png.width * 0.2);
  const x1 = Math.ceil(png.width * 0.8);
  const y0 = Math.floor(png.height * 0.2);
  const y1 = Math.ceil(png.height * 0.85);
  let total = 0;
  let count = 0;

  for (let y = y0; y < y1; y += 1) {
    const row = png.rows[y];
    for (let x = x0; x < x1; x += 1) {
      const rgba = readPixel(row, x * png.channels, png.colorType);
      if (rgba.a <= 10) continue;
      total += 1;
      if (rgba.b > 150 && rgba.b > rgba.r + 20 && rgba.b > rgba.g - 40) {
        count += 1;
      }
    }
  }

  return { count, total, ratio: total > 0 ? count / total : 0 };
}

function motionMetrics(firstFile, secondFile) {
  const first = parsePng(fs.readFileSync(firstFile), firstFile);
  const second = parsePng(fs.readFileSync(secondFile), secondFile);
  if (first.width !== second.width || first.height !== second.height) {
    throw new Error(`${firstFile} and ${secondFile}: screenshots have different dimensions`);
  }

  const x0 = Math.floor(first.width * 0.2);
  const x1 = Math.ceil(first.width * 0.8);
  const y0 = Math.floor(first.height * 0.2);
  const y1 = Math.ceil(first.height * 0.85);
  let changed = 0;
  let total = 0;
  let sum = 0;

  for (let y = y0; y < y1; y += 1) {
    const firstRow = first.rows[y];
    const secondRow = second.rows[y];
    for (let x = x0; x < x1; x += 1) {
      const a = readPixel(firstRow, x * first.channels, first.colorType);
      const b = readPixel(secondRow, x * second.channels, second.colorType);
      const delta = Math.abs(a.r - b.r)
        + Math.abs(a.g - b.g)
        + Math.abs(a.b - b.b)
        + Math.abs(a.a - b.a);
      if (delta > 24) changed += 1;
      sum += delta;
      total += 1;
    }
  }

  return {
    changed,
    total,
    ratio: total > 0 ? changed / total : 0,
    meanDelta: total > 0 ? sum / total : 0,
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const pngs = collectPngs(args.paths);
  if (pngs.length < args.minImages) {
    fail(`expected at least ${args.minImages} PNG files, found ${pngs.length}`);
  }

  const summaries = [];
  for (const file of pngs) {
    try {
      summaries.push(validate(file));
    } catch (error) {
      fail(error.message);
    }
  }

  const minUnique = Math.min(...summaries.map((item) => item.uniqueColors));
  const minLuminance = Math.min(...summaries.map((item) => item.luminanceRange));
  console.log(`Verified ${summaries.length} PNG screenshot(s). minUniqueColors=${minUnique} minLuminanceRange=${minLuminance}`);

  const motionSummaries = [];
  for (const [first, second] of args.motionPairs) {
    try {
      const motion = motionMetrics(first, second);
      motionSummaries.push({
        first,
        second,
        ...motion,
        minRatio: args.minMotionRatio,
        passed: motion.ratio >= args.minMotionRatio,
      });
      console.log(
        `Motion ${path.basename(first)} -> ${path.basename(second)} changed=${motion.changed}/${motion.total} `
        + `ratio=${motion.ratio.toFixed(4)} meanDelta=${motion.meanDelta.toFixed(2)}`
      );
      if (motion.ratio < args.minMotionRatio) {
        fail(`motion ratio ${motion.ratio.toFixed(4)} is below minimum ${args.minMotionRatio}`);
      }
    } catch (error) {
      fail(error.message);
    }
  }

  if (args.manifest) {
    const output = {
      generatedAt: new Date().toISOString(),
      inputs: args.paths,
      minImages: args.minImages,
      screenshots: summaries,
      motionPairs: motionSummaries,
    };
    fs.mkdirSync(path.dirname(args.manifest), { recursive: true });
    fs.writeFileSync(args.manifest, `${JSON.stringify(output, null, 2)}\n`);
    console.log(`Manifest: ${args.manifest}`);
  }
}

main();
