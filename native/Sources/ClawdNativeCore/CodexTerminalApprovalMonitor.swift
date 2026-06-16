import Foundation

public struct CodexTerminalApprovalEvent: Equatable, Sendable {
  public var sessionId: String
  public var command: String
  public var cwd: String?
  public var sourceFile: String

  public init(sessionId: String, command: String, cwd: String? = nil, sourceFile: String) {
    self.sessionId = sessionId
    self.command = command
    self.cwd = cwd
    self.sourceFile = sourceFile
  }
}

public final class CodexTerminalApprovalMonitor: @unchecked Sendable {
  public typealias ApprovalHandler = @Sendable (CodexTerminalApprovalEvent) -> Void

  private struct PendingApproval {
    var key: String
    var sessionId: String
    var command: String
    var cwd: String?
    var sourceFile: String
    var deadline: Date
  }

  private struct FileState {
    var offset: UInt64
    var cwd: String?
    var pending: PendingApproval?
  }

  private let sessionRoot: URL
  private let pollInterval: TimeInterval
  private let approvalDelay: TimeInterval
  private let activeWindow: TimeInterval
  private let maxInitialReadBytes: UInt64
  private let now: @Sendable () -> Date
  private let onApproval: ApprovalHandler
  private let fileManager: FileManager
  private let queue = DispatchQueue(label: "clawd.native.codex-terminal-approval")

  private var timer: DispatchSourceTimer?
  private var files: [String: FileState] = [:]
  private var emittedKeys = Set<String>()

  public init(
    sessionRoot: URL = CodexTerminalApprovalMonitor.defaultSessionRoot(),
    pollInterval: TimeInterval = 1.5,
    approvalDelay: TimeInterval = 2,
    activeWindow: TimeInterval = 5 * 60,
    maxInitialReadBytes: UInt64 = 262_144,
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init,
    onApproval: @escaping ApprovalHandler
  ) {
    self.sessionRoot = sessionRoot
    self.pollInterval = pollInterval
    self.approvalDelay = approvalDelay
    self.activeWindow = activeWindow
    self.maxInitialReadBytes = maxInitialReadBytes
    self.fileManager = fileManager
    self.now = now
    self.onApproval = onApproval
  }

  public static func defaultSessionRoot(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let root = codexHome?.isEmpty == false
      ? URL(fileURLWithPath: codexHome!)
      : homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    return root.appendingPathComponent("sessions", isDirectory: true)
  }

  public func start() {
    queue.async {
      guard self.timer == nil else { return }
      _ = self.pollLocked(deliver: true)
      let source = DispatchSource.makeTimerSource(queue: self.queue)
      source.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
      source.setEventHandler { [weak self] in
        _ = self?.pollLocked(deliver: true)
      }
      self.timer = source
      source.resume()
    }
  }

