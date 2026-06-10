import Foundation

public enum PermissionDecision: Equatable, Sendable {
  case allow
  case allowWithUpdatedPermissions([JSONValue])
  case deny(message: String?)
  case noDecision
}

public struct PermissionRequest: Codable, Equatable, Sendable {
  public var agentId: String
  public var sessionId: String
  public var toolName: String
  public var toolInput: JSONValue
  public var toolInputDescription: String?
  public var requestId: String?
  public var bridgeURL: String?
  public var bridgeToken: String?
  public var isElicitation: Bool
  public var suggestions: [JSONValue]

  public init(
    agentId: String = "claude-code",
    sessionId: String = "default",
    toolName: String,
    toolInput: JSONValue = .object([:]),
    toolInputDescription: String? = nil,
    requestId: String? = nil,
    bridgeURL: String? = nil,
    bridgeToken: String? = nil,
    isElicitation: Bool = false,
    suggestions: [JSONValue] = []
  ) {
    self.agentId = agentId
    self.sessionId = sessionId
    self.toolName = toolName
    self.toolInput = toolInput
    self.toolInputDescription = toolInputDescription
    self.requestId = requestId
    self.bridgeURL = bridgeURL
    self.bridgeToken = bridgeToken
    self.isElicitation = isElicitation
    self.suggestions = Array(suggestions.prefix(20))
  }
}

public final class PendingPermission: Identifiable, @unchecked Sendable {
  public let id = UUID()
  public let request: PermissionRequest
  public let createdAt: Date
  private let lock = NSLock()
  private var resolver: ((PermissionDecision) -> Void)?

  init(request: PermissionRequest, createdAt: Date = Date(), resolver: @escaping (PermissionDecision) -> Void) {
    self.request = request
    self.createdAt = createdAt
    self.resolver = resolver
  }

  public func resolve(_ decision: PermissionDecision) {
    lock.lock()
    let callback = resolver
    resolver = nil
    lock.unlock()
    callback?(decision)
  }
}

public final class PermissionCoordinator: @unchecked Sendable {
  public typealias Presenter = @Sendable (PendingPermission) -> Void

  private let lock = NSLock()
  private var pending: [UUID: PendingPermission] = [:]
  public var presenter: Presenter?

  public init() {}

  @discardableResult
  public func enqueue(_ request: PermissionRequest, resolver: @escaping (PermissionDecision) -> Void) -> PendingPermission {
    var entry: PendingPermission!
    entry = PendingPermission(request: request) { [weak self] decision in
      resolver(decision)
      self?.remove(entry.id)
    }
    lock.lock()
    pending[entry.id] = entry
    lock.unlock()
    presenter?(entry)
    return entry
  }

  public func pendingPermissions() -> [PendingPermission] {
    lock.lock()
    defer { lock.unlock() }
    return Array(pending.values)
  }

  public func cancelAll(with decision: PermissionDecision = .noDecision) {
    let values: [PendingPermission]
    lock.lock()
    values = Array(pending.values)
    pending.removeAll()
    lock.unlock()
    values.forEach { $0.resolve(decision) }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    pending.removeValue(forKey: id)
    lock.unlock()
  }
}

public enum PermissionResponseBuilder {
  public static func body(for decision: PermissionDecision, hookEventName: String = "PermissionRequest") -> Data? {
    switch decision {
    case .noDecision:
      return nil
    case .allow:
      return try? JSONEncoder().encode(HookSpecificOutput(hookSpecificOutput: .init(hookEventName: hookEventName, decision: .init(behavior: "allow", message: nil, updatedPermissions: nil))))
    case .allowWithUpdatedPermissions(let permissions):
      return try? JSONEncoder().encode(HookSpecificOutput(hookSpecificOutput: .init(hookEventName: hookEventName, decision: .init(behavior: "allow", message: nil, updatedPermissions: permissions))))
    case .deny(let message):
      return try? JSONEncoder().encode(HookSpecificOutput(hookSpecificOutput: .init(hookEventName: hookEventName, decision: .init(behavior: "deny", message: message, updatedPermissions: nil))))
    }
  }

  private struct HookSpecificOutput: Codable {
    var hookSpecificOutput: Output
  }

  private struct Output: Codable {
    var hookEventName: String
    var decision: Decision
  }

  private struct Decision: Codable {
    var behavior: String
    var message: String?
    var updatedPermissions: [JSONValue]?
  }
}

public enum PermissionSuggestionFormatter {
  public static func label(for suggestion: JSONValue) -> String {
    guard case .object(let object) = suggestion else { return "Apply suggestion" }
    let type = object.string("type") ?? "permission"
    if type == "setMode" {
      return "Set mode: \(object.string("mode") ?? "default")"
    }
    if type == "addRules" {
      if case .array(let rules) = object["rules"], !rules.isEmpty {
        return "Always allow \(rules.count) rule\(rules.count == 1 ? "" : "s")"
      }
      let tool = object.string("toolName") ?? "tool"
      let behavior = object.string("behavior") ?? "allow"
      return "\(behavior.capitalized) \(tool)"
    }
    return type
  }

  public static func updatedPermission(from suggestion: JSONValue) -> JSONValue {
    guard case .object(let object) = suggestion else { return suggestion }
    let type = object.string("type")
    if type == "addRules" {
      let rules: JSONValue
      if let existing = object["rules"] {
        rules = existing
      } else {
        rules = .array([
          .object([
            "toolName": object["toolName"] ?? .string(""),
            "ruleContent": object["ruleContent"] ?? .string("")
          ])
        ])
      }
      return .object([
        "type": .string("addRules"),
        "destination": object["destination"] ?? .string("localSettings"),
        "behavior": object["behavior"] ?? .string("allow"),
        "rules": rules
      ])
    }
    if type == "setMode" {
      return .object([
        "type": .string("setMode"),
        "mode": object["mode"] ?? .string("default"),
        "destination": object["destination"] ?? .string("localSettings")
      ])
    }
    return .object(object)
  }
}

private extension Dictionary where Key == String, Value == JSONValue {
  func string(_ key: String) -> String? {
    guard case .string(let value) = self[key] else { return nil }
    return value
  }
}
