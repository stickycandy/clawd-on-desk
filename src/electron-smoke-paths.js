"use strict";

const path = require("path");

const ELECTRON_ALLOW_PARALLEL_ENV = "CLAWD_ELECTRON_ALLOW_PARALLEL";
const ELECTRON_PREFS_PATH_ENV = "CLAWD_ELECTRON_PREFS_PATH";

function isTruthyEnvFlag(value) {
  if (!value) return false;
  return !/^(0|false)$/i.test(String(value));
}

function normalizeOverridePath(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? path.resolve(trimmed) : null;
}

function resolveElectronPrefsPath(userDataPath, options = {}) {
  const env = options.env || process.env;
  const override = normalizeOverridePath(env[ELECTRON_PREFS_PATH_ENV]);
  return override || path.join(userDataPath, "clawd-prefs.json");
}

module.exports = {
  ELECTRON_ALLOW_PARALLEL_ENV,
  ELECTRON_PREFS_PATH_ENV,
  isTruthyEnvFlag,
  normalizeOverridePath,
  resolveElectronPrefsPath,
};
