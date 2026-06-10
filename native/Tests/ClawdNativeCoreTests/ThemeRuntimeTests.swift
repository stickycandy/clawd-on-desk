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

  func testVariantAndOverridesAffectResolvedAsset() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-theme-\(UUID().uuidString)", isDirectory: true)
    let themeDir = root.appendingPathComponent("themes/test/assets", isDirectory: true)
    try FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
    for file in ["idle.svg", "alt.svg", "override.svg", "work.svg", "think.svg"] {
      FileManager.default.createFile(atPath: themeDir.appendingPathComponent(file).path, contents: Data("<svg></svg>".utf8))
    }
    let manifest = """
    {
      "name": "test",
      "states": {
        "idle": ["idle.svg"],
        "working": ["work.svg"],
        "thinking": ["think.svg"]
      },
      "variants": {
        "alt": {
          "states": {
            "idle": ["alt.svg"]
          }
        }
      }
    }
    """
    try manifest.write(to: root.appendingPathComponent("themes/test/theme.json"), atomically: true, encoding: .utf8)
    let runtime = ThemeRuntime(projectRoot: root)
    let snapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
    XCTAssertEqual(runtime.resolveAsset(themeId: "test", snapshot: snapshot, variantId: "alt")?.fileName, "alt.svg")
    let overrides: JSONValue = .object([
      "states": .object([
        "idle": .object(["file": .string("override.svg")])
      ])
    ])
    XCTAssertEqual(runtime.resolveAsset(themeId: "test", snapshot: snapshot, variantId: "alt", overrides: overrides)?.fileName, "override.svg")
    try? FileManager.default.removeItem(at: root)
  }

  private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
