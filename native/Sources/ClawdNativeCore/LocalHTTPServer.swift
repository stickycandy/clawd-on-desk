import Foundation
import Network

public final class LocalHTTPServer: @unchecked Sendable {
  public static let defaultPorts = Array(23333...23337)
  public static let serverHeader = "X-Clawd-Server"
  public static let serverId = "clawd-on-desk-native"

  private let engine: StateEngine
  private let preferences: @Sendable () -> Preferences
  private let permissions: PermissionCoordinator
  private let projectRoot: URL?
  private let remoteSSHStatuses: @Sendable () -> [RemoteSSHStatus]
  private let queue = DispatchQueue(label: "clawd.native.http")
  private var listener: NWListener?

  public private(set) var port: Int?

  public init(
    engine: StateEngine,
    preferences: @escaping @Sendable () -> Preferences,
    permissions: PermissionCoordinator,
    projectRoot: URL? = nil,
    remoteSSHStatuses: @escaping @Sendable () -> [RemoteSSHStatus] = { [] }
  ) {
    self.engine = engine
    self.preferences = preferences
    self.permissions = permissions
    self.projectRoot = projectRoot
    self.remoteSSHStatuses = remoteSSHStatuses
  }

  @discardableResult
  public func start(ports: [Int] = LocalHTTPServer.defaultPorts) throws -> Int {
    if let port { return port }
    var lastError: Error?
    for candidate in ports {
      do {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(candidate))!)
        listener.newConnectionHandler = { [weak self] connection in
          self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        self.port = candidate
        try writeRuntimeConfig(port: candidate)
        return candidate
      } catch {
        lastError = error
      }
    }
    throw lastError ?? ServerError.noAvailablePort
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    port = nil
  }

  private func writeRuntimeConfig(port: Int) throws {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".clawd", isDirectory: true)
      .appendingPathComponent("runtime.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = ["port": port, "app": LocalHTTPServer.serverId] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic])
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        self.send(connection, status: 500, body: "connection error: \(error.localizedDescription)")
        return
      }
      var next = buffer
      if let data { next.append(data) }
      if let request = HTTPRequest(data: next) {
        self.route(request, connection: connection)
      } else if isComplete {
        self.send(connection, status: 400, body: "bad request")
      } else if next.count > 600_000 {
        self.send(connection, status: 413, body: "payload too large")
      } else {
        self.receive(connection, buffer: next)
      }
    }
  }

  private func route(_ request: HTTPRequest, connection: NWConnection) {
    switch (request.method, request.path) {
    case ("GET", "/state"):
      let activePort = port ?? 23333
      let body = #"{"ok":true,"app":"\#(LocalHTTPServer.serverId)","port":\#(activePort)}"#
      send(connection, status: 200, contentType: "application/json", bodyData: Data(body.utf8))
    case ("POST", "/state"):
      handleState(request, connection: connection)
    case ("POST", "/permission"):
      handlePermission(request, connection: connection)
    case ("GET", "/sessions"):
      let snapshot = engine.snapshot()
      let data = (try? JSONEncoder.iso8601.encode(snapshot)) ?? Data("{}".utf8)
      send(connection, status: 200, contentType: "application/json", bodyData: data)
    case ("GET", "/mobile-preview"):
      let body = MobilePreviewRuntime.html(snapshot: engine.snapshot(), preferences: preferences())
      send(connection, status: 200, contentType: "text/html; charset=utf-8", bodyData: Data(body.utf8))
    case ("GET", "/diagnostics"):
      let items = Diagnostics.localReport(
        serverPort: port,
        preferencesURL: PreferencesStore.defaultURL(),
        projectRoot: projectRoot ?? FileManager.default.currentDirectoryPathURL,
        remoteSSHStatuses: remoteSSHStatuses()
      )
      let data = (try? JSONEncoder.iso8601.encode(items)) ?? Data("[]".utf8)
      send(connection, status: 200, contentType: "application/json", bodyData: data)
    case ("GET", "/remote-ssh/status"):
      let data = (try? JSONEncoder.iso8601.encode(remoteSSHStatuses())) ?? Data("[]".utf8)
      send(connection, status: 200, contentType: "application/json", bodyData: data)
    default:
      send(connection, status: 404, body: "not found")
    }
  }

  private func handleState(_ request: HTTPRequest, connection: NWConnection) {
    guard request.body.count <= 4096 else {
      send(connection, status: 413, body: "state payload too large")
      return
    }
    do {
      let payload = try JSONDecoder().decode(HookStateRequest.self, from: request.body)
      guard let state = ClawdState(rawValue: payload.state) else {
        send(connection, status: 400, body: "unknown state")
        return
      }
      let prefs = preferences()
      let agentId = payload.agentId?.trimmedNonEmpty ?? "claude-code"
      guard AgentGate.isAgentEnabled(prefs, agentId) else {
        send(connection, status: 204, bodyData: Data())
        return
      }
      guard !engine.shouldDropForDnd() else {
        send(connection, status: 204, bodyData: Data())
        return
      }
      let metadata = SessionMetadata(
        sourcePid: payload.sourcePid?.positiveInt,
        agentPid: payload.agentPid?.positiveInt,
        cwd: payload.cwd ?? "",
        editor: payload.editor,
        pidChain: payload.pidChain?.compactMap { $0.positiveInt },
        agentId: agentId,
        host: payload.host?.trimmedNonEmpty ?? "local",
        headless: payload.headless ?? false,
        platform: payload.platform,
        model: payload.model,
        provider: payload.provider,
        displayHint: payload.displaySvg?.lastPathComponent,
        sessionTitle: payload.sessionTitle?.trimmedNonEmpty,
        contextUsage: payload.contextUsage,
        assistantLastOutput: payload.assistantLastOutput?.sanitizedAssistantOutput,
        assistantLastOutputTruncated: payload.assistantLastOutputTruncated ?? false,
        permissionSuspect: payload.permissionSuspect ?? false,
        hookSource: payload.hookSource
      )
      if let svg = payload.svg?.lastPathComponent, !svg.isEmpty {
        engine.setState(state)
      } else {
        engine.updateSession(payload.sessionId?.trimmedNonEmpty ?? "default", state: state, event: payload.event, metadata: metadata)
      }
      send(connection, status: 200, body: "ok")
    } catch {
      send(connection, status: 400, body: "bad json")
    }
  }

  private func handlePermission(_ request: HTTPRequest, connection: NWConnection) {
    guard request.body.count <= 524_288 else {
      respondPermission(connection, decision: .deny(message: "Permission request too large for Clawd bubble; answer in terminal"), agentId: "claude-code")
      return
    }
    do {
      let payload = try JSONDecoder().decode(HookPermissionRequest.self, from: request.body)
      let agentId = payload.agentId?.trimmedNonEmpty ?? "claude-code"
      let prefs = preferences()
      let tool = payload.toolName?.trimmedNonEmpty ?? "unknown"
      let sessionId = payload.sessionId?.trimmedNonEmpty ?? "default"

      if agentId == "pi" {
        respondPermission(connection, decision: .allow, agentId: agentId)
        return
      }
      if agentId == "antigravity-cli" || agentId == "qoder" || agentId == "openclaw" {
        respondPermission(connection, decision: .noDecision, agentId: agentId)
        return
      }
      if !AgentGate.isAgentEnabled(prefs, agentId) || engine.shouldDropForDnd() {
        respondPermission(connection, decision: .noDecision, agentId: agentId)
        return
      }
      if agentId == "codex", !AgentGate.isCodexPermissionInterceptEnabled(prefs) {
        let metadata = SessionMetadata(agentId: "codex")
        engine.updateSession(sessionId, state: .notification, event: "PermissionRequest", metadata: metadata)
        respondPermission(connection, decision: .noDecision, agentId: agentId)
        return
      }
      if prefs.hideBubbles || !prefs.permissionBubblesEnabled || !AgentGate.isAgentPermissionsEnabled(prefs, agentId) {
        respondPermission(connection, decision: .noDecision, agentId: agentId)
        return
      }

      let permission = PermissionRequest(
        agentId: agentId,
        sessionId: sessionId,
        toolName: tool,
        toolInput: payload.toolInput ?? .object([:]),
        toolInputDescription: payload.toolInputDescription?.trimmedNonEmpty,
        requestId: payload.requestId,
        bridgeURL: payload.bridgeURL,
        bridgeToken: payload.bridgeToken,
        isElicitation: tool == "AskUserQuestion",
        suggestions: Self.suggestionsAllowed(for: agentId) ? (payload.permissionSuggestions ?? []) : []
      )
      engine.updateSession(sessionId, state: .notification, event: "PermissionRequest", metadata: SessionMetadata(agentId: agentId))
      permissions.enqueue(permission) { [weak self, weak connection] decision in
        guard let self, let connection else { return }
        self.respondPermission(connection, decision: decision, agentId: agentId)
      }
    } catch {
      send(connection, status: 400, body: "bad json")
    }
  }

  private func respondPermission(_ connection: NWConnection, decision: PermissionDecision, agentId: String) {
    if decision == .noDecision {
      send(connection, status: 204, bodyData: Data())
      return
    }
    let hookName = "PermissionRequest"
    guard let data = PermissionResponseBuilder.body(for: decision, hookEventName: hookName) else {
      send(connection, status: 204, bodyData: Data())
      return
    }
    send(connection, status: 200, contentType: "application/json", bodyData: data)
  }

  private static func suggestionsAllowed(for agentId: String) -> Bool {
    agentId == "claude-code" || agentId == "codebuddy" || agentId == "hermes"
  }

  private func send(_ connection: NWConnection, status: Int, contentType: String = "text/plain; charset=utf-8", body: String) {
    send(connection, status: status, contentType: contentType, bodyData: Data(body.utf8))
  }

  private func send(_ connection: NWConnection, status: Int, contentType: String = "text/plain; charset=utf-8", bodyData: Data) {
    let reason = HTTPStatus.reasonPhrase(status)
    var headers = "HTTP/1.1 \(status) \(reason)\r\n"
    headers += "\(LocalHTTPServer.serverHeader): \(LocalHTTPServer.serverId)\r\n"
    headers += "Content-Length: \(bodyData.count)\r\n"
    if !bodyData.isEmpty {
      headers += "Content-Type: \(contentType)\r\n"
    }
    headers += "Connection: close\r\n\r\n"
    var response = Data(headers.utf8)
    response.append(bodyData)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  public enum ServerError: Error {
    case noAvailablePort
  }
}

