# Clawd Native

This directory contains a Swift native macOS port of the Clawd runtime. It is
structured as a Swift Package:

- `ClawdNativeCore`: testable runtime logic for agents, preferences, state,
  permission requests, local HTTP hook routes, theme manifests, diagnostics, and
  integration sync commands.
- `ClawdNative`: an AppKit executable with a transparent desktop pet window,
  status menu, settings window, sessions dashboard, native permission bubbles,
  and passive notification bubbles.

Run from this directory:

```bash
swift test
swift run ClawdNative
```

For an isolated local smoke run that avoids touching the normal `~/.clawd`
files or startup hook sync:

```bash
CLAWD_NATIVE_PREFS_PATH=/tmp/clawd-native-prefs.json \
CLAWD_NATIVE_RUNTIME_PATH=/tmp/clawd-native-runtime.json \
CLAWD_NATIVE_SKIP_INTEGRATION_SYNC=1 \
swift run ClawdNative
```

For a repeatable Session HUD click-reveal smoke that starts an isolated native
app, injects a live Codex session, clicks the pet, and captures a screenshot:

```bash
bash scripts/smoke-session-hud-click.sh
```

For a broader visual smoke that captures desktop and mini states across Clawd,
Calico, and Cloudling:

```bash
bash scripts/smoke-cross-theme-visuals.sh
```

For timed transition smoke screenshots across those same themes and modes:

```bash
bash scripts/smoke-cross-theme-transitions.sh
```

For a state matrix smoke that captures the desktop and mini state set across
Clawd, Calico, and Cloudling:

```bash
bash scripts/smoke-state-matrix.sh
```

For a targeted Cloudling scripted-SVG check that waits past the AppKit fallback
grace period and verifies WebKit frame-to-frame motion:

```bash
bash scripts/smoke-cloudling-webkit-motion.sh
```

For a targeted Clawd playback-only SVG check that verifies non-scripted inline
SVG animation is not stuck on a static image-channel frame:

```bash
bash scripts/smoke-clawd-svg-motion.sh
```

For a targeted Calico APNG check that verifies image-channel APNG playback is
not stuck on a static fallback frame:

```bash
bash scripts/smoke-calico-apng-motion.sh
```

To run the targeted motion checks for all three renderer channels together:

```bash
bash scripts/smoke-motion-suite.sh
```

To run a review bundle that groups selected smoke suites and writes
`summary.md`, `summary.json`, and `review-manifest.json`:

```bash
bash scripts/smoke-review-bundle.sh /tmp/clawd-native-review motion visual state
```

All smoke scripts print the generated screenshot path or smoke root. The
Session HUD smoke accepts an optional screenshot path and optional manifest path,
the cross-theme smoke scripts accept an optional output directory argument, and
the transition smoke accepts an optional cycle count as its second argument. Each
script also runs a PNG integrity check over its captured screenshot set before
exiting; the state matrix verifier also guards Cloudling desktop
carrying/sweeping against blank scripted-SVG captures. The Session HUD,
cross-theme visual, state matrix, transition, and targeted motion smokes also
write `manifest.json` files with screenshot metrics and motion ratios.

To summarize one or more smoke output directories into a review table, with an
optional machine-readable sidecar:

```bash
node scripts/summarize-smoke-manifests.js \
  --json /tmp/clawd-native-motion-summary.json \
  /tmp/clawd-native-motion-suite
```

