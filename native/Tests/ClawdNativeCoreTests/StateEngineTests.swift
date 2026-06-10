import XCTest
@testable import ClawdNativeCore

final class StateEngineTests: XCTestCase {
  func testDominantStateIgnoresHeadlessSessions() {
    let engine = StateEngine()
    engine.updateSession("headless", state: .error, event: "StopFailure", metadata: SessionMetadata(agentId: "codex", headless: true))
    XCTAssertEqual(engine.current(), .idle)

    engine.updateSession("visible", state: .working, event: "PreToolUse", metadata: SessionMetadata(agentId: "claude-code"))
    XCTAssertEqual(engine.current(), .working)

    engine.updateSession("visible-2", state: .notification, event: "PermissionRequest", metadata: SessionMetadata(agentId: "qwen-code"))
    XCTAssertEqual(engine.current(), .notification)
  }

  func testDndForcesSleepingAndBlocksUpdates() {
    let engine = StateEngine()
    engine.updateSession("s1", state: .working, event: "PreToolUse")
    XCTAssertEqual(engine.current(), .working)

    engine.enableDoNotDisturb()
    XCTAssertTrue(engine.shouldDropForDnd())
    XCTAssertEqual(engine.current(), .sleeping)

    engine.updateSession("s1", state: .notification, event: "PermissionRequest")
    XCTAssertEqual(engine.current(), .sleeping)
  }

  func testStaleCleanupDropsOldWorkingSession() {
    let engine = StateEngine()
    engine.updateSession("s1", state: .working, event: "PreToolUse")
    engine.cleanStaleSessions(now: Date().addingTimeInterval(400), workingStaleMs: 300_000)
    XCTAssertEqual(engine.snapshot().sessions.count, 0)
    XCTAssertEqual(engine.current(), .idle)
  }
}
