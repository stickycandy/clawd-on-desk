import XCTest
@testable import ClawdNativeCore

final class NativeProcessResolverTests: XCTestCase {
  func testParsePSOutputAndResolveAgentPidChain() {
    let records = NativeProcessResolver.parsePSOutput("""
        10     1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        20    10 /bin/zsh
        30    20 /opt/homebrew/bin/codex
        40    30 /tmp/ClawdNativeHook
    """)
    XCTAssertEqual(records.count, 4)

    let fields = NativeProcessResolver.resolve(records: records, agentNames: ["codex"], currentPid: 40)
    XCTAssertEqual(fields.agentPid, 30)
    XCTAssertEqual(fields.sourcePid, 30)
    XCTAssertEqual(fields.pidChain, [40, 30, 20, 10])
    XCTAssertEqual(fields.editor, "Terminal")
  }

  func testResolverFallsBackToParentWhenAgentMissing() {
    let records = [
      NativeProcessRecord(pid: 20, ppid: 10, command: "/bin/zsh"),
      NativeProcessRecord(pid: 40, ppid: 20, command: "/tmp/ClawdNativeHook")
    ]
    let fields = NativeProcessResolver.resolve(records: records, agentNames: ["codex"], currentPid: 40)
    XCTAssertNil(fields.agentPid)
    XCTAssertEqual(fields.sourcePid, 20)
    XCTAssertEqual(fields.pidChain, [40, 20])
  }
}