private struct HTTPRequest {
  var method: String
  var path: String
  var headers: [String: String]
  var body: Data

  init?(data: Data) {
    guard let text = String(data: data, encoding: .utf8),
          let range = text.range(of: "\r\n\r\n")
    else { return nil }
    let headerText = String(text[..<range.lowerBound])
    let headerLength = text.distance(from: text.startIndex, to: range.upperBound)
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    guard data.count >= headerLength + length else { return nil }
    self.method = parts[0]
    self.path = parts[1].split(separator: "?").first.map(String.init) ?? parts[1]
    self.headers = headers
    self.body = data.subdata(in: headerLength..<(headerLength + length))
  }
}

private struct HookStateRequest: Decodable {
  var state: String
  var svg: String?
  var sessionId: String?
  var event: String?
  var displaySvg: String?
  var sourcePid: Double?
  var cwd: String?
  var editor: String?
  var pidChain: [Double]?
  var agentPid: Double?
  var agentId: String?
  var host: String?
  var headless: Bool?
  var platform: String?
  var model: String?
  var provider: String?
  var sessionTitle: String?
  var contextUsage: ContextUsage?
  var assistantLastOutput: String?
  var assistantLastOutputTruncated: Bool?
  var permissionSuspect: Bool?
  var hookSource: String?

