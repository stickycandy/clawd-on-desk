import XCTest
@testable import ClawdNativeCore

final class ThemeRuntimeTests: XCTestCase {
  func testResolvesClawdAssetsFromSharedSvgDirectory() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let snapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
    let asset = try XCTUnwrap(runtime.resolveAsset(themeId: "clawd", snapshot: snapshot))
    XCTAssertEqual(asset.fileName, "clawd-idle-follow.svg")
    XCTAssertTrue(asset.url.path.hasSuffix("/assets/svg/clawd-idle-follow.svg"))
  }

  func testResolvesCalicoAssetsFromThemeAssetsDirectory() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let snapshot = StateSnapshot(currentState: .working, sessions: [
      AgentSession(id: "a", state: .working, event: nil, updatedAt: Date(), startedAt: Date(), metadata: SessionMetadata(agentId: "codex")),
      AgentSession(id: "b", state: .working, event: nil, updatedAt: Date(), startedAt: Date(), metadata: SessionMetadata(agentId: "claude-code"))
    ], updatedAt: Date())
    let asset = try XCTUnwrap(runtime.resolveAsset(themeId: "calico", snapshot: snapshot))
    XCTAssertEqual(asset.fileName, "calico-working-juggling.apng")
    XCTAssertTrue(asset.url.path.hasSuffix("/themes/calico/assets/calico-working-juggling.apng"))
  }

  func testDisplayHintMapsAcrossThemes() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let snapshot = StateSnapshot(currentState: .working, sessions: [
      AgentSession(
        id: "a",
        state: .working,
        event: nil,
        updatedAt: Date(),
        startedAt: Date(),
        metadata: SessionMetadata(agentId: "codex", displayHint: "clawd-working-building.svg")
      )
    ], updatedAt: Date())
    let asset = try XCTUnwrap(runtime.resolveAsset(themeId: "cloudling", snapshot: snapshot))
    XCTAssertEqual(asset.fileName, "cloudling-building.svg")
  }

  func testResolvesThemeHitBoxForAsset() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let loaded = try runtime.loadTheme(id: "clawd")
    let snapshot = StateSnapshot(currentState: .notification, sessions: [], updatedAt: Date())
    let asset = try XCTUnwrap(loaded.resolveAsset(snapshot: snapshot))
    let hitBox = try XCTUnwrap(loaded.hitBox(for: asset))
    XCTAssertGreaterThan(hitBox.w, 0)
    XCTAssertGreaterThan(hitBox.h, 0)
  }

  private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
