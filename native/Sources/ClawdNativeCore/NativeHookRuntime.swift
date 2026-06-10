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
    default:
      return .none
    }
  }

  public static func runtimePort(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int? {
    let url = homeDirectory
      .appendingPathComponent(".clawd", isDirectory: true)
      .appendingPathComponent("runtime.json")
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
    if let title = normalizedTitle(payload.string("session_title")) {
      body["session_title"] = .string(title)
    } else if event == "UserPromptSubmit", let title = normalizedPromptTitle(payload.string("prompt")) {
      body["session_title"] = .string(title)
    }
    if event == "Stop" {
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
    if hookEvent == "PermissionRequest" {
      var body = basePermission(
        agentId: "codex",
        sessionId: normalizeSessionId(payload.string("session_id"), prefix: "codex"),
        toolName: payload.string("tool_name") ?? "Unknown",
        payload: payload
      )
      body["hook_source"] = .string("codex-official")
      if let description = payload.object("tool_input")?.string("description") {
        body["tool_input_description"] = .string(String(description.prefix(500)))
      }
      addCodexFields(payload: payload, body: &body)
      return .permission(.object(body))
    }
    guard let state = Self.codexState[hookEvent] else { return .none }
    if hookEvent == "Stop", payload.bool("stop_hook_active") == true { return .none }
    var body = baseState(
      state: state,
      sessionId: normalizeSessionId(payload.string("session_id"), prefix: "codex"),
      event: hookEvent,
      agentId: "codex",
      payload: payload
    )
    body["hook_source"] = .string("codex-official")
    addToolMetadata(payload: payload, body: &body)
    addCodexFields(payload: payload, body: &body)
    if let active = payload.bool("stop_hook_active") {
      body["stop_hook_active"] = .bool(active)
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
      body["source_pid"] = .number(Double(ProcessInfo.processInfo.processIdentifier))
      body["platform"] = .string("darwin")
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

  private func addCodexFields(payload: [String: JSONValue], body: inout [String: JSONValue]) {
    if let originator = payload.string("originator"), !originator.isEmpty {
      body["codex_originator"] = .string(originator)
    }
    if let source = payload.string("source"), !source.isEmpty {
      body["codex_source"] = .string(source)
    }
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
