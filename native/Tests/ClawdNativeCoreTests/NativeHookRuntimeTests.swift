import XCTest
@testable import ClawdNativeCore

final class NativeHookRuntimeTests: XCTestCase {
  func testClaudePreToolUseTaskBecomesSubagentStart() throws {
    let payload = Data(#"{"session_id":"s1","cwd":"/repo","tool_name":"Task","tool_input":{"description":"work"}}"#.utf8)
    let route = NativeHookRuntime(agentId: "claude-code", event: "PreToolUse", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "claude-code")
    XCTAssertEqual(body.string("state"), "juggling")
    XCTAssertEqual(body.string("event"), "SubagentStart")
    XCTAssertEqual(body.string("tool_name"), "Task")
    XCTAssertNotNil(body.string("tool_input_fingerprint"))
  }

  func testCodexPermissionBuildsPermissionRoute() throws {
    let payload = Data(#"{"hook_event_name":"PermissionRequest","session_id":"abc","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/repo"}"#.utf8)
    let route = NativeHookRuntime(agentId: "codex", event: "PermissionRequest", environment: [:]).route(stdin: payload)
    guard case .permission(.object(let body)) = route else {
      return XCTFail("expected permission route")
    }
    XCTAssertEqual(body.string("agent_id"), "codex")
    XCTAssertEqual(body.string("session_id"), "codex:abc")
    XCTAssertEqual(body.string("tool_name"), "Bash")
    XCTAssertEqual(body.string("hook_source"), "codex-official")
  }

  func testCopilotPermissionAcceptsCamelCasePayload() throws {
    let payload = Data(#"{"sessionId":"s1","toolName":"edit","toolInput":{"path":"a.swift"},"permissionSuggestions":[]}"#.utf8)
    let route = NativeHookRuntime(agentId: "copilot-cli", event: "permissionRequest", environment: [:]).route(stdin: payload)
    guard case .permission(.object(let body)) = route else {
      return XCTFail("expected permission route")
    }
    XCTAssertEqual(body.string("agent_id"), "copilot-cli")
    XCTAssertEqual(body.string("session_id"), "copilot-cli:s1")
    XCTAssertEqual(body.string("tool_name"), "edit")
    XCTAssertNotNil(body["permission_suggestions"])
  }
}

private extension [String: JSONValue] {
  func string(_ key: String) -> String? {
    if case .string(let value)? = self[key] { return value }
    return nil
  }
}
