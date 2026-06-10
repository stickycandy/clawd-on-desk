import Foundation

public struct UpdateCommandPlan: Codable, Equatable, Sendable {
  public var check: [String]
  public var apply: [[String]]

  public init(check: [String], apply: [[String]]) {
    self.check = check
    self.apply = apply
  }
}

public enum UpdaterRuntime {
  public static func gitModePlan() -> UpdateCommandPlan {
    UpdateCommandPlan(
      check: ["git", "fetch", "origin"],
      apply: [
        ["git", "pull", "--ff-only"],
        ["npm", "install"]
      ]
    )
  }

  public static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int)? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "\t")
    guard parts.count >= 2 else { return nil }
    func parse(_ value: Substring, prefix: String) -> Int? {
      guard value.hasPrefix(prefix) else { return nil }
      return Int(value.dropFirst(prefix.count))
    }
    guard let ahead = parse(parts[0], prefix: "ahead "), let behind = parse(parts[1], prefix: "behind ") else {
      return nil
    }
    return (ahead, behind)
  }
}

public struct UpdateStatus: Codable, Equatable, Sendable {
  public var status: String
  public var message: String
  public var behind: Int

  public init(status: String, message: String, behind: Int = 0) {
    self.status = status
    self.message = message
    self.behind = behind
  }
}

public final class UpdaterService: @unchecked Sendable {
  public let projectRoot: URL

  public init(projectRoot: URL) {
    self.projectRoot = projectRoot
  }

  public func checkForUpdates() -> UpdateStatus {
    let fetch = run(["git", "fetch", "origin"])
    guard fetch.status == "ok" else { return fetch }
    let count = run(["git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
    guard count.status == "ok" else { return count }
    let parts = count.message.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    let behind = parts.count >= 2 ? parts[1] : 0
    return behind > 0
      ? UpdateStatus(status: "available", message: "\(behind) upstream commit(s) available", behind: behind)
      : UpdateStatus(status: "ok", message: "Already up to date", behind: 0)
  }

  public func applyUpdate() -> UpdateStatus {
    let pull = run(["git", "pull", "--ff-only"])
    guard pull.status == "ok" else { return pull }
    let packageLock = projectRoot.appendingPathComponent("package-lock.json")
    if FileManager.default.fileExists(atPath: packageLock.path) {
      let install = run(["npm", "install"])
      guard install.status == "ok" else { return install }
    }
    return UpdateStatus(status: "ok", message: "Update applied")
  }

  public func relaunch(executableURL: URL, arguments: [String] = []) -> UpdateStatus {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    do {
      try process.run()
      return UpdateStatus(status: "ok", message: "Relaunch started")
    } catch {
      return UpdateStatus(status: "error", message: error.localizedDescription)
    }
  }

  @discardableResult
  private func run(_ command: [String]) -> UpdateStatus {
    guard let executable = command.first else {
      return UpdateStatus(status: "error", message: "Empty command")
    }
    let process = Process()
    process.currentDirectoryURL = projectRoot
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return UpdateStatus(status: process.terminationStatus == 0 ? "ok" : "error", message: output.isEmpty ? executable : output)
    } catch {
      return UpdateStatus(status: "error", message: error.localizedDescription)
    }
  }
}
