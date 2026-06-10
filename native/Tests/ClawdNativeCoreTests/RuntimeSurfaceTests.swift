import XCTest
@testable import ClawdNativeCore

final class RuntimeSurfaceTests: XCTestCase {
  func testRemoteSSHTunnelCommandMatchesReverseForwardingShape() {
    let profile = RemoteSSHProfile(id: "p1", name: "prod", host: "example.com", user: "alice", port: 2200)
    XCTAssertEqual(RemoteSSHRuntime.tunnelCommand(profile: profile, localPort: 23334), [
      "ssh",
      "-N",
      "-R",
      "127.0.0.1:23333:127.0.0.1:23334",
      "-p",
      "2200",
      "alice@example.com"
    ])
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
}
