import Foundation

public let localSessionHost = "local"
public let unknownSessionAgent = "unknown"
public let maxSessionAliasLength = 80
public let sessionAliasTTL: TimeInterval = 7 * 24 * 60 * 60

public struct SessionAlias: Codable, Equatable, Sendable {
  public var title: String
  public var updatedAt: Date

  public init(title: String, updatedAt: Date) {
    self.title = title
    self.updatedAt = updatedAt
  }
}

public enum SessionAliasKeys {
  public static func normalizeHost(_ host: String?) -> String {
    let trimmed = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.lowercased() == localSessionHost ? localSessionHost : trimmed
  }

  public static func normalizeAgent(_ agentId: String?) -> String {
    let trimmed = (agentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? unknownSessionAgent : trimmed
  }

  public static func normalizeSessionId(_ sessionId: String?) -> String {
    (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func scope(agentId: String?, sessionId: String?, cwd: String?) -> String {
    let agent = normalizeAgent(agentId)
    let session = normalizeSessionId(sessionId)
    let trimmedCwd = (cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if agent == "kiro-cli" && session == "default" && !trimmedCwd.isEmpty {
      return "cwd:\(trimmedCwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedCwd)"
    }
    return ""
  }

  public static func key(host: String?, agentId: String?, sessionId: String?, cwd: String? = nil) -> String? {
    let session = normalizeSessionId(sessionId)
    guard !session.isEmpty else { return nil }
    var parts = [normalizeHost(host), normalizeAgent(agentId), session]
    let scoped = scope(agentId: agentId, sessionId: sessionId, cwd: cwd)
    if !scoped.isEmpty { parts.append(scoped) }
    return parts.joined(separator: "|")
  }

  public static func sanitizeTitle(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value
      .map { character in
        character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
          ? " "
          : String(character)
      }
      .joined()
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if cleaned.isEmpty { return "" }
    return String(cleaned.prefix(maxSessionAliasLength))
  }

  public static func pruneExpired(_ aliases: [String: SessionAlias], activeKeys: Set<String>, now: Date = Date()) -> [String: SessionAlias] {
    let cutoff = now.addingTimeInterval(-sessionAliasTTL)
    return aliases.filter { key, alias in
      activeKeys.contains(key) || alias.updatedAt >= cutoff
    }
  }
}
