import XCTest
@testable import ClawdNativeCore

final class NativeIntegrationInstallerTests: XCTestCase {
  func testClaudeInstallerPreservesUserHooksAndAddsPermissionHTTPHook() throws {
    let fixture = try Fixture()
    try fixture.writeJSON(["hooks": [
      "SessionStart": [[
        "matcher": "",
        "hooks": [[
          "type": "command",
          "command": "echo user"
        ]]
      ]]
    ]], to: ".claude/settings.json")

    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/usr/local/bin/node", "CLAWD_CLAUDE_VERSION": "2.1.78"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "claude-code", preferences: Preferences(autoStartWithClaude: true), permissionPort: 23334))
    XCTAssertEqual(summary.status, "ok")

    let settings = try fixture.readJSON(".claude/settings.json")
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
    XCTAssertTrue(String(describing: sessionStart).contains("echo user"))
    XCTAssertTrue(String(describing: sessionStart).contains("auto-start.js"))
    XCTAssertTrue(String(describing: sessionStart).contains("clawd-hook.js"))

    let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
    XCTAssertTrue(String(describing: permission).contains("http://127.0.0.1:23334/permission"))
    XCTAssertFalse(String(describing: permission).contains("\"command\""))
    XCTAssertNotNil(hooks["PreCompact"])
    XCTAssertNotNil(hooks["PostCompact"])
    XCTAssertNotNil(hooks["StopFailure"])
  }

  func testCodexInstallerWritesHooksFeatureAndPermissionTimeout() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "codex", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")

    let config = try String(contentsOf: fixture.home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
    XCTAssertTrue(config.contains("[features]"))
    XCTAssertTrue(config.contains("hooks = true"))

    let settings = try fixture.readJSON(".codex/hooks.json")
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
    XCTAssertTrue(String(describing: permission).contains("codex-hook.js"))
    XCTAssertTrue(String(describing: permission).contains("timeout = 600"))
  }

