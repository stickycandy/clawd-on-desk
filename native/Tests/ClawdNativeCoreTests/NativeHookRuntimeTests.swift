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

  func testCodexPermissionUsesTranscriptSessionMeta() throws {
    let fixture = try HookFixture()
    let transcript = fixture.root.appendingPathComponent("rollout-2026-06-12T10-00-00-019eb9ff-1111-7222-8333-abcdefabcdef.jsonl")
    try """
    {"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"agent_role":"worker"}}},"originator":"Codex Desktop","agent_id":"upstream-agent-id","agent_type":"worker"}}
    """.write(to: transcript, atomically: true, encoding: .utf8)
    let payload = Data(#"{"hook_event_name":"PermissionRequest","transcript_path":"\#(transcript.path)","tool_name":"Bash","tool_input":{"command":"npm test"},"source":"vscode"}"#.utf8)
    let route = NativeHookRuntime(agentId: "codex", event: "PermissionRequest", environment: [:]).route(stdin: payload)
    guard case .permission(.object(let body)) = route else {
      return XCTFail("expected permission route")
    }
    XCTAssertEqual(body.string("session_id"), "codex:019eb9ff-1111-7222-8333-abcdefabcdef")
    XCTAssertEqual(body.string("codex_session_role"), "subagent")
    XCTAssertEqual(body.string("codex_originator"), "Codex Desktop")
    XCTAssertEqual(body.string("codex_source"), "vscode")
    XCTAssertEqual(body.string("codex_subagent_id"), "upstream-agent-id")
    XCTAssertEqual(body.string("codex_agent_type"), "worker")
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

  func testGeminiAfterAgentStaysNeutralIdleEvent() throws {
    let payload = Data(#"{"session_id":"s1","cwd":"/repo"}"#.utf8)
    let route = NativeHookRuntime(agentId: "gemini-cli", event: "AfterAgent", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "gemini-cli")
    XCTAssertEqual(body.string("session_id"), "gemini:s1")
    XCTAssertEqual(body.string("state"), "idle")
    XCTAssertEqual(body.string("event"), "AfterAgent")
    XCTAssertEqual(body.string("cwd"), "/repo")
  }

  func testGeminiAfterToolErrorBecomesPostToolUseFailure() throws {
    let payload = Data(#"{"session_id":"s1","tool_response":{"error":"failed"}}"#.utf8)
    let route = NativeHookRuntime(agentId: "gemini-cli", event: "AfterTool", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("state"), "error")
    XCTAssertEqual(body.string("event"), "PostToolUseFailure")
  }

  func testGeminiSessionEndClearBecomesSweeping() throws {
    let payload = Data(#"{"session_id":"s1","reason":"clear"}"#.utf8)
    let route = NativeHookRuntime(agentId: "gemini-cli", event: "SessionEnd", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("state"), "sweeping")
    XCTAssertEqual(body.string("event"), "SessionEnd")
  }

  func testGeminiPreCompressPreservesState() throws {
    let payload = Data(#"{"hook_event_name":"PreCompress","session_id":"gemini:s1"}"#.utf8)
    let route = NativeHookRuntime(agentId: "gemini-cli", event: "BeforeTool", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("session_id"), "gemini:s1")
    XCTAssertEqual(body.string("state"), "idle")
    XCTAssertEqual(body.string("event"), "PreCompress")
    XCTAssertEqual(body.bool("preserve_state"), true)
  }

  func testGeminiStdoutUsesPayloadHookEventOverride() throws {
    let payload = Data(#"{"hook_event_name":"PreCompress"}"#.utf8)
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "gemini-cli", event: "BeforeTool", stdin: payload), "{}")
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "gemini-cli", event: "AfterTool"), #"{"decision":"allow"}"#)
  }

  func testAntigravityRouteUsesConversationWorkspaceAndStdout() throws {
    let payload = Data(#"{"hookEventName":"PostToolUse","conversationId":"c1","workspacePaths":["/repo"],"toolCall":{"args":{"Cwd":"/tool-cwd"}}}"#.utf8)
    let route = NativeHookRuntime(agentId: "antigravity-cli", event: "unknown", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "antigravity-cli")
    XCTAssertEqual(body.string("session_id"), "antigravity:c1")
    XCTAssertEqual(body.string("state"), "working")
    XCTAssertEqual(body.string("event"), "PostToolUse")
    XCTAssertEqual(body.string("cwd"), "/tool-cwd")
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "antigravity-cli", event: "Stop"), #"{"decision":"allow"}"#)
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "antigravity-cli", event: "PreInvocation"), "{}")
  }

  func testAntigravityRouteMapsFailuresAndBusyStop() throws {
    let failedTool = Data(#"{"hookEventName":"PostToolUse","conversationId":"c1","error":"boom"}"#.utf8)
    let failedToolRoute = NativeHookRuntime(agentId: "antigravity-cli", event: "PostToolUse", environment: [:]).route(stdin: failedTool)
    guard case .state(.object(let failedToolBody)) = failedToolRoute else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(failedToolBody.string("state"), "error")
    XCTAssertEqual(failedToolBody.string("event"), "PostToolUseFailure")

    let busyStop = Data(#"{"hookEventName":"Stop","conversationId":"c1","fullyIdle":false}"#.utf8)
    let busyStopRoute = NativeHookRuntime(agentId: "antigravity-cli", event: "Stop", environment: [:]).route(stdin: busyStop)
    guard case .state(.object(let busyStopBody)) = busyStopRoute else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(busyStopBody.string("state"), "working")
    XCTAssertEqual(busyStopBody.string("event"), "PostToolUse")
  }

  func testKimiRouteMapsExplicitPermissionAndSuspectMode() throws {
    let explicit = Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo","tool_name":"shell","requires_approval":true}"#.utf8)
    let explicitRoute = NativeHookRuntime(agentId: "kimi-cli", event: "unknown", environment: [:]).route(stdin: explicit)
    guard case .state(.object(let explicitBody)) = explicitRoute else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(explicitBody.string("agent_id"), "kimi-cli")
    XCTAssertEqual(explicitBody.string("session_id"), "kimi-cli:s1")
    XCTAssertEqual(explicitBody.string("state"), "notification")
    XCTAssertEqual(explicitBody.string("event"), "PermissionRequest")
    XCTAssertEqual(explicitBody.string("tool_name"), "shell")
    XCTAssertEqual(explicitBody.string("cwd"), "/repo")

    let suspect = Data(#"{"hook_event_name":"PreToolUse","session_id":"s2","tool_name":"write_file"}"#.utf8)
    let suspectRoute = NativeHookRuntime(
      agentId: "kimi-cli",
      event: "unknown",
      environment: ["CLAWD_KIMI_PERMISSION_MODE": "suspect"]
    ).route(stdin: suspect)
    guard case .state(.object(let suspectBody)) = suspectRoute else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(suspectBody.string("state"), "working")
    XCTAssertEqual(suspectBody.string("event"), "PreToolUse")
    XCTAssertEqual(suspectBody.bool("permission_suspect"), true)
  }

  func testCursorRouteUsesHookEventPayloadWorkspaceAndDisplayHint() throws {
    let payload = Data(#"{"hook_event_name":"preToolUse","conversation_id":"c1","workspace_roots":["/repo"],"tool_name":"Shell"}"#.utf8)
    let route = NativeHookRuntime(agentId: "cursor-agent", event: "unknown", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "cursor-agent")
    XCTAssertEqual(body.string("session_id"), "c1")
    XCTAssertEqual(body.string("state"), "working")
    XCTAssertEqual(body.string("event"), "PreToolUse")
    XCTAssertEqual(body.string("cwd"), "/repo")
    XCTAssertEqual(body.string("display_svg"), "clawd-working-building.svg")
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "cursor-agent", event: "beforeSubmitPrompt"), #"{"continue":true}"#)
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "cursor-agent", event: "postToolUse"), "{}")
  }

  func testCursorStopErrorBecomesStopFailure() throws {
    let payload = Data(#"{"hook_event_name":"stop","session_id":"s1","status":"error"}"#.utf8)
    let route = NativeHookRuntime(agentId: "cursor-agent", event: "stop", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("session_id"), "s1")
    XCTAssertEqual(body.string("state"), "error")
    XCTAssertEqual(body.string("event"), "StopFailure")
  }

  func testCodeBuddyRouteAndStdout() throws {
    let payload = Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/repo"}"#.utf8)
    let route = NativeHookRuntime(agentId: "codebuddy", event: "unknown", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "codebuddy")
    XCTAssertEqual(body.string("session_id"), "s1")
    XCTAssertEqual(body.string("state"), "working")
    XCTAssertEqual(body.string("event"), "PreToolUse")
    XCTAssertEqual(body.string("cwd"), "/repo")
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "codebuddy", event: "PreToolUse"), #"{"decision":"allow"}"#)
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "codebuddy", event: "Stop"), "{}")
  }

  func testKiroRouteUsesDefaultSessionAndCamelCaseEvent() throws {
    let payload = Data(#"{"hook_event_name":"preToolUse","cwd":"/repo"}"#.utf8)
    let route = NativeHookRuntime(agentId: "kiro-cli", event: "unknown", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "kiro-cli")
    XCTAssertEqual(body.string("session_id"), "default")
    XCTAssertEqual(body.string("state"), "working")
    XCTAssertEqual(body.string("event"), "preToolUse")
    XCTAssertEqual(body.string("cwd"), "/repo")
  }

  func testCodewhaleBuildsPayloadFromEnvironmentAndCache() throws {
    let fixture = try HookFixture()
    let cache = fixture.root.appendingPathComponent("codewhale-session-cache")
    let route = NativeHookRuntime(
      agentId: "codewhale",
      event: "tool_call_before",
      environment: [
        "CLAWD_CODEWHALE_SESSION_CACHE": cache.path,
        "DEEPSEEK_SESSION_ID": "sess-1",
        "DEEPSEEK_WORKSPACE": "/repo",
        "DEEPSEEK_MODEL": "deepseek-chat",
        "DEEPSEEK_TOOL_NAME": "Edit"
      ]
    ).route(stdin: Data())
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "codewhale")
    XCTAssertEqual(body.string("hook_source"), "codewhale-hook")
    XCTAssertEqual(body.string("session_id"), "codewhale:sess-1")
    XCTAssertEqual(body.string("state"), "working")
    XCTAssertEqual(body.string("event"), "PreToolUse")
    XCTAssertEqual(body.string("cwd"), "/repo")
    XCTAssertEqual(body.string("model"), "deepseek-chat")
    XCTAssertEqual(body.string("tool_name"), "Edit")
    XCTAssertEqual(body.string("session_title"), "CodeWhale")

    let cachedRoute = NativeHookRuntime(
      agentId: "codewhale",
      event: "mode_change",
      environment: [
        "CLAWD_CODEWHALE_SESSION_CACHE": cache.path,
        "DEEPSEEK_MODE": "agent",
        "DEEPSEEK_PREVIOUS_MODE": "plan"
      ]
    ).route(stdin: Data())
    guard case .state(.object(let cachedBody)) = cachedRoute else {
      return XCTFail("expected cached state route")
    }
    XCTAssertEqual(cachedBody.string("session_id"), "codewhale:sess-1")
    XCTAssertEqual(cachedBody.string("state"), "attention")
    XCTAssertEqual(cachedBody.string("event"), "Notification")
  }

  func testCodewhaleFailureAndSessionEndPolicy() throws {
    let fixture = try HookFixture()
    let cache = fixture.root.appendingPathComponent("codewhale-session-cache")
    let route = NativeHookRuntime(
      agentId: "codewhale",
      event: "tool_call_after",
      environment: [
        "CLAWD_CODEWHALE_SESSION_CACHE": cache.path,
        "DEEPSEEK_SESSION_ID": "sess-2",
        "DEEPSEEK_TOOL_SUCCESS": "false",
        "DEEPSEEK_ERROR": "failed"
      ]
    ).route(stdin: Data())
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("state"), "error")
    XCTAssertEqual(body.string("event"), "PostToolUseFailure")
    XCTAssertEqual(body.string("error_message"), "failed")
    XCTAssertEqual(NativeHookRuntime.statePostTimeout(agentId: "codewhale", event: "session_end"), 2)

    _ = NativeHookRuntime(
      agentId: "codewhale",
      event: "session_end",
      environment: ["CLAWD_CODEWHALE_SESSION_CACHE": cache.path]
    ).route(stdin: Data())
    XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
  }

  func testReasonixUsesPayloadEventAndToolName() throws {
    let payload = Data(#"{"event":"PreToolUse","session_id":"s1","cwd":"/repo","toolName":"Read"}"#.utf8)
    let route = NativeHookRuntime(agentId: "reasonix", event: "unknown", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "reasonix")
    XCTAssertEqual(body.string("session_id"), "reasonix:s1")
    XCTAssertEqual(body.string("state"), "working")
    XCTAssertEqual(body.string("event"), "PreToolUse")
    XCTAssertEqual(body.string("cwd"), "/repo")
    XCTAssertEqual(body.string("tool_name"), "Read")
  }

  func testReasonixStopUsesPostDelay() throws {
    let payload = Data(#"{"event":"Stop"}"#.utf8)
    XCTAssertEqual(NativeHookRuntime.statePostDelay(agentId: "reasonix", event: "PostToolUse", stdin: payload), 0.2)
    XCTAssertEqual(NativeHookRuntime.statePostDelay(agentId: "reasonix", event: "PostToolUse"), 0)
  }

  func testQoderPermissionRequestIsPassiveNotification() throws {
    let payload = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
    let route = NativeHookRuntime(agentId: "qoder", event: "PreToolUse", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("agent_id"), "qoder")
    XCTAssertEqual(body.string("session_id"), "qoder:s1")
    XCTAssertEqual(body.string("state"), "notification")
    XCTAssertEqual(body.string("event"), "Notification")
    XCTAssertEqual(body.string("cwd"), "/repo")
    XCTAssertEqual(body.string("tool_name"), "Bash")
    XCTAssertNotNil(body.string("tool_input_fingerprint"))
    XCTAssertEqual(NativeHookRuntime.stdout(agentId: "qoder", event: "PermissionRequest"), "{}")
  }

  func testQwenPermissionIncludesEmptySuggestionsForHookParity() throws {
    let payload = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/repo"}"#.utf8)
    let route = NativeHookRuntime(agentId: "qwen-code", event: "PermissionRequest", environment: [:]).route(stdin: payload)
    guard case .permission(.object(let body)) = route else {
      return XCTFail("expected permission route")
    }
    XCTAssertEqual(body.string("agent_id"), "qwen-code")
    XCTAssertEqual(body.string("session_id"), "qwen-code:s1")
    XCTAssertEqual(body.array("permission_suggestions")?.count, 0)
  }

  func testClaudeTranscriptAddsTitleAndAssistantOutput() throws {
    let fixture = try HookFixture()
    let transcript = fixture.root.appendingPathComponent("claude.jsonl")
    try """
    {"type":"custom-title","title":"  Native Hook Migration  "}
    {"type":"assistant","sessionId":"s1","message":{"content":[{"type":"text","text":"Done with the task"}]}}
    """.write(to: transcript, atomically: true, encoding: .utf8)
    let payload = Data(#"{"session_id":"s1","transcript_path":"\#(transcript.path)"}"#.utf8)
    let route = NativeHookRuntime(agentId: "claude-code", event: "Stop", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("session_title"), "Native Hook Migration")
    XCTAssertEqual(body.string("assistant_last_output"), "Done with the task")
  }

  func testClaudeTranscriptApiErrorPromotesStopToError() throws {
    let fixture = try HookFixture()
    let transcript = fixture.root.appendingPathComponent("claude-error.jsonl")
    try """
    {"type":"assistant","sessionId":"s1","isApiErrorMessage":true,"api_error_type":"rate_limit","message":{"content":"rate limited"}}
    """.write(to: transcript, atomically: true, encoding: .utf8)
    let payload = Data(#"{"session_id":"s1","transcript_path":"\#(transcript.path)"}"#.utf8)
    let route = NativeHookRuntime(agentId: "claude-code", event: "Stop", environment: [:]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("state"), "error")
    XCTAssertEqual(body.string("event"), "ApiError")
    XCTAssertEqual(body.string("api_error_type"), "rate_limit")
  }

  func testCodexReadsThreadNameAndAssistantOutput() throws {
    let fixture = try HookFixture()
    let codexHome = fixture.root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try #"{"id":"abc","thread_name":"Thread From Index"}"#
      .write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    let transcript = fixture.root.appendingPathComponent("codex.jsonl")
    try """
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Codex final answer"}]}}
    """.write(to: transcript, atomically: true, encoding: .utf8)
    let payload = Data(#"{"hook_event_name":"Stop","session_id":"abc","transcript_path":"\#(transcript.path)"}"#.utf8)
    let route = NativeHookRuntime(agentId: "codex", event: "Stop", environment: ["CODEX_HOME": codexHome.path]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("session_title"), "Thread From Index")
    XCTAssertEqual(body.string("assistant_last_output"), "Codex final answer")
  }

  func testCopilotReadsWorkspaceTitle() throws {
    let fixture = try HookFixture()
    let copilotHome = fixture.root.appendingPathComponent("copilot")
    let workspace = copilotHome
      .appendingPathComponent("session-state", isDirectory: true)
      .appendingPathComponent("s1", isDirectory: true)
      .appendingPathComponent("workspace.yaml")
    try FileManager.default.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "name: 'Renamed Workspace' # keep\n".write(to: workspace, atomically: true, encoding: .utf8)
    let payload = Data(#"{"sessionId":"s1"}"#.utf8)
    let route = NativeHookRuntime(agentId: "copilot-cli", event: "sessionStart", environment: ["COPILOT_HOME": copilotHome.path]).route(stdin: payload)
    guard case .state(.object(let body)) = route else {
      return XCTFail("expected state route")
    }
    XCTAssertEqual(body.string("session_title"), "Renamed Workspace")
  }
}

private extension [String: JSONValue] {
  func string(_ key: String) -> String? {
    if case .string(let value)? = self[key] { return value }
    return nil
  }

  func array(_ key: String) -> [JSONValue]? {
    if case .array(let value)? = self[key] { return value }
    return nil
  }

  func bool(_ key: String) -> Bool? {
    if case .bool(let value)? = self[key] { return value }
    return nil
  }
}

private final class HookFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-hook-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}