  enum CodingKeys: String, CodingKey {
    case state, svg, event, cwd, editor, host, headless, platform, model, provider
    case sessionId = "session_id"
    case displaySvg = "display_svg"
    case sourcePid = "source_pid"
    case pidChain = "pid_chain"
    case agentPid = "agent_pid"
    case agentId = "agent_id"
    case sessionTitle = "session_title"
    case contextUsage = "context_usage"
    case assistantLastOutput = "assistant_last_output"
    case assistantLastOutputTruncated = "assistant_last_output_truncated"
    case permissionSuspect = "permission_suspect"
    case hookSource = "hook_source"
  }
}

private struct HookPermissionRequest: Decodable {
  var agentId: String?
  var sessionId: String?
  var toolName: String?
  var toolInput: JSONValue?
  var toolInputDescription: String?
  var requestId: String?
  var bridgeURL: String?
  var bridgeToken: String?
  var permissionSuggestions: [JSONValue]?

  enum CodingKeys: String, CodingKey {
    case agentId = "agent_id"
    case sessionId = "session_id"
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case toolInputDescription = "tool_input_description"
    case requestId = "request_id"
    case bridgeURL = "bridge_url"
    case bridgeToken = "bridge_token"
    case permissionSuggestions = "permission_suggestions"
  }
}

private enum HTTPStatus {
  static func reasonPhrase(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 413: return "Payload Too Large"
    case 500: return "Internal Server Error"
    default: return "OK"
    }
  }
}

private extension JSONEncoder {
  static var iso8601: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

private extension FileManager {
  var currentDirectoryPathURL: URL {
    URL(fileURLWithPath: currentDirectoryPath)
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var lastPathComponent: String {
    (self as NSString).lastPathComponent
  }

  var sanitizedAssistantOutput: String? {
    let cleaned = replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: .controlCharacters)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty { return nil }
    return String(cleaned.prefix(2400))
  }
}

private extension Double {
  var positiveInt: Int? {
    guard isFinite && self > 0 else { return nil }
    return Int(self.rounded(.down))
  }
}
