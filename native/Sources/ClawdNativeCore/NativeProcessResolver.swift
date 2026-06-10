import Foundation

public struct NativeProcessRecord: Equatable, Sendable {
  public var pid: Int
  public var ppid: Int
  public var command: String

  public init(pid: Int, ppid: Int, command: String) {
    self.pid = pid
    self.ppid = ppid
    self.command = command
  }

  public var executableName: String {
    URL(fileURLWithPath: command).lastPathComponent
  }
}

public struct NativeHookProcessFields: Equatable, Sendable {
  public var sourcePid: Int?
  public var agentPid: Int?
  public var pidChain: [Int]
  public var editor: String?

  public init(sourcePid: Int? = nil, agentPid: Int? = nil, pidChain: [Int] = [], editor: String? = nil) {
    self.sourcePid = sourcePid
    self.agentPid = agentPid
    self.pidChain = pidChain
    self.editor = editor
  }
}

public enum NativeProcessResolver {
  public static func resolve(agentNames: Set<String>, currentPid: Int = Int(ProcessInfo.processInfo.processIdentifier)) -> NativeHookProcessFields {
    resolve(records: readProcessTable(), agentNames: agentNames, currentPid: currentPid)
  }

  public static func resolve(records: [NativeProcessRecord], agentNames: Set<String>, currentPid: Int) -> NativeHookProcessFields {
    let byPid = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
    var chain: [Int] = []
    var cursor = currentPid
    var seen = Set<Int>()
    while cursor > 0, !seen.contains(cursor), let record = byPid[cursor] {
      seen.insert(cursor)
      chain.append(cursor)
      cursor = record.ppid
      if chain.count >= 32 { break }
    }

    let normalizedAgentNames = Set(agentNames.map { $0.lowercased() })
    let agent = chain
      .compactMap { byPid[$0] }
      .first { record in
        let exe = record.executableName.lowercased()
        let command = record.command.lowercased()
        return normalizedAgentNames.contains(exe) || normalizedAgentNames.contains(command)
      }
    let terminal = chain
      .compactMap { byPid[$0] }
      .first { record in
        let exe = record.executableName.lowercased()
        return Self.terminalProcessNames.contains(exe)
      }
    let source = agent?.pid ?? chain.dropFirst().first ?? currentPid
    return NativeHookProcessFields(
      sourcePid: source,
      agentPid: agent?.pid,
      pidChain: chain,
      editor: terminal?.executableName
    )
  }

  public static func parsePSOutput(_ output: String) -> [NativeProcessRecord] {
    output
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> NativeProcessRecord? in
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1])
        else { return nil }
        return NativeProcessRecord(pid: pid, ppid: ppid, command: String(parts[2]))
      }
  }

  private static func readProcessTable() -> [NativeProcessRecord] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return [] }
      return parsePSOutput(String(decoding: data, as: UTF8.self))
    } catch {
      return []
    }
  }

  private static let terminalProcessNames: Set<String> = [
    "terminal",
    "iterm2",
    "ghostty",
    "wezterm",
    "alacritty",
    "kitty",
    "cursor",
    "code"
  ]
}
