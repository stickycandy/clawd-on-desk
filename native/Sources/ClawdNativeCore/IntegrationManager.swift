import Foundation

public struct IntegrationResult: Codable, Equatable, Sendable {
  public var agentId: String
  public var command: [String]
  public var status: String
  public var output: String

  public init(agentId: String, command: [String], status: String, output: String) {
    self.agentId = agentId
    self.command = command
    self.status = status
    self.output = output
  }
}

public final class IntegrationManager: @unchecked Sendable {
  public let projectRoot: URL
  private let nativeInstaller: NativeIntegrationInstaller

  public init(projectRoot: URL) {
    self.projectRoot = projectRoot
    self.nativeInstaller = NativeIntegrationInstaller(projectRoot: projectRoot)
  }

  public func syncEnabledStartupIntegrations(preferences: Preferences) -> [IntegrationResult] {
    AgentRegistry.all.compactMap { descriptor in
      guard AgentGate.shouldSyncAgentIntegration(preferences, descriptor.id) else { return nil }
      if let native = nativeInstaller.install(agentId: descriptor.id, preferences: preferences) {
        return IntegrationResult(
          agentId: descriptor.id,
          command: ["native", "install", descriptor.id],
          status: native.status,
          output: native.output
        )
      }
      guard let command = descriptor.installCommand else { return nil }
      return run(command, agentId: descriptor.id)
    }
  }

  public func repairAll(preferences: Preferences) -> [IntegrationResult] {
    AgentRegistry.all.compactMap { descriptor in
      guard AgentGate.shouldSyncAgentIntegration(preferences, descriptor.id) else { return nil }
      return install(agentId: descriptor.id, preferences: preferences, action: "repair")
    }
  }

  public func install(agentId: String, preferences: Preferences) -> IntegrationResult {
    install(agentId: agentId, preferences: preferences, action: "install")
  }

  public func repair(agentId: String) -> IntegrationResult {
    install(agentId: agentId, preferences: Preferences(), action: "repair")
  }

  private func install(agentId: String, preferences: Preferences, action: String) -> IntegrationResult {
    if let native = nativeInstaller.install(agentId: agentId, preferences: preferences) {
      return IntegrationResult(
        agentId: agentId,
        command: ["native", action, agentId],
        status: native.status,
        output: native.output
      )
    }
    guard let descriptor = AgentRegistry.agent(agentId), let command = descriptor.installCommand else {
      return IntegrationResult(agentId: agentId, command: [], status: "skip", output: "No installer registered")
    }
    return run(command, agentId: agentId)
  }

  public func uninstall(agentId: String) -> IntegrationResult {
    if let native = nativeInstaller.uninstall(agentId: agentId) {
      return IntegrationResult(
        agentId: agentId,
        command: ["native", "uninstall", agentId],
        status: native.status,
        output: native.output
      )
    }
    guard let descriptor = AgentRegistry.agent(agentId), let command = descriptor.uninstallCommand else {
      return IntegrationResult(agentId: agentId, command: [], status: "skip", output: "No uninstaller registered")
    }
    return run(command, agentId: agentId)
  }

  public func cleanupAll() -> IntegrationResult {
    run(["node", "hooks/cleanup-integrations.js", "--apply", "--silent", "--fail-open"], agentId: "all")
  }

  private func run(_ command: [String], agentId: String) -> IntegrationResult {
    guard let executable = command.first else {
      return IntegrationResult(agentId: agentId, command: command, status: "error", output: "Empty command")
    }
    let process = Process()
    process.currentDirectoryURL = projectRoot
    process.executableURL = executable.contains("/")
      ? URL(fileURLWithPath: executable)
      : URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = executable.contains("/") ? Array(command.dropFirst()) : command
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(decoding: data, as: UTF8.self)
      return IntegrationResult(
        agentId: agentId,
        command: command,
        status: Self.normalizedProcessStatus(
          terminationStatus: process.terminationStatus,
          output: output
        ),
        output: output
      )
    } catch {
      return IntegrationResult(agentId: agentId, command: command, status: "error", output: error.localizedDescription)
    }
  }

  static func normalizedProcessStatus(terminationStatus: Int32, output: String) -> String {
    guard terminationStatus == 0 else { return "error" }
    return outputLooksLikeMissingInstallSkip(output) ? "skip" : "ok"
  }

  private static func outputLooksLikeMissingInstallSkip(_ output: String) -> Bool {
    output
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .contains { line in
        if line.contains("not installed") && (line.contains("skipping") || line.contains("skipped")) {
          return true
        }
        if line.contains("config not found") {
          return true
        }
        guard line.contains("not found") else { return false }
        guard line.contains("skipping") || line.contains("skipped") else { return false }
        return line.contains("hook")
          || line.contains("plugin")
          || line.contains("extension")
          || line.contains("registration")
          || line.contains("cleanup")
          || line.contains("disable")
      }
  }
}
