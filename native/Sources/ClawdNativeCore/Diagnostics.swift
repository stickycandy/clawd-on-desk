import Foundation

public struct DiagnosticItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var status: String
  public var message: String

  public init(id: String, status: String, message: String) {
    self.id = id
    self.status = status
    self.message = message
  }
}

public enum Diagnostics {
  private static let agentRuntimeDependencyPaths = [
    "agents/kimi-cli.js"
  ]

  public static func localReport(
    serverPort: Int?,
    preferencesURL: URL,
    projectRoot: URL,
    preferences: Preferences = Preferences(),
    remoteSSHStatuses: [RemoteSSHStatus] = []
  ) -> [DiagnosticItem] {
    var items: [DiagnosticItem] = []
    if let serverPort {
      items.append(.init(id: "local-server", status: "ok", message: "Listening on 127.0.0.1:\(serverPort)"))
    } else {
      items.append(.init(id: "local-server", status: "error", message: "Local hook server is not running"))
    }
    items.append(.init(
      id: "preferences",
      status: FileManager.default.fileExists(atPath: preferencesURL.path) ? "ok" : "warning",
      message: preferencesURL.path
    ))
    let themes = projectRoot.appendingPathComponent("themes", isDirectory: true)
    items.append(.init(
      id: "themes",
      status: FileManager.default.fileExists(atPath: themes.path) ? "ok" : "warning",
      message: themes.path
    ))
    let themeRuntime = ThemeRuntime(projectRoot: projectRoot)
    let variant = preferences.themeVariant[preferences.theme] ?? "default"
    if let _ = try? themeRuntime.loadTheme(id: preferences.theme, variantId: variant, overrides: preferences.themeOverrides[preferences.theme]) {
      items.append(.init(id: "theme-health", status: "ok", message: "\(preferences.theme) (\(variant)) validated"))
    } else {
      items.append(.init(id: "theme-health", status: "warning", message: "\(preferences.theme) could not be validated"))
    }
    let enabledAgents = AgentRegistry.all.filter { AgentGate.isAgentEnabled(preferences, $0.id) }
    items.append(.init(id: "agent-gates", status: "ok", message: "\(enabledAgents.count)/\(AgentRegistry.all.count) agents enabled"))
    let hooksDir = projectRoot.appendingPathComponent("hooks", isDirectory: true)
    let missingInstallers = AgentRegistry.all.compactMap { agent -> String? in
      guard let command = agent.installCommand, command.count >= 2 else { return nil }
      let script = command[1]
      guard script.hasPrefix("hooks/") else { return nil }
      return FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(script).path) ? nil : agent.id
    }
    items.append(.init(
      id: "agent-installers",
      status: missingInstallers.isEmpty && FileManager.default.fileExists(atPath: hooksDir.path) ? "ok" : "warning",
      message: missingInstallers.isEmpty ? "Installer scripts present" : "Missing installers: \(missingInstallers.joined(separator: ", "))"
    ))
    let missingRuntimeDependencies = agentRuntimeDependencyPaths.filter {
      !FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent($0).path)
    }
    items.append(.init(
      id: "agent-runtime",
      status: missingRuntimeDependencies.isEmpty ? "ok" : "warning",
      message: missingRuntimeDependencies.isEmpty
        ? "Agent runtime dependencies present"
        : "Missing runtime dependencies: \(missingRuntimeDependencies.joined(separator: ", "))"
    ))
    let nativeAgents = NativeIntegrationInstaller.supportedAgentIds.sorted().joined(separator: ", ")
    items.append(.init(
      id: "native-installers",
      status: "ok",
      message: "Swift installers: \(nativeAgents)"
    ))
    let shortcutWarnings = ShortcutDiagnostics.validate(preferences.shortcuts)
      .filter { $0.status == "warning" }
    items.append(.init(
      id: "shortcuts",
      status: shortcutWarnings.isEmpty ? "ok" : "warning",
      message: shortcutWarnings.isEmpty
        ? "Shortcuts valid"
        : shortcutWarnings.map(\.message).joined(separator: "; ")
    ))
    items.append(.init(
      id: "macos-behavior",
      status: "ok",
      message: [
        preferences.openAtLogin ? "open-at-login:on" : "open-at-login:off",
        preferences.keepAwakeWhileWorking ? "keep-awake:on" : "keep-awake:off",
        preferences.flashTaskbarOnComplete ? "dock-flash:on" : "dock-flash:off",
        preferences.miniMode && !preferences.disableMiniMode ? "mini:on" : "mini:off"
      ].joined(separator: ", ")
    ))
    if remoteSSHStatuses.isEmpty {
      items.append(.init(id: "remote-ssh", status: "idle", message: "No active Remote SSH tunnel"))
    } else {
      for status in remoteSSHStatuses {
        items.append(.init(
          id: "remote-ssh:\(status.profileId)",
          status: status.state,
          message: status.message
        ))
      }
    }
    return items
  }
}
