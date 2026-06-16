import Foundation

public struct NativeHookRuntime {
  public enum Route: Equatable, Sendable {
    case state(JSONValue)
    case permission(JSONValue)
    case none
  }

  public var agentId: String
  public var event: String
  public var environment: [String: String]

  public init(agentId: String, event: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.agentId = agentId
    self.event = event
    self.environment = environment
  }

  public func route(stdin: Data) -> Route {
    let payload = (try? JSONDecoder().decode(JSONValue.self, from: stdin)) ?? .object([:])
    guard case .object(let object) = payload else { return .none }
    switch agentId {
    case "claude-code":
      return claudeRoute(payload: object)
    case "codex":
      return codexRoute(payload: object)
    case "qwen-code":
      return qwenRoute(payload: object)
    case "copilot-cli":
      return copilotRoute(payload: object)
    case "gemini-cli":
      return geminiRoute(payload: object)
    case "cursor-agent":
      return cursorRoute(payload: object)
    case "kiro-cli":
      return kiroRoute(payload: object)
    case "codewhale":
      return codewhaleRoute(payload: object)
    case "reasonix":
      return reasonixRoute(payload: object)
    case "qoder":
      return qoderRoute(payload: object)
    default:
      return .none
    }
  }

  public static func runtimePort(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Int? {
    let url: URL
    if let explicit = environment["CLAWD_NATIVE_RUNTIME_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !explicit.isEmpty {
      url = URL(fileURLWithPath: explicit)
    } else {
      url = homeDirectory
        .appendingPathComponent(".clawd", isDirectory: true)
        .appendingPathComponent("runtime.json")
    }
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
          case .number(let port)? = object["port"],
          port >= 1,
          port <= 65535
    else { return nil }
    return Int(port)
  }

  public static func encode(_ value: JSONValue) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
  }

