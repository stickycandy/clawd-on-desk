import XCTest
@testable import ClawdNativeCore

final class RuntimeSurfaceTests: XCTestCase {
  func testRemoteSSHTunnelCommandMatchesReverseForwardingShape() {
    let profile = RemoteSSHProfile(
      id: "p1",
      name: "prod",
      host: "example.com",
      user: "alice",
      port: 2200,
      identityFile: "/Users/alice/.ssh/id_ed25519"
    )
    XCTAssertEqual(RemoteSSHRuntime.tunnelCommand(profile: profile, localPort: 23334), [
      "ssh",
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=15",
      "-i",
      "/Users/alice/.ssh/id_ed25519",
      "-p",
      "2200",
      "-N",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=3",
      "-R",
      "127.0.0.1:23333:127.0.0.1:23334",
      "alice@example.com"
    ])
  }

  func testRemoteSSHScpArgsUseUppercasePortFlag() {
    let profile = RemoteSSHProfile(id: "p1", host: "example.com", user: "alice", port: 2200)
    XCTAssertEqual(RemoteSSHRuntime.buildScpArgs(profile: profile), [
      "-q",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=15",
      "-P",
      "2200"
    ])
  }

  func testRemoteSSHProbeCommandAcceptsNativeAndElectronServerHeaders() {
    let command = RemoteSSHRuntime.buildProbeCommand(remoteForwardPort: 23335)
    XCTAssertTrue(command.contains("23335"))
    XCTAssertTrue(command.contains("clawd-on-desk-native"))
    XCTAssertTrue(command.contains("clawd-on-desk"))
  }

  func testRemoteNodeProbeOutputParserRequiresAbsoluteSupportedNode() throws {
    let parsed = try XCTUnwrap(RemoteSSHRuntime.parseRemoteNodeProbeOutput("""
    CLAWD_REMOTE_NODE_BIN=/usr/local/bin/node
    CLAWD_REMOTE_NODE_VERSION=v20.11.1
    CLAWD_REMOTE_NODE_SOURCE=path
    """))
    XCTAssertEqual(parsed.nodeBin, "/usr/local/bin/node")
    XCTAssertEqual(parsed.version, "v20.11.1")
    XCTAssertEqual(parsed.source, "path")
    XCTAssertNil(RemoteSSHRuntime.parseRemoteNodeProbeOutput("""
    CLAWD_REMOTE_NODE_BIN=node
    CLAWD_REMOTE_NODE_VERSION=v20.11.1
    CLAWD_REMOTE_NODE_SOURCE=path
    """))
    XCTAssertNil(RemoteSSHRuntime.parseRemoteNodeProbeOutput("""
    CLAWD_REMOTE_NODE_BIN=/usr/bin/node
    CLAWD_REMOTE_NODE_VERSION=v12.22.0
    CLAWD_REMOTE_NODE_SOURCE=path
    """))
  }

