# Clawd Native

This directory contains a Swift native macOS port of the Clawd runtime. It is
structured as a Swift Package:

- `ClawdNativeCore`: testable runtime logic for agents, preferences, state,
  permission requests, local HTTP hook routes, theme manifests, diagnostics, and
  integration sync commands.
- `ClawdNative`: an AppKit executable with a transparent desktop pet window,
  status menu, settings window, sessions dashboard, and native permission
  bubbles.

Run from this directory:

```bash
swift test
swift run ClawdNative
```

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
  compact session HUD, terminal-focus buttons, and permission bubble.
- Eye tracking for SVG themes, theme-configured hitbox handling, drag/click
  reactions, and native mini-mode edge movement.
- Preference persistence in `~/.clawd/clawd-prefs-native.json`.
- Startup integration sync wrapper that calls the existing hook/plugin
  installers from the repository root for compatibility.
- Theme manifest loading/validation for the existing `theme.json` format, with
  real theme asset playback for built-in Clawd, Calico, and Cloudling assets.
- Mobile preview HTML at `GET /mobile-preview` and diagnostics at
  `GET /diagnostics`.
- Core runtime surfaces for Remote SSH tunnel command/lifecycle, Git updater
  commands, and Telegram approval status/summary formatting.
- Telegram approval sidecar using Bot API `sendMessage`/`getUpdates` callback
  flow, plus native Settings controls for token file and chat id.
- Git updater check/apply/relaunch flow exposed from the status menu.
- Permission suggestion buttons returning `updatedPermissions` for compatible
  approval hooks.

Not yet at Electron parity:

- Per-agent installer internals still delegate to the existing JS hook scripts;
  the macOS shell app is native, but the cross-agent hook payload scripts remain
  the shared compatibility layer.
- Remote SSH deploy/repair UI and Windows/Linux native packaging are explicitly
  out of scope for this pass.
- Per-pixel parity for every Electron animation timing/transition remains a
  tuning task, but the native feature paths are implemented.

This is intended as the native foundation to continue the rewrite without
touching the Electron implementation.
