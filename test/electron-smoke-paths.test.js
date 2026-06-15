const { describe, it } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const {
  ELECTRON_PREFS_PATH_ENV,
  resolveElectronPrefsPath,
} = require("../src/electron-smoke-paths");

describe("electron smoke path helpers", () => {
  it("uses the normal userData prefs path by default", () => {
    const userData = path.join("tmp", "clawd-user-data");
    assert.strictEqual(
      resolveElectronPrefsPath(userData, { env: {} }),
      path.join(userData, "clawd-prefs.json")
    );
  });

  it("uses CLAWD_ELECTRON_PREFS_PATH when set", () => {
    const override = path.join("tmp", "isolated", "prefs.json");
    assert.strictEqual(
      resolveElectronPrefsPath("/real/user-data", {
        env: { [ELECTRON_PREFS_PATH_ENV]: override },
      }),
      path.resolve(override)
    );
  });

  it("ignores blank CLAWD_ELECTRON_PREFS_PATH values", () => {
    assert.strictEqual(
      resolveElectronPrefsPath("/real/user-data", {
        env: { [ELECTRON_PREFS_PATH_ENV]: "  " },
      }),
      path.join("/real/user-data", "clawd-prefs.json")
    );
  });
});
