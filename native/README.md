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

All smoke scripts print the generated screenshot path or smoke root. The
Session HUD smoke accepts an optional screenshot path, the cross-theme smoke
scripts accept an optional output directory argument, and the transition smoke
accepts an optional cycle count as its second argument. Each script also runs a
PNG integrity check over its captured screenshot set before exiting; the state
matrix verifier also guards Cloudling desktop carrying/sweeping against blank
scripted-SVG captures.

The native app listens on `127.0.0.1:23333-23337` and writes
`~/.clawd/runtime.json`, matching the Electron app's hook contract.

## Current Port Surface

Implemented:

- Local `/state`, `/permission`, `/sessions`, and health routes.
- Agent registry and default gates for Claude Code, Codex, Copilot, Gemini,
  Antigravity, Cursor Agent, CodeBuddy, Kiro, Kimi, Qwen, opencode, Pi,
  OpenClaw, Hermes, and Qoder.
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
  installers from the repository root for compatibility.
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
