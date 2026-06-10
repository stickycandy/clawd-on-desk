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

  public init(projectRoot: URL) {
    self.projectRoot = projectRoot
  }

  public func syncEnabledStartupIntegrations(preferences: Preferences) -> [IntegrationResult] {
    AgentRegistry.all.compactMap { descriptor in
      guard AgentGate.isAgentEnabled(preferences, descriptor.id) else { return nil }
      guard let command = descriptor.installCommand else { return nil }
      return run(command, agentId: descriptor.id)
    }
  }

  public func repair(agentId: String) -> IntegrationResult {
    guard let descriptor = AgentRegistry.agent(agentId), let command = descriptor.installCommand else {
      return IntegrationResult(agentId: agentId, command: [], status: "skip", output: "No installer registered")
    }
    return run(command, agentId: agentId)
  }

  public func uninstall(agentId: String) -> IntegrationResult {
    guard let descriptor = AgentRegistry.agent(agentId), let command = descriptor.uninstallCommand else {
      return IntegrationResult(agentId: agentId, command: [], status: "skip", output: "No uninstaller registered")
    }
    return run(command, agentId: agentId)
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
        status: process.terminationStatus == 0 ? "ok" : "error",
        output: output
      )
    } catch {
      return IntegrationResult(agentId: agentId, command: command, status: "error", output: error.localizedDescription)
    }
  }
}
