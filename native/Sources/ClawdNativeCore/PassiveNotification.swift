import Foundation

public enum PassiveNotificationKind: String, Codable, Equatable, Sendable {
  case codexPermission
  case kimiPermission
  case terminalAttention
}

public struct PassiveNotificationRequest: Codable, Equatable, Sendable {
  public var kind: PassiveNotificationKind
  public var agentId: String
  public var sessionId: String
  public var title: String
  public var message: String
  public var detail: String?
  public var createdAt: Date

  public init(
    kind: PassiveNotificationKind,
    agentId: String,
    sessionId: String,
    title: String,
    message: String,
    detail: String? = nil,
    createdAt: Date = Date()
  ) {
    self.kind = kind
    self.agentId = agentId
    self.sessionId = sessionId
    self.title = title
    self.message = message
    self.detail = detail
    self.createdAt = createdAt
  }
}

public enum PassiveNotificationEvent: Equatable, Sendable {
  case show(PassiveNotificationRequest)
  case clear(agentId: String?, sessionId: String?, reason: String)
}
