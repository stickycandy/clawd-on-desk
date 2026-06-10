import XCTest
@testable import ClawdNativeCore

final class SessionAliasTests: XCTestCase {
  func testKiroDefaultSessionIsScopedByCwd() {
    let key = SessionAliasKeys.key(host: "local", agentId: "kiro-cli", sessionId: "default", cwd: "/tmp/project")
    XCTAssertEqual(key, "local|kiro-cli|default|cwd:/tmp/project")
  }

  func testAliasPruneKeepsActiveKeys() {
    let now = Date()
    let aliases = [
      "old": SessionAlias(title: "Old", updatedAt: now.addingTimeInterval(-sessionAliasTTL - 10)),
      "active": SessionAlias(title: "Active", updatedAt: now.addingTimeInterval(-sessionAliasTTL - 10))
    ]
    let pruned = SessionAliasKeys.pruneExpired(aliases, activeKeys: ["active"], now: now)
    XCTAssertNil(pruned["old"])
    XCTAssertNotNil(pruned["active"])
  }
}
