"use strict";

const path = require("path");

const ELECTRON_PREFS_PATH_ENV = "CLAWD_ELECTRON_PREFS_PATH";

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
  ELECTRON_PREFS_PATH_ENV,
  normalizeOverridePath,
  resolveElectronPrefsPath,
};