  public func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
      files.removeAll()
      emittedKeys.removeAll()
    }
  }

  @discardableResult
  public func scanOnce(deliver: Bool = true) -> [CodexTerminalApprovalEvent] {
    queue.sync {
      pollLocked(deliver: deliver)
    }
  }

  private func pollLocked(deliver: Bool) -> [CodexTerminalApprovalEvent] {
    let timestamp = now()
    var emitted: [CodexTerminalApprovalEvent] = []
    let active = activeSessionFiles(now: timestamp)
    let activePaths = Set(active.map(\.path))
    for file in active {
      emitted.append(contentsOf: pollFileLocked(file, now: timestamp))
    }
    emitted.append(contentsOf: emitReadyPendingLocked(now: timestamp))
    files = files.filter { activePaths.contains($0.key) }
    if deliver {
      emitted.forEach(onApproval)
    }
    return emitted
  }

  private func activeSessionFiles(now timestamp: Date) -> [URL] {
    let minDate = timestamp.addingTimeInterval(-activeWindow)
    var candidates: [(url: URL, modifiedAt: Date)] = []
    for dir in recentDayDirectories(now: timestamp) {
      guard let entries = try? fileManager.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { continue }
      for entry in entries where entry.pathExtension == "jsonl" {
        let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { continue }
        let modifiedAt = values?.contentModificationDate ?? Date.distantPast
        if modifiedAt >= minDate || files[entry.path] != nil {
          candidates.append((entry, modifiedAt))
        }
      }
    }
    return candidates
      .sorted { $0.modifiedAt > $1.modifiedAt }
      .prefix(50)
      .map(\.url)
  }

  private func recentDayDirectories(now timestamp: Date) -> [URL] {
    let calendar = Calendar(identifier: .gregorian)
    return (0...1).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: timestamp) else { return nil }
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
      return sessionRoot
        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }
  }

  private func pollFileLocked(_ file: URL, now timestamp: Date) -> [CodexTerminalApprovalEvent] {
    let path = file.path
    let size = fileSize(file)
    let knownFile = files[path] != nil
    var state = files[path] ?? FileState(
      offset: size > maxInitialReadBytes ? size - maxInitialReadBytes : 0,
      cwd: nil,
      pending: nil
    )
    if size < state.offset {
      state.offset = 0
      state.pending = nil
    }
    guard size > state.offset else {
      files[path] = state
      return []
    }

    let startOffset = state.offset
    guard let data = readFile(file, from: startOffset) else {
      files[path] = state
      return []
    }
    state.offset = size
    var text = String(decoding: data, as: UTF8.self)
    if startOffset > 0 && !knownFile {
      guard let newline = text.firstIndex(where: { $0.isNewline }) else {
        files[path] = state
        return []
      }
      text = String(text[text.index(after: newline)...])
    }

    let sessionId = Self.sessionId(from: file) ?? "codex:default"
    for rawLine in text.split(whereSeparator: \.isNewline) {
      guard case .object(let record) = decodeJSON(String(rawLine)) else { continue }
      handleRecord(
        record,
        state: &state,
        sessionId: sessionId,
        sourceFile: path,
        now: timestamp
      )
    }
    files[path] = state
    return []
  }

  private func handleRecord(
    _ record: [String: JSONValue],
    state: inout FileState,
    sessionId: String,
    sourceFile: String,
    now timestamp: Date
  ) {
    let type = record.string("type")
    let payload = record.object("payload") ?? [:]
    if type == "session_meta" || type == "turn_context" {
      if let cwd = payload.string("cwd")?.trimmedNonEmpty {
        state.cwd = cwd
      }
      return
    }

    let payloadType = payload.string("type")
    if isApprovalClear(type: type, payloadType: payloadType, payload: payload) {
      state.pending = nil
      return
    }

    guard type == "response_item",
          payloadType == "function_call",
          let detail = approvalDetail(payload)
    else { return }

    let key = [
      sessionId,
      payload.string("call_id") ?? payload.string("id") ?? "",
      detail.command
    ].joined(separator: "|")
    let cwd = detail.cwd ?? state.cwd
    if detail.explicit {
      state.pending = PendingApproval(
        key: key,
        sessionId: sessionId,
        command: detail.command,
        cwd: cwd,
        sourceFile: sourceFile,
        deadline: timestamp
      )
    } else {
      state.pending = PendingApproval(
        key: key,
        sessionId: sessionId,
        command: detail.command,
        cwd: cwd,
        sourceFile: sourceFile,
        deadline: timestamp.addingTimeInterval(approvalDelay)
      )
    }
  }

  private func emitReadyPendingLocked(now timestamp: Date) -> [CodexTerminalApprovalEvent] {
    var emitted: [CodexTerminalApprovalEvent] = []
    for (path, var state) in files {
      guard let pending = state.pending, pending.deadline <= timestamp else { continue }
      state.pending = nil
      files[path] = state
      emitIfNeeded(
        key: pending.key,
        sessionId: pending.sessionId,
        command: pending.command,
        cwd: pending.cwd,
        sourceFile: pending.sourceFile,
        emitted: &emitted
      )
    }
    return emitted
  }

  private func emitIfNeeded(
    key: String,
    sessionId: String,
    command: String,
    cwd: String?,
    sourceFile: String,
    emitted: inout [CodexTerminalApprovalEvent]
  ) {
    guard !emittedKeys.contains(key) else { return }
    emittedKeys.insert(key)
    emitted.append(CodexTerminalApprovalEvent(
      sessionId: sessionId,
      command: command,
      cwd: cwd,
      sourceFile: sourceFile
    ))
  }

  private func approvalDetail(_ payload: [String: JSONValue]) -> (command: String, cwd: String?, explicit: Bool)? {
    let name = payload.string("name") ?? ""
    guard name == "shell_command" || name == "exec_command" else { return nil }
    guard let args = commandArguments(payload),
          let command = (args.string("command") ?? args.string("cmd"))?.trimmedNonEmpty
    else { return nil }
    let explicit = args.string("sandbox_permissions") == "require_escalated"
      || args.string("justification")?.trimmedNonEmpty != nil
    return (command, args.string("workdir") ?? args.string("cwd"), explicit)
  }

  private func commandArguments(_ payload: [String: JSONValue]) -> [String: JSONValue]? {
    if let args = payload.object("arguments") { return args }
    guard let text = payload.string("arguments")?.trimmedNonEmpty,
          case .object(let args) = decodeJSON(text)
    else { return nil }
    return args
  }

  private func isApprovalClear(type: String?, payloadType: String?, payload: [String: JSONValue]) -> Bool {
    if type == "event_msg", payloadType == "exec_command_end" { return true }
    if type == "response_item", payloadType == "function_call_output" { return true }
    if payloadType == "guardian_assessment" {
      let status = payload.string("status")
      return status == "in_progress" || status == "approved"
    }
    return false
  }

  private func fileSize(_ url: URL) -> UInt64 {
    let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    return size ?? 0
  }

  private func readFile(_ url: URL, from offset: UInt64) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: offset)
      return try handle.readToEnd() ?? Data()
    } catch {
      return nil
    }
  }

  private func decodeJSON(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func sessionId(from file: URL) -> String? {
    let base = file.deletingPathExtension().lastPathComponent
    let parts = base.split(separator: "-")
    guard parts.count >= 5 else { return nil }
    let suffix = parts.suffix(5).joined(separator: "-")
    let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    guard suffix.range(of: pattern, options: .regularExpression) != nil else { return nil }
    return "codex:\(suffix)"
  }
}

private extension Dictionary where Key == String, Value == JSONValue {
  func string(_ key: String) -> String? {
    guard case .string(let value) = self[key] else { return nil }
    return value
  }

  func object(_ key: String) -> [String: JSONValue]? {
    guard case .object(let value) = self[key] else { return nil }
    return value
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
