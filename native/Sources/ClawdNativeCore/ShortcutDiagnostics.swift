import Foundation

public struct ShortcutDiagnostic: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var status: String
  public var message: String

  public init(id: String, status: String, message: String) {
    self.id = id
    self.status = status
    self.message = message
  }
}

public enum ShortcutDiagnostics {
  public static let supportedActions: [String] = [
    "togglePet",
    "permissionAllow",
    "permissionDeny"
  ]

  public static func validate(_ shortcuts: [String: String]) -> [ShortcutDiagnostic] {
    var diagnostics: [ShortcutDiagnostic] = []
    var seen: [String: String] = [:]

    for action in supportedActions {
      let raw = shortcuts[action] ?? ""
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        diagnostics.append(.init(
          id: "shortcut:\(action)",
          status: "idle",
          message: "\(action) disabled"
        ))
        continue
      }

      guard let parsed = ParsedShortcut(trimmed) else {
        diagnostics.append(.init(
          id: "shortcut:\(action)",
          status: "warning",
          message: "\(action) has invalid accelerator: \(trimmed)"
        ))
        continue
      }

      let normalized = parsed.normalized
      if let otherAction = seen[normalized] {
        diagnostics.append(.init(
          id: "shortcut-conflict:\(action)",
          status: "warning",
          message: "\(action) conflicts with \(otherAction): \(normalized)"
        ))
      } else {
        seen[normalized] = action
        diagnostics.append(.init(
          id: "shortcut:\(action)",
          status: "ok",
          message: "\(action): \(normalized)"
        ))
      }
    }

    return diagnostics
  }

  public static func isValid(_ accelerator: String) -> Bool {
    ParsedShortcut(accelerator) != nil
  }

  private struct ParsedShortcut {
    var commandOrControl = false
    var shift = false
    var alt = false
    var key = ""

    var normalized: String {
      var parts: [String] = []
      if commandOrControl { parts.append("CommandOrControl") }
      if shift { parts.append("Shift") }
      if alt { parts.append("Alt") }
      parts.append(key)
      return parts.joined(separator: "+")
    }

    init?(_ value: String?) {
      guard let value else { return nil }
      let parts = value.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      guard parts.count >= 2 else { return nil }
      for part in parts {
        switch part.lowercased() {
        case "commandorcontrol", "cmdorctrl", "cmdorcontrol", "command", "cmd", "control", "ctrl":
          commandOrControl = true
        case "shift":
          shift = true
        case "alt", "option":
          alt = true
        default:
          if !key.isEmpty { return nil }
          key = part.uppercased()
        }
      }
      guard !key.isEmpty else { return nil }
      guard commandOrControl || shift || alt else { return nil }
    }
  }
}