The review bundle accepts `motion`, `visual`, `state`, `transitions`, `hud`,
`desktop-compare`, or `summary` suite names. If no suite names are passed, it uses
`CLAWD_NATIVE_REVIEW_SUITES`, defaulting to all suites; transition smoke cycles
default to 1 and can be changed with `CLAWD_NATIVE_REVIEW_TRANSITION_CYCLES`.
Set `CLAWD_NATIVE_REVIEW_MIN_MOTION_RATIO` to make the generated summary fail if
any motion manifest reports a lower frame-to-frame change ratio.
Set `CLAWD_NATIVE_VISUAL_SCOPE=desktop` to capture only the native visual smoke
desktop subset (`all` remains the default; `mini` is also accepted).
Set `CLAWD_NATIVE_VISUAL_CAPTURE_REGION=x,y,w,h` to crop native visual smoke
screenshots to a fixed desktop region selected for the current display layout.
Set `CLAWD_NATIVE_REVIEW_COMPARE_BASELINE` to an Electron baseline PNG directory
with matching relative paths to also emit `compare-manifest.json` from the
per-pixel comparator. Set `CLAWD_NATIVE_REVIEW_COMPARE_TARGET=visual` to compare
against the review bundle's visual suite output instead of the whole review
root; absolute paths are also accepted. Optional
`CLAWD_NATIVE_REVIEW_COMPARE_MAX_CHANGED_RATIO` and
`CLAWD_NATIVE_REVIEW_COMPARE_MAX_MEAN_DELTA` values make that comparison fail on
drift beyond the chosen thresholds. The top-level `review-manifest.json` records
final `passed`, `summaryStatus`, and `compareStatus` fields after all threshold
checks finish.

To compare two PNG screenshots or two matching screenshot directories for
per-pixel parity:

```bash
node scripts/compare-smoke-screenshots.js \
  --manifest /tmp/native-parity-compare.json \
  /tmp/electron-baseline /tmp/native-smoke
```

Electron baseline smoke runs can isolate app state from the user's normal
Clawd profile by launching Electron with `CLAWD_ELECTRON_PREFS_PATH` and
`CLAWD_ELECTRON_RUNTIME_PATH` set to temporary JSON paths. Add
`CLAWD_ELECTRON_SKIP_INTEGRATION_SYNC=1` so startup does not auto-edit user
hook/plugin configs. When an existing Clawd instance may be running, add
`CLAWD_ELECTRON_ALLOW_PARALLEL=1` for a smoke-only parallel instance. Together
these match the native smoke scripts' isolated prefs/runtime/no-sync model.

To verify the isolated Electron launch contract before capturing baselines:

```bash
bash scripts/smoke-electron-isolated-launch.sh
```

To capture Electron desktop baseline screenshots for Clawd, Calico, and
Cloudling idle / working / notification states, stored as desktop idle /
working / alert paths to match the native cross-theme visual smoke:

```bash
bash scripts/smoke-electron-desktop-baseline.sh /tmp/clawd-electron-baseline
```

To run the Electron baseline, native desktop-only visual smoke, and per-pixel
directory comparison as one desktop parity bundle:

```bash
bash scripts/smoke-electron-native-desktop-compare.sh /tmp/clawd-desktop-compare
```

Comparison manifests include aggregate max changed ratio / mean delta and a
`failures` list for rows that exceed the configured thresholds.

The native app listens on `127.0.0.1:23333-23337` and writes
`~/.clawd/runtime.json`, matching the Electron app's hook contract.

## Current Port Surface

Implemented:

- Local `/state`, `/permission`, `/sessions`, and health routes.
- Agent registry and default gates for Claude Code, Codex, Copilot, Gemini,
  Antigravity, Cursor Agent, CodeBuddy, Kiro, Kimi, Qwen, opencode, Pi,
  CodeWhale, OpenClaw, Hermes, Qoder, and Reasonix.
- State priority, session tracking, DND behavior, stale cleanup, HUD snapshot
  data, and permission notification state.
- Native AppKit desktop pet, status menu, settings window, sessions dashboard,
  compact session HUD with mini-mode visibility and click-reveal plus
  hot-zone/grace auto-hide parity, terminal-focus buttons, permission bubbles,
  and passive notification bubbles.
- Permission bubble stacking honors bubble follow mode, hide/enable policy, and
  permission/passive notification auto-close timing.
- Settings exposes runtime controls for sound volume, dock flash timing, and
  permission/notification/update bubble auto-close timing.