  public static func stdout(agentId: String, event: String, stdin: Data? = nil) -> String? {
    if agentId == "qoder" { return "{}" }
    if agentId == "cursor-agent" {
      return event == "beforeSubmitPrompt" ? #"{"continue":true}"# : "{}"
    }
    guard agentId == "gemini-cli" else { return nil }
    var hookEvent = event
    if let stdin,
       case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: stdin),
       let payloadEvent = object.string("hook_event_name"),
       !payloadEvent.isEmpty {
      hookEvent = payloadEvent
    }
    if hookEvent == "BeforeTool" || hookEvent == "AfterTool" {
      return #"{"decision":"allow"}"#
    }
    return "{}"
  }

  public static func statePostDelay(agentId: String, event: String, stdin: Data? = nil) -> TimeInterval {
    guard agentId == "reasonix" else { return 0 }
    var hookEvent = event
    if let stdin,
       case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: stdin),
       let payloadEvent = object.string("event"),
       !payloadEvent.isEmpty {
      hookEvent = payloadEvent
    }
    return hookEvent == "Stop" ? 0.2 : 0
  }

  public static func statePostTimeout(agentId: String, event: String, stdin: Data? = nil) -> TimeInterval {
    guard agentId == "codewhale" else { return 0.2 }
    return event == "session_end" ? 2 : 0.2
  }

  private func claudeRoute(payload: [String: JSONValue]) -> Route {
    guard let state = Self.claudeState[event] else { return .none }
    let toolName = payload.string("tool_name")
    let resolvedEvent = event == "PreToolUse" && toolName == "Task" ? "SubagentStart" : event
    let resolvedState: String
    if event == "PreToolUse", toolName == "Task" {
      resolvedState = "juggling"
    } else if event == "SessionEnd", payload.string("source") == "clear" || payload.string("reason") == "clear" {
      resolvedState = "sweeping"
    } else if event == "PostCompact", payload.string("trigger") == "manual" {
      resolvedState = "idle"
    } else {
      resolvedState = state
    }
    var body = baseState(
      state: resolvedState,
      sessionId: payload.string("session_id") ?? "default",
      event: resolvedEvent,
      agentId: "claude-code",
      payload: payload
    )
    addToolMetadata(payload: payload, body: &body)
    let transcript = transcriptRecords(path: payload.string("transcript_path"), maxBytes: 262_144)
    if let title = normalizedTitle(payload.string("session_title")) {
      body["session_title"] = .string(title)
    } else if let title = claudeSessionTitle(records: transcript) {
      body["session_title"] = .string(title)
    } else if event == "UserPromptSubmit", let title = normalizedPromptTitle(payload.string("prompt")) {
      body["session_title"] = .string(title)
    }
    if event == "Stop" {
      if let apiError = claudeApiError(records: transcript, sessionId: payload.string("session_id")) {
        body["state"] = .string("error")
        body["event"] = .string("ApiError")
        body["failure_kind"] = .string("api_error")
        body["api_error_type"] = .string(apiError)
        body["error_present"] = .bool(true)
      } else if let assistant = lastClaudeAssistantText(records: transcript, sessionId: payload.string("session_id")) {
        body["assistant_last_output"] = .string(assistant.text)
        if assistant.truncated {
          body["assistant_last_output_truncated"] = .bool(true)
        }
      }
      if let count = payload.arrayCount("background_tasks"), count > 0 {
        body["background_tasks_count"] = .number(Double(count))
      }
      if let count = payload.arrayCount("session_crons"), count > 0 {
        body["session_crons_count"] = .number(Double(count))
      }
      if payload.bool("stop_hook_active") == true {
        body["stop_hook_active"] = .bool(true)
      }
    }
    return .state(.object(body))
  }

  private func codexRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("hook_event_name") ?? event
    let sessionMeta = firstCodexSessionMeta(path: payload.string("transcript_path"))
    if hookEvent == "PermissionRequest" {
      var body = basePermission(
        agentId: "codex",
        sessionId: codexSessionId(payload: payload),
        toolName: payload.string("tool_name") ?? "Unknown",
        payload: payload
      )
      body["hook_source"] = .string("codex-official")
      if let description = payload.object("tool_input")?.string("description") {
        body["tool_input_description"] = .string(String(description.prefix(500)))
      }
      addCodexFields(payload: payload, sessionMeta: sessionMeta, body: &body)
      return .permission(.object(body))
    }
    guard let state = Self.codexState[hookEvent] else { return .none }
    if hookEvent == "Stop", payload.bool("stop_hook_active") == true { return .none }
    var body = baseState(
      state: state,
      sessionId: codexSessionId(payload: payload),
      event: hookEvent,
      agentId: "codex",
      payload: payload
    )
    body["hook_source"] = .string("codex-official")
    addToolMetadata(payload: payload, body: &body)
    addCodexFields(payload: payload, sessionMeta: sessionMeta, body: &body)
    if let title = codexThreadName(sessionId: body.string("session_id")) {
      body["session_title"] = .string(title)
    }
    if let active = payload.bool("stop_hook_active") {
      body["stop_hook_active"] = .bool(active)
    }
    if hookEvent == "Stop",
       let assistant = lastCodexAssistantText(records: transcriptRecords(path: payload.string("transcript_path"), maxBytes: 262_144)) {
      body["assistant_last_output"] = .string(assistant.text)
      if assistant.truncated {
        body["assistant_last_output_truncated"] = .bool(true)
      }
    }
    return .state(.object(body))
  }

  private func qwenRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("hook_event_name") ?? event
    if hookEvent == "PermissionRequest" {
      var body = basePermission(
        agentId: "qwen-code",
        sessionId: normalizeSessionId(payload.string("session_id"), prefix: "qwen-code"),
        toolName: payload.string("tool_name") ?? "Unknown",
        payload: payload
      )
      addToolMetadata(payload: payload, body: &body)
      body["permission_suggestions"] = .array([])
      return .permission(.object(body))
    }
    guard let state = Self.qwenState[hookEvent] else { return .none }
    var body = baseState(
      state: state,
      sessionId: normalizeSessionId(payload.string("session_id"), prefix: "qwen-code"),
      event: hookEvent,
      agentId: "qwen-code",
      payload: payload
    )
    if hookEvent == "PreToolUse" || hookEvent == "PostToolUse" {
      addToolMetadata(payload: payload, body: &body)
    }
    return .state(.object(body))
  }

  private func copilotRoute(payload: [String: JSONValue]) -> Route {
    if event == "permissionRequest" {
      var body = basePermission(
        agentId: "copilot-cli",
        sessionId: normalizeSessionId(payload.string("sessionId") ?? payload.string("session_id"), prefix: "copilot-cli"),
        toolName: payload.string("toolName") ?? payload.string("tool_name") ?? "Unknown",
        payload: payload
      )
      if let suggestions = payload["permissionSuggestions"] ?? payload["permission_suggestions"] {
        body["permission_suggestions"] = suggestions
      }
      addCopilotToolMetadata(payload: payload, body: &body)
      return .permission(.object(body))
    }
    guard let state = Self.copilotState[event] else { return .none }
    var body = baseState(
      state: state,
      sessionId: normalizeSessionId(payload.string("sessionId") ?? payload.string("session_id"), prefix: "copilot-cli"),
      event: event,
      agentId: "copilot-cli",
      payload: payload
    )
    addCopilotToolMetadata(payload: payload, body: &body)
    if let title = normalizedTitle(payload.string("sessionTitle") ?? payload.string("session_title")) {
      body["session_title"] = .string(title)
    } else if let title = copilotWorkspaceTitle(sessionId: payload.string("sessionId") ?? payload.string("session_id")) {
      body["session_title"] = .string(title)
    }
    return .state(.object(body))
  }

  private func geminiRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("hook_event_name") ?? event
    guard var mapped = Self.geminiState[hookEvent] else { return .none }
    if hookEvent == "AfterTool", geminiToolResponseHasError(payload) {
      mapped = (state: "error", event: "PostToolUseFailure", preserveState: false)
    } else if hookEvent == "SessionEnd", payload.string("reason") == "clear" || payload.string("source") == "clear" {
      mapped = (state: "sweeping", event: "SessionEnd", preserveState: false)
    }
    var body = baseState(
      state: mapped.state,
      sessionId: normalizeSessionId(payload.string("session_id"), prefix: "gemini"),
      event: mapped.event,
      agentId: "gemini-cli",
      payload: payload
    )
    if mapped.preserveState {
      body["preserve_state"] = .bool(true)
    }
    return .state(.object(body))
  }

  private func cursorRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("hook_event_name") ?? event
    guard var mapped = Self.cursorState[hookEvent] else { return .none }
    if hookEvent == "stop", payload.string("status") == "error" {
      mapped = (state: "error", event: "StopFailure")
    }
    let sessionId = firstNonEmpty(payload.string("conversation_id"), payload.string("session_id")) ?? "default"
    var sharedPayload = payload
    if sharedPayload.string("cwd") == nil, let workspace = firstString(in: payload["workspace_roots"]) {
      sharedPayload["cwd"] = .string(workspace)
    }
    var body = baseState(
      state: mapped.state,
      sessionId: sessionId,
      event: mapped.event,
      agentId: "cursor-agent",
      payload: sharedPayload
    )
    if let hint = cursorDisplaySVG(hookEvent: hookEvent, payload: payload) {
      body["display_svg"] = .string(hint)
    }
    return .state(.object(body))
  }

  private func kiroRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("hook_event_name") ?? event
    guard let mapped = Self.kiroState[hookEvent] else { return .none }
    return .state(.object(baseState(
      state: mapped.state,
      sessionId: "default",
      event: mapped.event,
      agentId: "kiro-cli",
      payload: payload
    )))
  }

  private func codewhaleRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("event") ?? event
    guard var mapped = Self.codewhaleState[hookEvent] else { return .none }
    if hookEvent == "tool_call_after", codewhaleBool("DEEPSEEK_TOOL_SUCCESS") == false {
      mapped = (state: "error", event: "PostToolUseFailure")
    } else if hookEvent == "mode_change" {
      let mode = codewhaleEnv("DEEPSEEK_MODE")?.lowercased() ?? ""
      let previous = codewhaleEnv("DEEPSEEK_PREVIOUS_MODE")?.lowercased() ?? ""
      if mode != "compact", previous != "compact" {
        mapped = (state: "attention", event: "Notification")
      }
    }

    let sessionId = codewhaleSessionId()
    var sharedPayload: [String: JSONValue] = [:]
    if let cwd = codewhaleEnv("DEEPSEEK_WORKSPACE") {
      sharedPayload["cwd"] = .string(cwd)
    }
    if let model = codewhaleEnv("DEEPSEEK_MODEL") {
      sharedPayload["model"] = .string(model)
    }
    var body = baseState(
      state: mapped.state,
      sessionId: normalizeSessionId(sessionId, prefix: "codewhale"),
      event: mapped.event,
      agentId: "codewhale",
      payload: sharedPayload
    )
    body["hook_source"] = .string("codewhale-hook")
    body["session_title"] = .string("CodeWhale")
    if let toolName = codewhaleEnv("DEEPSEEK_TOOL_NAME") {
      body["tool_name"] = .string(toolName)
    }
    if let error = codewhaleEnv("DEEPSEEK_ERROR") {
      body["error_message"] = .string(error)
    }
    if hookEvent == "session_end" {
      clearCodewhaleCachedSessionId()
    }
    return .state(.object(body))
  }

  private func reasonixRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("event") ?? event
    guard let state = Self.reasonixState[hookEvent] else { return .none }
    var body = baseState(
      state: state,
      sessionId: normalizeSessionId(payload.string("session_id"), prefix: "reasonix"),
      event: hookEvent,
      agentId: "reasonix",
      payload: payload
    )
    if hookEvent == "PreToolUse" || hookEvent == "PostToolUse",
       let toolName = payload.string("toolName")?.trimmingCharacters(in: .whitespacesAndNewlines),
       !toolName.isEmpty {
      body["tool_name"] = .string(toolName)
    }
    return .state(.object(body))
  }

  private func qoderRoute(payload: [String: JSONValue]) -> Route {
    let hookEvent = payload.string("hook_event_name") ?? event
    guard let mapped = Self.qoderState[hookEvent] else { return .none }
    var body = baseState(
      state: mapped.state,
      sessionId: normalizeSessionId(payload.string("session_id"), prefix: "qoder"),
      event: mapped.event,
      agentId: "qoder",
      payload: payload
    )
    if Self.qoderToolMetadataEvents.contains(hookEvent) {
      addToolMetadata(payload: payload, body: &body)
    }
    return .state(.object(body))
  }

  private func baseState(
    state: String,
    sessionId: String,
    event: String,
    agentId: String,
    payload: [String: JSONValue]
  ) -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "state": .string(state),
      "session_id": .string(sessionId),
      "event": .string(event),
      "agent_id": .string(agentId)
    ]
    addSharedFields(payload: payload, body: &body)
    return body
  }

  private func basePermission(
    agentId: String,
    sessionId: String,
    toolName: String,
    payload: [String: JSONValue]
  ) -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "agent_id": .string(agentId),
      "session_id": .string(sessionId),
      "tool_name": .string(toolName),
      "tool_input": capped(payload["tool_input"] ?? payload["toolInput"] ?? .object([:]))
    ]
    addSharedFields(payload: payload, body: &body)
    addToolMetadata(payload: payload, body: &body)
    return body
  }

  private func addSharedFields(payload: [String: JSONValue], body: inout [String: JSONValue]) {
    for (sourceKey, targetKey) in [
      ("cwd", "cwd"),
      ("model", "model"),
      ("provider", "provider"),
      ("permission_mode", "permission_mode"),
      ("transcript_path", "transcript_path")
    ] {
      if let value = payload.string(sourceKey), !value.isEmpty {
        body[targetKey] = .string(value)
      }
    }
    if environment["CLAWD_REMOTE"] == "1" {
      body["host"] = .string(environment["CLAWD_HOST_PREFIX"] ?? "remote")
    } else {
      let process = NativeProcessResolver.resolve(agentNames: processNames(for: agentId))
      if let sourcePid = process.sourcePid {
        body["source_pid"] = .number(Double(sourcePid))
      }
      if let agentPid = process.agentPid {
        body["agent_pid"] = .number(Double(agentPid))
      }
      if !process.pidChain.isEmpty {
        body["pid_chain"] = .array(process.pidChain.map { .number(Double($0)) })
      }
      if let editor = process.editor {
        body["editor"] = .string(editor)
      }
      body["platform"] = .string("darwin")
    }
  }

  private func processNames(for agentId: String) -> Set<String> {
    switch agentId {
    case "claude-code":
      return ["claude"]
    case "codex":
      return ["codex"]
    case "qwen-code":
      return ["qwen"]
    case "copilot-cli":
      return ["copilot"]
    case "gemini-cli":
      return ["gemini"]
    case "cursor-agent":
      return ["cursor", "Cursor"]
    case "kiro-cli":
      return ["kiro-cli"]
    case "codewhale":
      return ["codewhale"]
    case "reasonix":
      return ["reasonix"]
    case "qoder":
      return ["qoder", "qodercli", "qoder-cli"]
    default:
      return []
    }
  }

  private func geminiToolResponseHasError(_ payload: [String: JSONValue]) -> Bool {
    guard let response = payload.object("tool_response"), let error = response["error"] else { return false }
    switch error {
    case .null:
      return false
    case .bool(let value):
      return value
    case .string(let value):
      return !value.isEmpty
    default:
      return true
    }
  }

  private func addToolMetadata(payload: [String: JSONValue], body: inout [String: JSONValue]) {
    if let tool = payload.string("tool_name"), !tool.isEmpty {
      body["tool_name"] = .string(tool)
    }
    if let toolUseId = payload.string("tool_use_id") ?? payload.string("toolUseId") ?? payload.string("toolUseID"), !toolUseId.isEmpty {
      body["tool_use_id"] = .string(toolUseId)
    }
    let toolInput = payload["tool_input"] ?? payload["toolInput"]
    if let fingerprint = Self.fingerprint(toolInput) {
      body["tool_input_fingerprint"] = .string(fingerprint)
    }
  }

  private func addCopilotToolMetadata(payload: [String: JSONValue], body: inout [String: JSONValue]) {
    if let tool = payload.string("toolName") ?? payload.string("tool_name"), !tool.isEmpty {
      body["tool_name"] = .string(tool)
    }
    if let toolInput = payload["toolInput"] ?? payload["tool_input"] {
      body["tool_input"] = capped(toolInput)
      if let fingerprint = Self.fingerprint(toolInput) {
        body["tool_input_fingerprint"] = .string(fingerprint)
      }
    }
    if let toolUseId = payload.string("toolUseId") ?? payload.string("tool_use_id"), !toolUseId.isEmpty {
      body["tool_use_id"] = .string(toolUseId)
    }
  }

  private func addCodexFields(payload: [String: JSONValue], sessionMeta: [String: JSONValue]?, body: inout [String: JSONValue]) {
    if let role = resolveCodexSessionRole(payload: payload, sessionMeta: sessionMeta) {
      body["codex_session_role"] = .string(role)
    }
    if let originator = firstNonEmpty(sessionMeta?.string("originator"), payload.string("originator")) {
      body["codex_originator"] = .string(originator)
    }
    if let source = firstNonEmpty(sessionMeta?.string("source"), payload.string("source")) {
      body["codex_source"] = .string(source)
    }
    if let upstreamAgentId = firstNonEmpty(payload.string("agent_id"), sessionMeta?.string("agent_id")) {
      body["codex_subagent_id"] = .string(upstreamAgentId)
    }
    if let upstreamAgentType = firstNonEmpty(payload.string("agent_type"), sessionMeta?.string("agent_type")) {
      body["codex_agent_type"] = .string(upstreamAgentType)
    }
  }

  private func codexSessionId(payload: [String: JSONValue]) -> String {
    normalizeSessionId(extractCodexSessionId(fromTranscriptPath: payload.string("transcript_path")) ?? payload.string("session_id"), prefix: "codex")
  }

  private func extractCodexSessionId(fromTranscriptPath path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    let fileName = URL(fileURLWithPath: path).lastPathComponent
    let pattern = #"^rollout-.+-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: fileName)
    else { return nil }
    return String(fileName[range])
  }

  private func firstCodexSessionMeta(path: String?) -> [String: JSONValue]? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 262_144)) ?? Data()
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
    return text.components(separatedBy: CharacterSet.newlines).compactMap(parseCodexSessionMetaLine).first
  }

  private func parseCodexSessionMetaLine(_ line: String) -> [String: JSONValue]? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
          case .object(let record) = try? JSONDecoder().decode(JSONValue.self, from: data),
          record.string("type") == "session_meta",
          let payload = record.object("payload")
    else { return nil }
    return payload
  }

  private func resolveCodexSessionRole(payload: [String: JSONValue], sessionMeta: [String: JSONValue]?) -> String? {
    classifyCodexHookPayload(payload) ?? classifyCodexSessionMeta(sessionMeta)
  }

  private func classifyCodexHookPayload(_ payload: [String: JSONValue]) -> String? {
    normalizedCodexRole(payload.string("codex_session_role"))
      ?? classifyCodexSource(payload["source"])
      ?? normalizedCodexRole(payload.string("agent_role"))
      ?? normalizedCodexRole(payload.string("agent_type"))
      ?? codexParentRole(payload)
  }

  private func classifyCodexSessionMeta(_ sessionMeta: [String: JSONValue]?) -> String? {
    guard let sessionMeta else { return nil }
    return classifyCodexSource(sessionMeta["source"])
      ?? normalizedCodexRole(sessionMeta.string("codex_session_role"))
      ?? normalizedCodexRole(sessionMeta.string("agent_role"))
      ?? normalizedCodexRole(sessionMeta.string("agent_type"))
      ?? codexParentRole(sessionMeta)
  }

  private func classifyCodexSource(_ source: JSONValue?) -> String? {
    switch source {
    case .object(let object):
      if let subagent = object["subagent"] {
        return subagent == .bool(false) || subagent == .null ? "root" : "subagent"
      }
      return normalizedCodexRole(object.string("role") ?? object.string("type") ?? object.string("kind"))
    case .string(let value):
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if normalized == "subagent" || normalized == "agent-subagent" { return "subagent" }
      if normalized == "cli" || normalized == "codex-cli" || normalized == "codex-tui" { return "root" }
      return nil
    default:
      return nil
    }
  }

  private func normalizedCodexRole(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !normalized.isEmpty else { return nil }
    if normalized == "root" || normalized == "main" || normalized == "primary" { return "root" }
    if ["subagent", "child", "delegate", "delegated", "explorer", "worker"].contains(normalized) {
      return "subagent"
    }
    return nil
  }

  private func firstString(in value: JSONValue?) -> String? {
    guard case .array(let array)? = value else { return nil }
    for item in array {
      if case .string(let candidate) = item {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private func cursorDisplaySVG(hookEvent: String, payload: [String: JSONValue]) -> String? {
    guard hookEvent == "preToolUse" || hookEvent == "postToolUse",
          let name = payload.string("tool_name"),
          !name.isEmpty
    else { return nil }
    if name == "Shell" || name.hasPrefix("MCP:") { return "clawd-working-building.svg" }
    if name == "Task" { return "clawd-headphones-groove.svg" }
    if name == "Write" || name == "Delete" { return "clawd-working-typing.svg" }
    if name == "Read" || name == "Grep" { return "clawd-idle-reading.svg" }
    return nil
  }

  private func codewhaleSessionId() -> String {
    if let explicit = codewhaleEnv("DEEPSEEK_SESSION_ID") {
      writeCodewhaleCachedSessionId(explicit)
      return explicit
    }
    if let cached = readCodewhaleCachedSessionId() {
      writeCodewhaleCachedSessionId(cached)
      return cached
    }
    let generated = "sess_\(Int(Date().timeIntervalSince1970 * 1000))"
    writeCodewhaleCachedSessionId(generated)
    return generated
  }

  private func codewhaleEnv(_ key: String) -> String? {
    let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private func codewhaleBool(_ key: String) -> Bool? {
    switch codewhaleEnv(key) {
    case "true":
      return true
    case "false":
      return false
    default:
      return nil
    }
  }

  private func codewhaleSessionCacheURL() -> URL {
    if let explicit = codewhaleEnv("CLAWD_CODEWHALE_SESSION_CACHE") {
      return URL(fileURLWithPath: explicit)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codewhale-hook-session")
  }

  private func readCodewhaleCachedSessionId() -> String? {
    let value = (try? String(contentsOf: codewhaleSessionCacheURL(), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private func writeCodewhaleCachedSessionId(_ value: String) {
    try? value.write(to: codewhaleSessionCacheURL(), atomically: true, encoding: .utf8)
  }

  private func clearCodewhaleCachedSessionId() {
    try? FileManager.default.removeItem(at: codewhaleSessionCacheURL())
  }

  private func codexParentRole(_ object: [String: JSONValue]) -> String? {
    if firstNonEmpty(object.string("parent_session_id"), object.string("parent_thread_id")) != nil {
      return "subagent"
    }
    return nil
  }

  private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  private func normalizeSessionId(_ value: String?, prefix: String) -> String {
    let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let session = raw?.isEmpty == false ? raw! : "default"
    return session.hasPrefix("\(prefix):") ? session : "\(prefix):\(session)"
  }

  private func capped(_ value: JSONValue) -> JSONValue {
    Self.cap(value, depth: 0)
  }

  private func normalizedTitle(_ value: String?) -> String? {
    guard let value else { return nil }
    let collapsed = value
      .components(separatedBy: .controlCharacters)
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    if collapsed.count <= 80 { return collapsed }
    return "\(collapsed.prefix(79))..."
  }

  private func normalizedPromptTitle(_ value: String?) -> String? {
    guard let line = value?.split(whereSeparator: \.isNewline).first else { return nil }
    return normalizedTitle(String(line)).map { String($0.prefix(40)) }
  }

  private func transcriptRecords(path: String?, maxBytes: Int) -> [[String: JSONValue]] {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return [] }
    let url = URL(fileURLWithPath: path)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    let fileSize = (try? handle.seekToEnd()) ?? 0
    let readSize = min(UInt64(maxBytes), fileSize)
    guard readSize > 0 else { return [] }
    try? handle.seek(toOffset: fileSize - readSize)
    let data = (try? handle.read(upToCount: Int(readSize))) ?? Data()
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: CharacterSet.newlines)
    if fileSize > readSize, !lines.isEmpty {
      lines.removeFirst()
    }
    return lines.compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
      guard case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
      return object
    }
  }

  private func claudeSessionTitle(records: [[String: JSONValue]]) -> String? {
    var latest: String?
    for record in records {
      let type = record.string("type") ?? ""
      guard type == "custom-title" || type == "agent-name" else { continue }
      latest = normalizedTitle(
        record.string("customTitle")
          ?? record.string("title")
          ?? record.string("custom_title")
          ?? record.string("agentName")
          ?? record.string("agent_name")
      ) ?? latest
    }
    return latest
  }

  private func claudeApiError(records: [[String: JSONValue]], sessionId: String?) -> String? {
    let allowed = Set([
      "authentication_failed",
      "oauth_org_not_allowed",
      "billing_error",
      "rate_limit",
      "invalid_request",
      "model_not_found",
      "server_error",
      "unknown",
      "max_output_tokens"
    ])
    var lastErrorIndex = -1
    var errorType = "unknown"
    for index in stride(from: records.count - 1, through: 0, by: -1) {
      let record = records[index]
      guard record.bool("isApiErrorMessage") == true else { continue }
      guard assistantEntryMatchesSession(record, sessionId: sessionId) else { continue }
      lastErrorIndex = index
      let candidate = record.string("api_error_type") ?? record.string("apiErrorType") ?? "unknown"
      errorType = allowed.contains(candidate) ? candidate : "unknown"
      break
    }
    guard lastErrorIndex >= 0 else { return nil }
    if lastErrorIndex + 1 < records.count {
      for record in records[(lastErrorIndex + 1)..<records.count] {
        if claudeAssistantEntryIsTurnBoundary(record, sessionId: sessionId) { return nil }
        if record.string("type") == "assistant", record.bool("isApiErrorMessage") != true {
          return nil
        }
      }
    }
    return errorType
  }

  private func lastClaudeAssistantText(records: [[String: JSONValue]], sessionId: String?) -> (text: String, truncated: Bool)? {
    guard !records.isEmpty else { return nil }
    for record in records.reversed() {
      if claudeAssistantEntryIsTurnBoundary(record, sessionId: sessionId) { break }
      guard record.string("type") == "assistant",
            record.bool("isApiErrorMessage") != true,
            assistantEntryMatchesSession(record, sessionId: sessionId),
            !assistantEntryLooksSubagent(record)
      else { continue }
      let text = normalizeAssistantText(textParts(from: record["message"]?.objectValue?["content"] ?? record["content"]).joined(separator: "\n\n"))
      if !text.isEmpty {
        return clampAssistantText(text)
      }
    }
    return nil
  }

  private func lastCodexAssistantText(records: [[String: JSONValue]]) -> (text: String, truncated: Bool)? {
    guard !records.isEmpty else { return nil }
    for record in records.reversed() {
      if codexIsTurnBoundary(record) { break }
      let text = codexAssistantText(record)
      if !text.isEmpty {
        return clampAssistantText(text)
      }
    }
    return nil
  }

  private func codexAssistantText(_ record: [String: JSONValue]) -> String {
    guard let payload = record["payload"]?.objectValue else { return "" }
    if record.string("type") == "event_msg", payload.string("type") == "agent_message" {
      return normalizeAssistantText(collectTextCandidates(payload).joined(separator: "\n\n"))
    }
    guard record.string("type") == "response_item" else { return "" }
    let type = payload.string("type") ?? ""
    if Self.skippedCodexResponseItemTypes.contains(type) { return "" }
    let role = payload.string("role")?.lowercased() ?? ""
    if !role.isEmpty, role != "assistant" { return "" }
    guard Self.textCodexResponseItemTypes.contains(type) || role == "assistant" else { return "" }
    return normalizeAssistantText(collectTextCandidates(payload).joined(separator: "\n\n"))
  }

  private func codexIsTurnBoundary(_ record: [String: JSONValue]) -> Bool {
    guard let payload = record["payload"]?.objectValue else { return false }
    if record.string("type") == "event_msg" {
      return payload.string("type") == "task_started" || payload.string("type") == "user_message"
    }
    if record.string("type") == "response_item", payload.string("type") == "message" {
      return payload.string("role")?.lowercased() == "user"
    }
    return false
  }

  private func codexThreadName(sessionId: String?) -> String? {
    guard var id = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
    if id.hasPrefix("codex:") {
      id = String(id.dropFirst("codex:".count))
    }
    let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = (codexHome?.isEmpty == false)
      ? URL(fileURLWithPath: codexHome!)
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    let indexURL = base.appendingPathComponent("session_index.jsonl")
    guard let text = readTailText(indexURL, maxBytes: 512 * 1024) else { return nil }
    var latest: String?
    for line in text.components(separatedBy: CharacterSet.newlines) {
      guard let data = line.data(using: .utf8),
            case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data),
            object.string("id") == id,
            let name = normalizedTitle(object.string("thread_name"))
      else { continue }
      latest = name
    }
    return latest
  }

  private func copilotWorkspaceTitle(sessionId: String?) -> String? {
    guard let raw = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    guard raw.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
          raw.range(of: #"^\.+$"#, options: .regularExpression) == nil
    else { return nil }
    let home = environment["COPILOT_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = (home?.isEmpty == false)
      ? URL(fileURLWithPath: home!)
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot", isDirectory: true)
    let sessionState = base.appendingPathComponent("session-state", isDirectory: true)
    let workspace = sessionState.appendingPathComponent(raw, isDirectory: true).appendingPathComponent("workspace.yaml")
    guard workspace.standardizedFileURL.path.hasPrefix(sessionState.standardizedFileURL.path + "/"),
          let text = readHeadText(workspace, maxBytes: 16 * 1024)
    else { return nil }
    return normalizedTitle(parseWorkspaceYamlName(text))
  }

  private func parseWorkspaceYamlName(_ text: String) -> String? {
    for line in text.components(separatedBy: CharacterSet.newlines) {
      guard let range = line.range(of: #"^name:\s*(.*?)\s*$"#, options: .regularExpression) else { continue }
      var value = String(line[range]).replacingOccurrences(of: #"^name:\s*"#, with: "", options: .regularExpression)
      if let first = value.first, first == "\"" || first == "'" {
        if let close = value.dropFirst().firstIndex(of: first) {
          value = String(value[value.index(after: value.startIndex)..<close])
        }
      } else if let comment = value.range(of: " #") {
        value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  private func readTailText(_ url: URL, maxBytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let fileSize = (try? handle.seekToEnd()) ?? 0
    let readSize = min(UInt64(maxBytes), fileSize)
    guard readSize > 0 else { return nil }
    try? handle.seek(toOffset: fileSize - readSize)
    let data = (try? handle.read(upToCount: Int(readSize))) ?? Data()
    return String(data: data, encoding: .utf8)
  }

  private func readHeadText(_ url: URL, maxBytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
    return String(data: data, encoding: .utf8)
  }

  private func assistantEntryMatchesSession(_ entry: [String: JSONValue], sessionId: String?) -> Bool {
    guard let sessionId, !sessionId.isEmpty else { return true }
    return entry.string("sessionId") == nil || entry.string("sessionId") == sessionId
  }

  private func assistantEntryLooksSubagent(_ entry: [String: JSONValue]) -> Bool {
    entry.bool("isSidechain") == true
      || entry.bool("isSubagent") == true
      || entry.bool("is_subagent") == true
      || entry.bool("subagent") == true
  }

  private func claudeAssistantEntryIsTurnBoundary(_ entry: [String: JSONValue], sessionId: String?) -> Bool {
    entry.string("type") == "user" && assistantEntryMatchesSession(entry, sessionId: sessionId)
  }

  private func collectTextCandidates(_ object: [String: JSONValue]) -> [String] {
    var candidates: [String] = []
    for key in ["content", "text", "output_text", "message", "delta"] {
      guard let value = object[key] else { continue }
      candidates.append(contentsOf: textParts(from: value))
      if let nested = value.objectValue {
        candidates.append(contentsOf: collectTextCandidates(nested))
      }
    }
    return candidates
  }

  private func textParts(from value: JSONValue?) -> [String] {
    guard let value else { return [] }
    switch value {
    case .string(let string):
      return [string]
    case .array(let array):
      return array.flatMap { item -> [String] in
        if case .string(let string) = item { return [string] }
        guard let block = item.objectValue else { return [] }
        let type = block.string("type") ?? ""
        if Self.skippedCodexResponseItemTypes.contains(type) || type == "tool_use" || type == "server_tool_use" {
          return []
        }
        if (type == "text" || type == "output_text" || type.isEmpty), let text = block.string("text") {
          return [text]
        }
        return []
      }
    case .object(let object):
      return collectTextCandidates(object)
    default:
      return []
    }
  }

  private func normalizeAssistantText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: CharacterSet(charactersIn: "\u{0000}\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}\u{0006}\u{0007}\u{0008}\u{000b}\u{000c}\u{000e}\u{000f}\u{0010}\u{0011}\u{0012}\u{0013}\u{0014}\u{0015}\u{0016}\u{0017}\u{0018}\u{0019}\u{001a}\u{001b}\u{001c}\u{001d}\u{001e}\u{001f}\u{007f}"))
      .joined(separator: " ")
      .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func clampAssistantText(_ value: String, maxLength: Int = 2_200) -> (text: String, truncated: Bool)? {
    let normalized = normalizeAssistantText(value)
    guard !normalized.isEmpty else { return nil }
    if normalized.count <= maxLength {
      return (normalized, false)
    }
    let marker = "\n...[truncated]...\n"
    let keep = maxLength - marker.count
    guard keep > 20 else {
      return (String(normalized.suffix(maxLength)), true)
    }
    let head = Int(ceil(Double(keep) / 2.0))
    let tail = keep / 2
    return ("\(normalized.prefix(head))\(marker)\(normalized.suffix(tail))", true)
  }

  private static func cap(_ value: JSONValue, depth: Int) -> JSONValue {
    if depth > 6 { return .null }
    switch value {
    case .string(let string):
      return string.count > 32_768 ? .string("\(string.prefix(32_768))...[truncated]") : value
    case .array(let array):
      return .array(array.prefix(64).map { cap($0, depth: depth + 1) })
    case .object(let object):
      var out: [String: JSONValue] = [:]
      for key in object.keys.sorted().prefix(64) {
        out[key] = object[key].map { cap($0, depth: depth + 1) } ?? .null
      }
      return .object(out)
    default:
      return value
    }
  }

  private static func fingerprint(_ value: JSONValue?) -> String? {
    guard let value,
          case .object = value,
          let data = try? JSONEncoder().encode(cap(value, depth: 0))
    else { return nil }
    return fnv1aHex(data)
  }

  private static func fnv1aHex(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
  }

  private static let claudeState = [
    "SessionStart": "idle",
    "SessionEnd": "sleeping",
    "UserPromptSubmit": "thinking",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "PostToolUseFailure": "error",
    "Stop": "attention",
    "StopFailure": "error",
    "SubagentStart": "juggling",
    "SubagentStop": "working",
    "Notification": "notification",
    "PreCompact": "sweeping",
    "PostCompact": "thinking",
    "Elicitation": "notification"
  ]

  private static let codexState = [
    "SessionStart": "idle",
    "UserPromptSubmit": "thinking",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Stop": "idle"
  ]

  private static let qwenState = [
    "SessionStart": "idle",
    "SessionEnd": "sleeping",
    "UserPromptSubmit": "thinking",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Stop": "attention"
  ]

  private static let copilotState = [
    "sessionStart": "idle",
    "sessionEnd": "sleeping",
    "userPromptSubmitted": "thinking",
    "preToolUse": "working",
    "postToolUse": "working",
    "errorOccurred": "error",
    "agentStop": "attention",
    "subagentStart": "juggling",
    "subagentStop": "working",
    "preCompact": "sweeping"
  ]

  private static let geminiState: [String: (state: String, event: String, preserveState: Bool)] = [
    "SessionStart": ("idle", "SessionStart", false),
    "SessionEnd": ("sleeping", "SessionEnd", false),
    "BeforeAgent": ("thinking", "UserPromptSubmit", false),
    "BeforeTool": ("working", "PreToolUse", false),
    "AfterTool": ("working", "PostToolUse", false),
    "AfterAgent": ("idle", "AfterAgent", false),
    "Notification": ("notification", "Notification", false),
    "PreCompress": ("idle", "PreCompress", true)
  ]

  private static let cursorState: [String: (state: String, event: String)] = [
    "sessionStart": ("idle", "SessionStart"),
    "sessionEnd": ("sleeping", "SessionEnd"),
    "beforeSubmitPrompt": ("thinking", "UserPromptSubmit"),
    "preToolUse": ("working", "PreToolUse"),
    "postToolUse": ("working", "PostToolUse"),
    "postToolUseFailure": ("working", "PostToolUseFailure"),
    "stop": ("attention", "Stop"),
    "subagentStart": ("juggling", "SubagentStart"),
    "subagentStop": ("working", "SubagentStop"),
    "preCompact": ("sweeping", "PreCompact"),
    "afterAgentThought": ("thinking", "AfterAgentThought")
  ]

  private static let kiroState: [String: (state: String, event: String)] = [
    "agentSpawn": ("idle", "agentSpawn"),
    "userPromptSubmit": ("thinking", "userPromptSubmit"),
    "preToolUse": ("working", "preToolUse"),
    "postToolUse": ("working", "postToolUse"),
    "stop": ("attention", "stop")
  ]

  private static let codewhaleState: [String: (state: String, event: String)] = [
    "session_start": ("idle", "SessionStart"),
    "session_end": ("sleeping", "SessionEnd"),
    "message_submit": ("thinking", "UserPromptSubmit"),
    "tool_call_before": ("working", "PreToolUse"),
    "tool_call_after": ("working", "PostToolUse"),
    "mode_change": ("sweeping", "PreCompact"),
    "on_error": ("error", "StopFailure")
  ]

  private static let reasonixState = [
    "SessionStart": "idle",
    "SessionEnd": "sleeping",
    "UserPromptSubmit": "thinking",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Stop": "attention",
    "SubagentStop": "working",
    "Notification": "notification",
    "PreCompact": "sweeping"
  ]

  private static let qoderState: [String: (state: String, event: String)] = [
    "SessionStart": ("idle", "SessionStart"),
    "UserPromptSubmit": ("thinking", "UserPromptSubmit"),
    "PreToolUse": ("working", "PreToolUse"),
    "PostToolUse": ("working", "PostToolUse"),
    "PostToolUseFailure": ("error", "PostToolUseFailure"),
    "Stop": ("attention", "Stop"),
    "Notification": ("notification", "Notification"),
    "PermissionRequest": ("notification", "Notification"),
    "PermissionDenied": ("notification", "Notification"),
    "SessionEnd": ("sleeping", "SessionEnd")
  ]

  private static let qoderToolMetadataEvents: Set<String> = [
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "PermissionDenied"
  ]

  private static let skippedCodexResponseItemTypes: Set<String> = [
    "function_call",
    "function_call_output",
    "custom_tool_call",
    "custom_tool_call_output",
    "web_search_call",
    "reasoning",
    "local_shell_call",
    "tool_call",
    "tool_result"
  ]

  private static let textCodexResponseItemTypes: Set<String> = [
    "message",
    "agent_message",
    "assistant_message",
    "output_text",
    "text"
  ]
}

private extension JSONValue {
  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
}

private extension [String: JSONValue] {
  func string(_ key: String) -> String? {
    if case .string(let value)? = self[key] { return value }
    return nil
  }

  func bool(_ key: String) -> Bool? {
    if case .bool(let value)? = self[key] { return value }
    return nil
  }

  func object(_ key: String) -> [String: JSONValue]? {
    if case .object(let value)? = self[key] { return value }
    return nil
  }

  func arrayCount(_ key: String) -> Int? {
    if case .array(let value)? = self[key] { return value.count }
    return nil
  }
}
