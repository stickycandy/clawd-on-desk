import Foundation

public struct TelegramApprovalConfig: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var botTokenFile: String
  public var chatId: String

  public init(enabled: Bool = false, botTokenFile: String = "~/.clawd/telegram-token", chatId: String = "") {
    self.enabled = enabled
    self.botTokenFile = botTokenFile
    self.chatId = chatId
  }
}

public struct TelegramApprovalStatus: Codable, Equatable, Sendable {
  public var status: String
  public var message: String

  public init(status: String, message: String) {
    self.status = status
    self.message = message
  }
}

public enum TelegramApprovalRuntime {
  public static func validate(_ config: TelegramApprovalConfig, fileManager: FileManager = .default) -> TelegramApprovalStatus {
    guard config.enabled else {
      return TelegramApprovalStatus(status: "off", message: "Telegram approval is disabled")
    }
    guard !config.chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return TelegramApprovalStatus(status: "warning", message: "chatId is missing")
    }
    let path = expandTilde(config.botTokenFile)
    guard fileManager.fileExists(atPath: path) else {
      return TelegramApprovalStatus(status: "warning", message: "Bot token file is missing")
    }
    return TelegramApprovalStatus(status: "ok", message: "Telegram approval is configured")
  }

  public static func approvalText(permission: PermissionRequest) -> String {
    """
    \(permission.agentId) requests permission
    Tool: \(permission.toolName)
    Session: \(permission.sessionId)
    Input: \(permission.toolInput.shortDescription)
    """
  }

  public static func callbackData(permissionId: UUID, action: PermissionDecisionAction) -> String {
    "clawd:\(permissionId.uuidString):\(action.rawValue)"
  }

  public static func parseCallbackData(_ value: String) -> (permissionId: UUID, action: PermissionDecisionAction)? {
    let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "clawd", let id = UUID(uuidString: parts[1]), let action = PermissionDecisionAction(rawValue: parts[2]) else {
      return nil
    }
    return (id, action)
  }

  public static func sendMessagePayload(permissionId: UUID, permission: PermissionRequest, config: TelegramApprovalConfig) -> [String: Any] {
    [
      "chat_id": config.chatId,
      "text": approvalText(permission: permission),
      "reply_markup": [
        "inline_keyboard": [[
          ["text": "Allow", "callback_data": callbackData(permissionId: permissionId, action: .allow)],
          ["text": "Deny", "callback_data": callbackData(permissionId: permissionId, action: .deny)],
          ["text": "Use Terminal", "callback_data": callbackData(permissionId: permissionId, action: .noDecision)]
        ]]
      ]
    ]
  }

  private static func expandTilde(_ value: String) -> String {
    if value == "~" {
      return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if value.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(value.dropFirst(2)))
        .path
    }
    return value
  }
}

public enum PermissionDecisionAction: String, Codable, Equatable, Sendable {
  case allow
  case deny
  case noDecision = "no-decision"

  public var decision: PermissionDecision {
    switch self {
    case .allow:
      return .allow
    case .deny:
      return .deny(message: "Denied from Telegram")
    case .noDecision:
      return .noDecision
    }
  }
}

public final class TelegramApprovalSidecar: @unchecked Sendable {
  private let configProvider: @Sendable () -> TelegramApprovalConfig
  private let session: URLSession
  private let queue = DispatchQueue(label: "clawd.native.telegram")
  private var pending: [UUID: PendingPermission] = [:]
  private var updateOffset: Int?
  private var polling = false

  public init(configProvider: @escaping @Sendable () -> TelegramApprovalConfig, session: URLSession = .shared) {
    self.configProvider = configProvider
    self.session = session
  }

  public func sendApproval(_ permission: PendingPermission) {
    let config = configProvider()
    guard TelegramApprovalRuntime.validate(config).status == "ok" else { return }
    queue.async {
      self.pending[permission.id] = permission
      self.sendMessage(permission, config: config)
      self.startPollingIfNeeded(config: config)
    }
  }

  private func sendMessage(_ permission: PendingPermission, config: TelegramApprovalConfig) {
    do {
      let request = try makeRequest(method: "sendMessage", config: config, payload: TelegramApprovalRuntime.sendMessagePayload(permissionId: permission.id, permission: permission.request, config: config))
      session.dataTask(with: request).resume()
    } catch {
      pending.removeValue(forKey: permission.id)
    }
  }

  private func startPollingIfNeeded(config: TelegramApprovalConfig) {
    guard !polling else { return }
    polling = true
    poll(config: config)
  }

  private func poll(config: TelegramApprovalConfig) {
    guard !pending.isEmpty else {
      polling = false
      return
    }
    var payload: [String: Any] = ["timeout": 15, "allowed_updates": ["callback_query"]]
    if let updateOffset { payload["offset"] = updateOffset }
    do {
      let request = try makeRequest(method: "getUpdates", config: config, payload: payload)
      session.dataTask(with: request) { data, _, _ in
        self.queue.async {
          if let data {
            self.handleUpdates(data, config: config)
          }
          self.queue.asyncAfter(deadline: .now() + .seconds(1)) {
            self.poll(config: config)
          }
        }
      }.resume()
    } catch {
      polling = false
    }
  }

  private func handleUpdates(_ data: Data, config: TelegramApprovalConfig) {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = root["result"] as? [[String: Any]]
    else { return }
    for update in result {
      if let updateId = update["update_id"] as? Int {
        updateOffset = max(updateOffset ?? 0, updateId + 1)
      }
      guard let callback = update["callback_query"] as? [String: Any],
            let data = callback["data"] as? String,
            let parsed = TelegramApprovalRuntime.parseCallbackData(data)
      else { continue }
      if let permission = pending.removeValue(forKey: parsed.permissionId) {
        permission.resolve(parsed.action.decision)
      }
      if let callbackId = callback["id"] as? String {
        answerCallback(id: callbackId, config: config)
      }
    }
  }

  private func answerCallback(id: String, config: TelegramApprovalConfig) {
    guard let request = try? makeRequest(method: "answerCallbackQuery", config: config, payload: ["callback_query_id": id]) else { return }
    session.dataTask(with: request).resume()
  }

  private func makeRequest(method: String, config: TelegramApprovalConfig, payload: [String: Any]) throws -> URLRequest {
    let tokenPath = expandTilde(config.botTokenFile)
    let token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
    return request
  }
}

private func expandTilde(_ value: String) -> String {
  if value == "~" {
    return FileManager.default.homeDirectoryForCurrentUser.path
  }
  if value.hasPrefix("~/") {
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(String(value.dropFirst(2)))
      .path
  }
  return value
}