- Eye tracking for SVG themes, global cursor polling, Cloudling pointer bridge,
  WebKit inline SVG / image rendering with AppKit fallback, JavaScriptCore
  first-frame fallback for trusted scripted SVGs, theme-configured hitbox
  handling, drag/click reactions, fallback eye-follow, and native mini-mode menu
  crabwalk / offscreen handoff entry, exit parabola, settings toggle,
  drag-to-edge snapping, hover peek, and internal display seam clipping.
- Theme idle animations, mouse-idle sleep sequencing, wake transitions, and
  theme timing refresh on preference changes.
- Preference persistence in `~/.clawd/clawd-prefs-native.json`.
- Startup integration sync wrapper that calls the existing hook/plugin
  installers from the repository root for compatibility, gated by native
  `integrationInstalled` and `enabled` agent preferences.
- Theme manifest loading/validation for the existing `theme.json` format,
  including rendering, trusted scripted SVG, and layered eye-tracking metadata.
- Theme `transitions` fade-in/fade-out support during native asset swaps.
- Theme `objectScale` sizing, per-file scale, and per-file offset support for
  native SVG/APNG placement parity.
- Theme `layout`, `fileViewBoxes`, mini timing, and mini edge offset metadata
  for normalized native placement parity.
- Theme sound mappings and native completion / notification sound playback,
  honoring mute, volume, DND, and cooldown preferences.
- Mobile preview HTML at `GET /mobile-preview` when `mobilePreviewEnabled` is
  on, and diagnostics at `GET /diagnostics`.
- Remote SSH profile settings, tunnel lifecycle, health probe, deploy/repair
  hooks flow, Codex remote monitor lifecycle, and status diagnostics.
- Telegram approval sidecar using Bot API `sendMessage`/`getUpdates` callback
  flow, plus native Settings controls for token file and chat id.
- Git updater check/apply/relaunch flow exposed from the status menu, with a
  native update bubble for available, success, and failure states.
- Permission suggestion buttons returning `updatedPermissions` for compatible
  approval hooks.

Not yet at Electron parity:

- Per-agent installer internals still delegate to the existing JS hook scripts;
  the macOS shell app is native, but the cross-agent hook payload scripts remain
  the shared compatibility layer.
- Live visual QA has passed for desktop Calico/Cloudling cursor movement,
  Cloudling mini idle/working/alert, Cloudling DND mini-sleep enter/exit,
  Calico mini idle/alert/working-fallback/DND mini-sleep enter/exit, and Clawd
  mini cold-start idle/working/alert/DND mini-sleep enter/exit, plus Session
  HUD mini-mode hide/restore, unpinned default-hide, and click-reveal. A
  repeatable cross-theme visual smoke now captures desktop idle/working/alert
  and mini idle/working for Clawd, Calico, and Cloudling. A timed transition
  smoke captures mid-transition and stable frames for desktop and mini
  idle/working/notification cycles across those themes. A state-matrix smoke
  covers desktop idle/thinking/working/juggling/carrying/attention/sweeping/
  notification/error and mini idle/thinking/working/attention/notification/error
  across all three built-in themes. These screenshot smokes now automatically
  validate PNG dimensions, color diversity, luminance range, transparency, and
  Cloudling scripted-state body/glow presence before passing. A targeted
  Cloudling WebKit motion smoke verifies trusted scripted SVGs are not only
  static fallback frames after the fallback grace period, and a targeted Clawd
  SVG motion smoke verifies playback-only SVGs animate through the inline
  WebKit path. A targeted Calico APNG motion smoke verifies image-channel APNG
  playback is not static. Session HUD click-reveal hot-zone/grace auto-hide has
  native unit coverage.
- Repeated manual transition review and per-pixel parity for every Electron
  animation remain tuning tasks.

This is intended as the native foundation to continue the rewrite without
touching the Electron implementation.