  func testRemoteSSHProfileDecodesLegacyNameAndValidatesFields() throws {
    let data = Data(#"{"id":"p1","name":"legacy","host":"example.com"}"#.utf8)
    let profile = try JSONDecoder().decode(RemoteSSHProfile.self, from: data)
    XCTAssertEqual(profile.label, "legacy")
    XCTAssertEqual(profile.name, "legacy")
    XCTAssertEqual(profile.effectivePort, 22)
    if case .failure(let error) = RemoteSSHProfileValidator.validate(profile) {
      XCTFail("legacy profile should validate: \(error.message)")
    }

    let badHost = RemoteSSHProfile(id: "bad", label: "Bad", host: "-bad.example.com")
    if case .success = RemoteSSHProfileValidator.validate(badHost) {
      XCTFail("invalid host should fail validation")
    }

    let badPort = RemoteSSHProfile(id: "bad-port", label: "Bad", host: "example.com", remoteForwardPort: 12345)
    if case .success = RemoteSSHProfileValidator.validate(badPort) {
      XCTFail("invalid remote forward port should fail validation")
    }
  }

  func testRemoteSSHDeployManifestContainsSharedHookFiles() {
    XCTAssertTrue(RemoteSSHRuntime.hookFiles.contains("clawd-hook.js"))
    XCTAssertTrue(RemoteSSHRuntime.hookFiles.contains("codex-remote-monitor.js"))
    XCTAssertTrue(RemoteSSHRuntime.hookFiles.contains("copilot-install.js"))
  }

  func testUpdaterAheadBehindParser() {
    XCTAssertEqual(UpdaterRuntime.parseAheadBehind("ahead 0\tbehind 3")?.behind, 3)
    XCTAssertEqual(UpdaterRuntime.parseAheadBehind("ahead 2\tbehind 0")?.ahead, 2)
    XCTAssertNil(UpdaterRuntime.parseAheadBehind("bad"))
  }

  func testTerminalFocusAppleScriptContainsPid() {
    XCTAssertTrue(TerminalFocusManager.appleScript(pid: 1234).contains("unix id is 1234"))
  }

  func testTelegramApprovalTextContainsPermissionSummary() {
    let text = TelegramApprovalRuntime.approvalText(permission: PermissionRequest(agentId: "codex", sessionId: "s1", toolName: "Bash", toolInput: .object(["command": .string("ls")])))
    XCTAssertTrue(text.contains("codex"))
    XCTAssertTrue(text.contains("Bash"))
    XCTAssertTrue(text.contains("s1"))
  }

  func testTelegramCallbackRoundTripsPermissionDecision() throws {
    let id = UUID()
    let data = TelegramApprovalRuntime.callbackData(permissionId: id, action: .deny)
    let parsed = try XCTUnwrap(TelegramApprovalRuntime.parseCallbackData(data))
    XCTAssertEqual(parsed.permissionId, id)
    XCTAssertEqual(parsed.action, .deny)
    XCTAssertEqual(parsed.action.decision, .deny(message: "Denied from Telegram"))
  }

  func testTelegramSendMessagePayloadIncludesInlineKeyboard() throws {
    let id = UUID()
    let payload = TelegramApprovalRuntime.sendMessagePayload(
      permissionId: id,
      permission: PermissionRequest(agentId: "claude-code", sessionId: "s", toolName: "Edit"),
      config: TelegramApprovalConfig(enabled: true, chatId: "123")
    )
    XCTAssertEqual(payload["chat_id"] as? String, "123")
    let markup = try XCTUnwrap(payload["reply_markup"] as? [String: Any])
    let keyboard = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
    XCTAssertEqual(keyboard.first?.count, 3)
  }

  func testMobilePreviewEscapesSessionTitle() {
    let snapshot = StateSnapshot(currentState: .notification, sessions: [
      AgentSession(
        id: "s1",
        state: .notification,
        event: nil,
        updatedAt: Date(),
        startedAt: Date(),
        metadata: SessionMetadata(agentId: "codex", sessionTitle: "<script>")
      )
    ], updatedAt: Date())
    let html = MobilePreviewRuntime.html(snapshot: snapshot, preferences: Preferences())
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertFalse(html.contains("<script>"))
  }

  func testPreferencesDecodeNewSchemaWithDefaultsAndRuntimeAutoApprove() throws {
    let data = Data(#"{"theme":"calico","autoApproveAllPermissions":true}"#.utf8)
    let prefs = try JSONDecoder().decode(Preferences.self, from: data).validated()
    XCTAssertEqual(prefs.theme, "calico")
    XCTAssertFalse(prefs.autoApproveAllPermissions)
    XCTAssertEqual(prefs.shortcuts["togglePet"], "CommandOrControl+Shift+Alt+C")
    XCTAssertEqual(prefs.hardwareBuddy.namePrefix, "Clawstick")

    let encoded = try JSONEncoder().encode(Preferences(autoApproveAllPermissions: true))
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    XCTAssertNil(json?["autoApproveAllPermissions"])
  }

  func testShortcutDiagnosticsDetectsConflictsAndInvalidAccelerators() {
    let diagnostics = ShortcutDiagnostics.validate([
      "togglePet": "CommandOrControl+Shift+C",
      "permissionAllow": "CommandOrControl+Shift+C",
      "permissionDeny": "NoModifier"
    ])
    XCTAssertTrue(diagnostics.contains { $0.id == "shortcut-conflict:permissionAllow" && $0.status == "warning" })
    XCTAssertTrue(diagnostics.contains { $0.id == "shortcut:permissionDeny" && $0.status == "warning" })
  }
}
