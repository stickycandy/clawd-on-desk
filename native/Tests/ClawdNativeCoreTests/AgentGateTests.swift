import XCTest
@testable import ClawdNativeCore

final class AgentGateTests: XCTestCase {
  func testDefaultAgentGateValues() {
    let prefs = Preferences()
    XCTAssertTrue(AgentGate.isAgentIntegrationInstalled(prefs, "claude-code"))
    XCTAssertTrue(AgentGate.isAgentIntegrationInstalled(prefs, "codex"))
    XCTAssertTrue(AgentGate.isAgentEnabled(prefs, "claude-code"))
    XCTAssertFalse(AgentGate.isAgentIntegrationInstalled(prefs, "copilot-cli"))
    XCTAssertFalse(AgentGate.isAgentEnabled(prefs, "copilot-cli"))
    XCTAssertFalse(AgentGate.shouldSyncAgentIntegration(prefs, "copilot-cli"))
    XCTAssertTrue(AgentGate.isAgentPermissionsEnabled(prefs, "codex"))
    XCTAssertFalse(AgentGate.isAgentPermissionsEnabled(prefs, "pi"))
    XCTAssertEqual(AgentGate.codexPermissionMode(prefs), "intercept")
  }

  func testIntegrationGateRequiresInstalledAndEnabled() {
    XCTAssertTrue(AgentGate.shouldSyncAgentIntegration(
      Preferences(agents: ["codex": .init(integrationInstalled: true, enabled: true)]),
      "codex"
    ))
    XCTAssertFalse(AgentGate.shouldSyncAgentIntegration(
      Preferences(agents: ["codex": .init(integrationInstalled: false, enabled: true)]),
      "codex"
    ))
    XCTAssertFalse(AgentGate.shouldSyncAgentIntegration(
      Preferences(agents: ["codex": .init(integrationInstalled: true, enabled: false)]),
      "codex"
    ))
  }

  func testLegacyAgentSettingsMissingInstalledFlagDefaultInstalled() throws {
    let data = Data(#"{"agents":{"copilot-cli":{"enabled":true,"permissionsEnabled":true}}}"#.utf8)
    let prefs = try JSONDecoder().decode(Preferences.self, from: data).validated()
    XCTAssertTrue(AgentGate.isAgentIntegrationInstalled(prefs, "copilot-cli"))
    XCTAssertTrue(AgentGate.shouldSyncAgentIntegration(prefs, "copilot-cli"))
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
      "codewhale",
      "opencode",
      "pi",
      "openclaw",
      "hermes",
      "qoder",
      "reasonix"
    ]))
    XCTAssertTrue(AgentRegistry.agent("codewhale")?.capabilities.stateOnly == true)
    XCTAssertTrue(AgentRegistry.agent("reasonix")?.capabilities.stateOnly == true)
    XCTAssertEqual(AgentRegistry.agent("codewhale")?.uninstallCommand, ["node", "hooks/codewhale-install.js", "--uninstall"])
    XCTAssertEqual(AgentRegistry.agent("reasonix")?.uninstallCommand, ["node", "hooks/reasonix-install.js", "--uninstall"])
  }
}