  func testInstallerUsesNativeHookBinaryWhenAvailable() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let hookBin = fixture.root.appendingPathComponent("ClawdNativeHook")
    try Data("#!/bin/sh\n".utf8).write(to: hookBin)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookBin.path)
    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node", "CLAWD_NATIVE_HOOK_BIN": hookBin.path]
    )
    _ = try XCTUnwrap(installer.install(agentId: "codex", preferences: Preferences()))

    let settings = try fixture.readJSON(".codex/hooks.json")
    XCTAssertTrue(String(describing: settings).contains("ClawdNativeHook"))
    XCTAssertTrue(String(describing: settings).contains("codex-hook.js"))
  }

  func testQwenInstallerUsesMatcherlessEventsAndLongPermissionTimeout() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent(".qwen"), withIntermediateDirectories: true)
    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "qwen-code", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")

    let settings = try fixture.readJSON(".qwen/settings.json")
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let userPrompt = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
    XCTAssertNil(userPrompt.first?["matcher"])
    let preTool = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
    XCTAssertEqual(preTool.first?["matcher"] as? String, "*")
    let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
    XCTAssertTrue(String(describing: permission).contains("timeout = 600000"))
  }

  func testGeminiInstallerPreservesUserHooksAndNormalizesDisabledMarker() throws {
    let fixture = try Fixture()
    try fixture.writeJSON([
      "hooksConfig": [
        "disabled": ["node /tmp/gemini-hook.js BeforeTool", "other"]
      ],
      "hooks": [
        "BeforeTool": [[
          "matcher": "*",
          "hooks": [
            [
              "type": "command",
              "command": "echo user"
            ],
            [
              "name": "clawd",
              "type": "command",
              "command": "node /old/gemini-hook.js BeforeTool"
            ]
          ]
        ]]
      ]
    ], to: ".gemini/settings.json")

    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "gemini-cli", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")

    let settings = try fixture.readJSON(".gemini/settings.json")
    let hooksConfig = try XCTUnwrap(settings["hooksConfig"] as? [String: Any])
    XCTAssertEqual(hooksConfig["disabled"] as? [String], ["clawd", "other"])

    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let beforeTool = try XCTUnwrap(hooks["BeforeTool"] as? [[String: Any]])
    XCTAssertTrue(String(describing: beforeTool).contains("echo user"))
    XCTAssertTrue(String(describing: beforeTool).contains("gemini-hook.js"))
    XCTAssertTrue(String(describing: beforeTool).contains("/opt/homebrew/bin/node"))
    let preCompress = try XCTUnwrap(hooks["PreCompress"] as? [[String: Any]])
    XCTAssertTrue(String(describing: preCompress).contains("PreCompress"))
  }

  func testCodewhaleInstallerPreservesUserHooksAndUninstallsManagedSections() throws {
    let fixture = try Fixture()
    try fixture.writeText("""
    [hooks]
    enabled = false

    [[hooks.hooks]]
    event = "session_start"
    command = '''echo user'''

    [[hooks.hooks]]
    # managed by clawd-on-desk
    event = "message_submit"
    command = '''node /old/codewhale-hook.js message_submit'''
    background = true
    timeout_secs = 5
    """, to: ".codewhale/config.toml")

    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "codewhale", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")

    let installed = try fixture.readText(".codewhale/config.toml")
    XCTAssertTrue(installed.contains("enabled = true"))
    XCTAssertTrue(installed.contains("echo user"))
    XCTAssertFalse(installed.contains("/old/codewhale-hook.js"))
    XCTAssertEqual(installed.components(separatedBy: "codewhale-hook.js").count - 1, 7)
    XCTAssertTrue(installed.contains(#"event = "session_end""#))
    XCTAssertTrue(installed.contains("timeout_secs = 30"))
    XCTAssertTrue(installed.contains("continue_on_error = true"))
    XCTAssertTrue(installed.contains(#""/opt/homebrew/bin/node" "\#(fixture.projectRoot.path)/hooks/codewhale-hook.js" "session_start""#))

    let uninstall = try XCTUnwrap(installer.uninstall(agentId: "codewhale"))
    XCTAssertEqual(uninstall.status, "ok")
    XCTAssertEqual(uninstall.removed, 7)
    let uninstalled = try fixture.readText(".codewhale/config.toml")
    XCTAssertTrue(uninstalled.contains("echo user"))
    XCTAssertFalse(uninstalled.contains("codewhale-hook.js"))
  }

  func testReasonixInstallerPreservesUserHooksAndReplacesManagedEntry() throws {
    let fixture = try Fixture()
    try fixture.writeJSON([
      "hooks": [
        "PreToolUse": [
          [
            "match": "user",
            "command": "echo user"
          ],
          [
            "match": "",
            "command": "node /old/reasonix-hook.js",
            "timeout": 5
          ]
        ]
      ]
    ], to: ".reasonix/settings.json")

    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "reasonix", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")

    let settings = try fixture.readJSON(".reasonix/settings.json")
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let preTool = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
    XCTAssertTrue(String(describing: preTool).contains("echo user"))
    XCTAssertTrue(String(describing: preTool).contains("reasonix-hook.js"))
    XCTAssertTrue(String(describing: preTool).contains("/opt/homebrew/bin/node"))
    XCTAssertFalse(String(describing: preTool).contains("timeout"))
    let preCompact = try XCTUnwrap(hooks["PreCompact"] as? [[String: Any]])
    XCTAssertTrue(String(describing: preCompact).contains("PreCompact"))
  }

  func testQoderInstallerPreservesUserHooksAndNormalizesDisabledMarker() throws {
    let fixture = try Fixture()
    try fixture.writeJSON([
      "hooksConfig": [
        "disabled": ["node /tmp/qoder-hook.js PreToolUse", "other"]
      ],
      "hooks": [
        "PermissionRequest": [[
          "matcher": "*",
          "hooks": [
            [
              "type": "command",
              "command": "echo user"
            ],
            [
              "name": "clawd",
              "type": "command",
              "command": "node /old/qoder-hook.js PermissionRequest"
            ]
          ]
        ]]
      ]
    ], to: ".qoder/settings.json")

    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "qoder", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")

    let settings = try fixture.readJSON(".qoder/settings.json")
    let hooksConfig = try XCTUnwrap(settings["hooksConfig"] as? [String: Any])
    XCTAssertEqual(hooksConfig["disabled"] as? [String], ["clawd", "other"])

    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
    XCTAssertTrue(String(describing: permission).contains("echo user"))
    XCTAssertTrue(String(describing: permission).contains("qoder-hook.js"))
    XCTAssertTrue(String(describing: permission).contains("/opt/homebrew/bin/node"))
    let denied = try XCTUnwrap(hooks["PermissionDenied"] as? [[String: Any]])
    XCTAssertTrue(String(describing: denied).contains("PermissionDenied"))
  }

  func testCopilotInstallerSkipsPermissionWhenUserHookExists() throws {
    let fixture = try Fixture()
    let copilotHome = fixture.home.appendingPathComponent(".copilot")
    try FileManager.default.createDirectory(at: copilotHome.appendingPathComponent("hooks"), withIntermediateDirectories: true)
    try fixture.writeJSON(["hooks": [
      "permissionRequest": [[
        "type": "command",
        "bash": "security-audit"
      ]]
    ]], to: ".copilot/settings.json")

    let installer = NativeIntegrationInstaller(
      projectRoot: fixture.projectRoot,
      homeDirectory: fixture.home,
      environment: ["CLAWD_NODE_BIN": "/opt/homebrew/bin/node"]
    )
    let summary = try XCTUnwrap(installer.install(agentId: "copilot-cli", preferences: Preferences()))
    XCTAssertEqual(summary.status, "ok")
    XCTAssertTrue(summary.warnings.contains { $0.contains("permissionRequest left untouched") })

    let hooksFile = try fixture.readJSON(".copilot/hooks/hooks.json")
    let hooks = try XCTUnwrap(hooksFile["hooks"] as? [String: Any])
    XCTAssertNotNil(hooks["sessionStart"])
    let permission = hooks["permissionRequest"] as? [[String: Any]]
    XCTAssertTrue(permission == nil || String(describing: permission).contains("copilot-hook.js") == false)
  }
}

private final class Fixture {
  let root: URL
  let home: URL
  let projectRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-tests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    projectRoot = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("hooks"), withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func writeJSON(_ object: [String: Any], to relativePath: String) throws {
    let url = home.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }

  func readJSON(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent(relativePath))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func writeText(_ text: String, to relativePath: String) throws {
    let url = home.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func readText(_ relativePath: String) throws -> String {
    try String(contentsOf: home.appendingPathComponent(relativePath), encoding: .utf8)
  }
}
