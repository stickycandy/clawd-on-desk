import XCTest
@testable import ClawdNativeCore

final class AgentGateTests: XCTestCase {
  func testDefaultAgentGateValues() {
    let prefs = Preferences()
    XCTAssertTrue(AgentGate.isAgentEnabled(prefs, "claude-code"))
    XCTAssertTrue(AgentGate.isAgentPermissionsEnabled(prefs, "codex"))
    XCTAssertFalse(AgentGate.isAgentPermissionsEnabled(prefs, "pi"))
    XCTAssertEqual(AgentGate.codexPermissionMode(prefs), "intercept")
  }

  func testRegistryIncludesCurrentAgents() {
    let ids = Set(AgentRegistry.all.map(\.id))
    XCTAssertTrue(ids.isSuperset(of: [
      "claude-code",
      "codex",
      "copilot-cli",
      "gemini-cli",
      "antigravity-cli",
      "cursor-agent",
      "codebuddy",
      "kiro-cli",
      "kimi-cli",
      "qwen-code",
      "opencode",
      "pi",
      "openclaw",
      "hermes",
      "qoder"
    ]))
  }
}
