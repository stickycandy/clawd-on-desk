import Foundation

public enum AgentGate {
  public static func isAgentEnabled(_ snapshot: Preferences, _ agentId: String) -> Bool {
    readFlag(snapshot, agentId, keyPath: \.enabled, defaultValue: true)
  }

  public static func isAgentPermissionsEnabled(_ snapshot: Preferences, _ agentId: String) -> Bool {
    readFlag(snapshot, agentId, keyPath: \.permissionsEnabled, defaultValue: true)
  }

  public static func isAgentSubagentPermissionsEnabled(_ snapshot: Preferences, _ agentId: String) -> Bool {
    guard let value = snapshot.agents[agentId]?.subagentPermissionsEnabled else { return true }
    return value
  }

  public static func isAgentNotificationHookEnabled(_ snapshot: Preferences, _ agentId: String) -> Bool {
    readFlag(snapshot, agentId, keyPath: \.notificationHookEnabled, defaultValue: true)
  }

  public static func codexPermissionMode(_ snapshot: Preferences) -> String {
    snapshot.agents["codex"]?.permissionMode == "native" ? "native" : "intercept"
  }

  public static func isCodexPermissionInterceptEnabled(_ snapshot: Preferences) -> Bool {
    codexPermissionMode(snapshot) == "intercept"
  }

  public static func isCodexNativeNotificationSoundEnabled(_ snapshot: Preferences) -> Bool {
    snapshot.agents["codex"]?.nativeNotificationSoundEnabled == true
  }

  private static func readFlag(_ snapshot: Preferences, _ agentId: String, keyPath: KeyPath<AgentSettings, Bool>, defaultValue: Bool) -> Bool {
    guard let entry = snapshot.agents[agentId] else { return defaultValue }
    return entry[keyPath: keyPath]
  }
}
