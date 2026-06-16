import XCTest
@testable import ClawdNativeCore

final class CodexTerminalApprovalMonitorTests: XCTestCase {
  func testEmitsExplicitEscalatedExecCommandImmediately() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let file = try sessionFile(root: root, date: now)
    try writeLines([
      #"{"type":"session_meta","payload":{"cwd":"/repo"}}"#,
      #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1","arguments":"{\"cmd\":\"git push\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"needs network\"}"}}"#
    ], to: file)

    let box = ApprovalEventBox()
    let monitor = CodexTerminalApprovalMonitor(
      sessionRoot: root,
      approvalDelay: 2,
      activeWindow: 600,
      now: { now },
      onApproval: { box.events.append($0) }
    )

    let emitted = monitor.scanOnce()

    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(box.events.count, 1)
    XCTAssertEqual(emitted.first?.command, "git push")
    XCTAssertEqual(emitted.first?.cwd, "/repo")
    XCTAssertEqual(emitted.first?.sessionId, "codex:019ecfb0-0441-7b43-8306-1ad663dc8d37")
  }

  func testEmitsShellCommandAfterApprovalDelay() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date())
    let file = try sessionFile(root: root, date: clock.now)
    try writeLines([
      #"{"type":"session_meta","payload":{"cwd":"/repo"}}"#,
      #"{"type":"response_item","payload":{"type":"function_call","name":"shell_command","call_id":"call_2","arguments":"{\"command\":\"npm test\"}"}}"#
    ], to: file)

    let monitor = CodexTerminalApprovalMonitor(
      sessionRoot: root,
      approvalDelay: 2,
      activeWindow: 600,
      now: { clock.now },
      onApproval: { _ in }
    )

    XCTAssertTrue(monitor.scanOnce().isEmpty)
    clock.advance(3)

    let emitted = monitor.scanOnce()
    XCTAssertEqual(emitted.count, 1)
    XCTAssertEqual(emitted.first?.command, "npm test")
  }

  func testDoesNotEmitWhenCommandEndsBeforeDelay() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date())
    let file = try sessionFile(root: root, date: clock.now)
    try writeLines([
      #"{"type":"response_item","payload":{"type":"function_call","name":"shell_command","call_id":"call_3","arguments":"{\"command\":\"ls\"}"}}"#
    ], to: file)

    let monitor = CodexTerminalApprovalMonitor(
      sessionRoot: root,
      approvalDelay: 2,
      activeWindow: 600,
      now: { clock.now },
      onApproval: { _ in }
    )

    XCTAssertTrue(monitor.scanOnce().isEmpty)
    clock.advance(1)
    try appendLines([
      #"{"type":"event_msg","payload":{"type":"exec_command_end"}}"#
    ], to: file)
    XCTAssertTrue(monitor.scanOnce().isEmpty)
    clock.advance(3)
    XCTAssertTrue(monitor.scanOnce().isEmpty)
  }

  func testDoesNotEmitHistoricalExplicitCommandThatAlreadyEnded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let file = try sessionFile(root: root, date: now)
    try writeLines([
      #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_4","arguments":"{\"cmd\":\"git push\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"needs network\"}"}}"#,
      #"{"type":"event_msg","payload":{"type":"exec_command_end"}}"#
    ], to: file)

    let monitor = CodexTerminalApprovalMonitor(
      sessionRoot: root,
      approvalDelay: 2,
      activeWindow: 600,
      now: { now },
      onApproval: { _ in }
    )

    XCTAssertTrue(monitor.scanOnce().isEmpty)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-codex-terminal-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func sessionFile(root: URL, date: Date) throws -> URL {
    let calendar = Calendar(identifier: .gregorian)
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    let dir = root
      .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("rollout-2026-06-16T17-07-59-019ecfb0-0441-7b43-8306-1ad663dc8d37.jsonl")
  }

  private func writeLines(_ lines: [String], to file: URL) throws {
    try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
  }

  private func appendLines(_ lines: [String], to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
  }
}

private final class ApprovalEventBox: @unchecked Sendable {
  var events: [CodexTerminalApprovalEvent] = []
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(_ seconds: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(seconds)
    lock.unlock()
  }
}
