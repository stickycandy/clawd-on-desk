# Native Feature Parity Map

| Electron area | Swift native module | Status |
| --- | --- | --- |
| `src/server.js`, `/state`, `/permission` | `LocalHTTPServer` | Core hook protocol implemented |
| `src/state.js`, `state-priority.js` | `StateEngine`, `ClawdState` | Core priority/session/DND implemented |
| `agents/registry.js` | `AgentRegistry` | Agent ids/capabilities/install commands mirrored |
| `src/prefs.js`, `src/agent-gate.js` | `Preferences`, `PreferencesStore`, `AgentGate` | Core schema/gates implemented |
| `src/session-alias.js` | `SessionAliasKeys` | Keying, Kiro cwd scope, TTL pruning implemented |
| `src/permission.js` | `PermissionCoordinator`, `PermissionBubbleWindowController` | Native bubble, suggestions, no-decision, Telegram remote approval implemented |
| Desktop pet render/input windows | `PetWindowController`, `PetAssetView` | Native transparent window, real theme playback, eye tracking, hitTest hitboxes, drag/click reactions implemented |
| Session HUD/Dashboard | `SessionHUDWindowController`, `DashboardWindowController`, `StateSnapshot` | HUD and Dashboard implemented |
| Settings UI | `SettingsWindowController` | Agent, bubble, theme, mini mode, Telegram, and runtime summary controls implemented |
| Theme loader | `ThemeManifest`, `ThemeRuntime` | Manifest validation, built-in asset resolution, hitbox/reaction/eye metadata implemented |
| Hook/plugin sync | `IntegrationManager` | Delegates to existing scripts for compatibility |
| Remote SSH | `RemoteSSHProfile`, `RemoteSSHRuntime` | Tunnel/deploy command construction and process lifecycle implemented; settings deploy UI pending |
| Updater | `UpdaterRuntime`, `UpdaterService` | Git-mode check/apply/relaunch implemented |
| Telegram approval | `TelegramApprovalRuntime`, `TelegramApprovalSidecar` | Config validation, approval message, inline keyboard callback polling implemented |
| Mobile preview/PWA | `MobilePreviewRuntime`, `/mobile-preview` | Native preview HTML route implemented |
| Terminal focus | `TerminalFocusManager` | macOS PID focus path implemented |
| Mini mode | `PetWindowController`, `PetAssetView`, `StatusMenuController` | State remapping and edge movement implemented |

Out of scope for the current native pass: Remote SSH UI/runtime expansion beyond
the already-present command surface, and Windows/Linux native packaging.
