import Foundation

public struct RemoteSSHStatus: Codable, Equatable, Sendable {
  public var profileId: String
  public var state: String
  public var message: String
  public var localPort: Int?

  public init(profileId: String, state: String, message: String, localPort: Int? = nil) {
    self.profileId = profileId
    self.state = state
    self.message = message
    self.localPort = localPort
  }
}

public final class RemoteSSHRuntime: @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [String: Process] = [:]

  public init() {}

  public static func tunnelCommand(profile: RemoteSSHProfile, localPort: Int) -> [String] {
    let destination = profile.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? profile.host
      : "\(profile.user)@\(profile.host)"
    return [
      "ssh",
      "-N",
      "-R",
      "127.0.0.1:23333:127.0.0.1:\(localPort)",
      "-p",
      String(profile.port),
      destination
    ]
  }

  public static func deployCommand(profile: RemoteSSHProfile) -> [String] {
    let destination = profile.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? profile.host
      : "\(profile.user)@\(profile.host)"
    return ["bash", "scripts/remote-deploy.sh", destination]
  }

  @discardableResult
  public func startTunnel(profile: RemoteSSHProfile, localPort: Int) -> RemoteSSHStatus {
    lock.lock()
    if processes[profile.id]?.isRunning == true {
      lock.unlock()
      return RemoteSSHStatus(profileId: profile.id, state: "running", message: "Tunnel already running", localPort: localPort)
    }
    lock.unlock()

    let command = Self.tunnelCommand(profile: profile, localPort: localPort)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      lock.lock()
      processes[profile.id] = process
      lock.unlock()
      return RemoteSSHStatus(profileId: profile.id, state: "running", message: command.joined(separator: " "), localPort: localPort)
    } catch {
      return RemoteSSHStatus(profileId: profile.id, state: "error", message: error.localizedDescription, localPort: localPort)
    }
  }

  public func stopTunnel(profileId: String) -> RemoteSSHStatus {
    lock.lock()
    let process = processes.removeValue(forKey: profileId)
    lock.unlock()
    guard let process else {
      return RemoteSSHStatus(profileId: profileId, state: "stopped", message: "No tunnel process")
    }
    if process.isRunning {
      process.terminate()
    }
    return RemoteSSHStatus(profileId: profileId, state: "stopped", message: "Tunnel stopped")
  }

  public func stopAll() {
    lock.lock()
    let running = processes
    processes.removeAll()
    lock.unlock()
    for process in running.values where process.isRunning {
      process.terminate()
    }
  }
}
