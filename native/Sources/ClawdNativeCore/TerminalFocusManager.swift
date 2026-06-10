import Foundation

public struct TerminalFocusResult: Equatable, Sendable {
  public var status: String
  public var message: String

  public init(status: String, message: String) {
    self.status = status
    self.message = message
  }
}

public final class TerminalFocusManager: @unchecked Sendable {
  public init() {}

  public func focus(session: AgentSession) -> TerminalFocusResult {
    guard let pid = session.metadata.sourcePid ?? session.metadata.agentPid else {
      return TerminalFocusResult(status: "skip", message: "Session has no source PID")
    }
    return focus(pid: pid)
  }

  public func focus(pid: Int) -> TerminalFocusResult {
    guard pid > 0 else {
      return TerminalFocusResult(status: "error", message: "Invalid PID")
    }
    #if os(macOS)
    return runAppleScript(Self.appleScript(pid: pid))
    #else
    return TerminalFocusResult(status: "skip", message: "Terminal focus is implemented for macOS in the native app")
    #endif
  }

  public static func appleScript(pid: Int) -> String {
    """
    tell application "System Events"
      set targetProcesses to every process whose unix id is \(pid)
      if (count of targetProcesses) > 0 then
        set frontmost of item 1 of targetProcesses to true
        return "focused"
      end if
      return "missing"
    end tell
    """
  }

  #if os(macOS)
  private func runAppleScript(_ script: String) -> TerminalFocusResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if process.terminationStatus == 0 {
        return TerminalFocusResult(status: output == "focused" ? "ok" : "skip", message: output)
      }
      return TerminalFocusResult(status: "error", message: output)
    } catch {
      return TerminalFocusResult(status: "error", message: error.localizedDescription)
    }
  }
  #endif
}
