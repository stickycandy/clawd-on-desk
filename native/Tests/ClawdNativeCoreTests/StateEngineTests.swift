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

  func testTransientPermissionEventPreservesSessionState() {
    let engine = StateEngine()
    engine.updateSession("s1", state: .working, event: "PreToolUse", metadata: SessionMetadata(agentId: "codex"))
    engine.updateSession(
      "s1",
      state: .notification,
      event: "PermissionRequest",
      metadata: SessionMetadata(agentId: "codex", transientPermissionEvent: true)
    )
    let snapshot = engine.snapshot()
    XCTAssertEqual(snapshot.sessions.first?.state, .working)
    XCTAssertEqual(engine.current(), .notification)
  }

  func testTransientPermissionEventWithoutSessionStoresIdle() {
    let engine = StateEngine()
    engine.updateSession(
      "new",
      state: .notification,
      event: "PermissionRequest",
      metadata: SessionMetadata(agentId: "codex", transientPermissionEvent: true)
    )
    let snapshot = engine.snapshot()
    XCTAssertEqual(snapshot.sessions.first?.state, .idle)
    XCTAssertEqual(snapshot.sessions.first?.event, "PermissionRequest")
    XCTAssertEqual(engine.current(), .notification)
  }

  func testOneShotSessionsStoreIdleButKeepEventBadges() {
    let engine = StateEngine()
    engine.updateSession("input", state: .notification, event: "Notification", metadata: SessionMetadata(agentId: "qoder"))
    var snapshot = engine.snapshot()
    XCTAssertEqual(snapshot.sessions.first?.state, .idle)
    XCTAssertEqual(snapshot.sessions.first?.badge, "Input")
    XCTAssertEqual(engine.current(), .notification)

    let doneEngine = StateEngine()
    doneEngine.updateSession("done", state: .attention, event: "Stop", metadata: SessionMetadata(agentId: "claude-code"))
    snapshot = doneEngine.snapshot()
    let done = snapshot.sessions.first { $0.id == "done" }
    XCTAssertEqual(done?.state, .idle)
    XCTAssertEqual(done?.badge, "Done")
    XCTAssertEqual(doneEngine.current(), .attention)
  }

  func testSuppressedOneShotVisualKeepsBookkeepingWithoutChangingCurrentState() {
    let engine = StateEngine()
    engine.updateSession(
      "input",
      state: .notification,
      event: "Notification",
      metadata: SessionMetadata(agentId: "qoder"),
      suppressOneShotVisual: true
    )

    let snapshot = engine.snapshot()
    let session = snapshot.sessions.first { $0.id == "input" }
    XCTAssertEqual(snapshot.currentState, .idle)
    XCTAssertEqual(session?.state, .idle)
    XCTAssertEqual(session?.event, "Notification")
    XCTAssertEqual(session?.badge, "Input")
    XCTAssertEqual(engine.current(), .idle)
  }

  func testMouseSleepSequenceAdvancesAndWakes() {
    let engine = StateEngine(timings: StateTiming(
      autoReturnMs: [:],
      yawnDurationMs: 5,
      wakeDurationMs: 5,
      collapseDurationMs: 5
    ))
    let dozing = expectation(description: "yawning advances to dozing")
    engine.beginMouseSleepSequence()
    XCTAssertEqual(engine.current(), .yawning)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
      XCTAssertEqual(engine.current(), .dozing)
      dozing.fulfill()
    }
    wait(for: [dozing], timeout: 1)

    let sleeping = expectation(description: "collapsing advances to sleeping")
    engine.deepenSleepIfDozing()
    XCTAssertEqual(engine.current(), .collapsing)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
      XCTAssertEqual(engine.current(), .sleeping)
      sleeping.fulfill()
    }
    wait(for: [sleeping], timeout: 1)

    let awake = expectation(description: "waking returns to idle")
    engine.wakeFromSleepSequence()
    XCTAssertEqual(engine.current(), .waking)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
      XCTAssertEqual(engine.current(), .idle)
      awake.fulfill()
    }
    wait(for: [awake], timeout: 1)
  }

  func testDirectSleepModeSkipsYawn() {
    let engine = StateEngine(timings: StateTiming(autoReturnMs: [:], sleepMode: .direct))
    engine.beginMouseSleepSequence()
    XCTAssertEqual(engine.current(), .sleeping)
  }
}
