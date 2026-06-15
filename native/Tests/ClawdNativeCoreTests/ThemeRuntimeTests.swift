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

  func testResolvesDefaultBuiltInSounds() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let sound = try XCTUnwrap(runtime.resolveSound(themeId: "clawd", name: "complete"))
    XCTAssertEqual(sound.fileName, "complete.mp3")
    XCTAssertTrue(sound.url.path.hasSuffix("/assets/sounds/complete.mp3"))
  }

  func testResolvesExternalThemeSoundsWithFallbackAndDisabledEntries() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-sounds-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let bundledSounds = root.appendingPathComponent("assets/sounds", isDirectory: true)
    let userThemesRoot = root.appendingPathComponent("user-themes", isDirectory: true)
    let themeDir = userThemesRoot.appendingPathComponent("custom", isDirectory: true)
    let themeSounds = themeDir.appendingPathComponent("sounds", isDirectory: true)
    try FileManager.default.createDirectory(at: bundledSounds, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: themeSounds, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: bundledSounds.appendingPathComponent("complete.mp3").path, contents: Data())
    FileManager.default.createFile(atPath: themeSounds.appendingPathComponent("custom-confirm.mp3").path, contents: Data())

    let manifest = """
    {
      "name": "custom",
      "states": {
        "idle": ["idle.svg"],
        "working": ["work.svg"],
        "thinking": ["think.svg"]
      },
      "sounds": {
        "complete": "complete.mp3",
        "confirm": "custom-confirm.mp3",
        "disabled": null,
        "unsafe": "../custom-confirm.mp3"
      }
    }
    """
    try manifest.write(to: themeDir.appendingPathComponent("theme.json"), atomically: true, encoding: .utf8)

    let runtime = ThemeRuntime(projectRoot: root, userThemesRoot: userThemesRoot)
    let complete = try XCTUnwrap(runtime.resolveSound(themeId: "custom", name: "complete"))
    XCTAssertTrue(complete.url.path.hasSuffix("/assets/sounds/complete.mp3"))

    let confirm = try XCTUnwrap(runtime.resolveSound(themeId: "custom", name: "confirm"))
    XCTAssertEqual(confirm.fileName, "custom-confirm.mp3")
    XCTAssertTrue(confirm.url.path.hasSuffix("/user-themes/custom/sounds/custom-confirm.mp3"))

    XCTAssertNil(runtime.resolveSound(themeId: "custom", name: "disabled"))

    let unsafe = try XCTUnwrap(runtime.resolveSound(themeId: "custom", name: "unsafe"))
    XCTAssertEqual(unsafe.fileName, "custom-confirm.mp3")
  }

  func testParsesLayoutFileViewBoxesAndMiniTimingMetadata() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())

    let clawd = try runtime.loadTheme(id: "clawd")
    XCTAssertEqual(clawd.manifest.layout?.contentBox?.width, 23)
    XCTAssertEqual(clawd.manifest.layout?.baselineY, 17)
    XCTAssertEqual(clawd.manifest.miniMode?.glyphFlips?["pixel-z"], 4)
    let clawdTiming = clawd.manifest.timing()
    XCTAssertEqual(clawdTiming.autoReturnMs[.miniAlert], 4_000)
    XCTAssertEqual(clawdTiming.minDisplayMs[.attention], 4_000)

    let cloudling = try runtime.loadTheme(id: "cloudling")
    XCTAssertEqual(cloudling.manifest.fileViewBoxes?["cloudling-mini-crabwalk.svg"]?.width, 88)
    XCTAssertEqual(cloudling.manifest.miniMode?.viewBox?.width, 48)
    XCTAssertEqual(cloudling.manifest.miniMode?.offsetRatio, 0.486)
    XCTAssertEqual(cloudling.manifest.timing().autoReturnMs[.miniPeek], 1_500)
  }

  func testMiniWorkingFallbackStaysInMiniAssetsWhenOptionalAssetIsMissing() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let snapshot = StateSnapshot(currentState: .miniWorking, sessions: [], updatedAt: Date())

    let calico = try XCTUnwrap(runtime.resolveAsset(themeId: "calico", snapshot: snapshot))
    XCTAssertEqual(calico.fileName, "calico-mini-idle.apng")

    let clawd = try XCTUnwrap(runtime.resolveAsset(themeId: "clawd", snapshot: snapshot))
    XCTAssertEqual(clawd.fileName, "clawd-mini-typing.svg")
  }

  func testParsesRendererMetadataUsedByNativeWebDocument() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())

    let clawd = try runtime.loadTheme(id: "clawd")
    XCTAssertEqual(clawd.manifest.eyeTracking?.bodyScale, 0.33)
    XCTAssertEqual(clawd.manifest.eyeTracking?.shadowStretch, 0.15)
    XCTAssertEqual(clawd.manifest.eyeTracking?.shadowShift, 0.3)

    let calico = try runtime.loadTheme(id: "calico")
    let layers = try XCTUnwrap(calico.manifest.eyeTracking?.trackingLayers)
    XCTAssertEqual(layers["eyes"]?.ids?.first, "eye-sockets")
    XCTAssertEqual(layers["head"]?.classes?.first, "ear-anim")

    let cloudling = try runtime.loadTheme(id: "cloudling")
    XCTAssertTrue(cloudling.manifest.trustedRuntime?.scriptedSvgFiles?.contains("cloudling-idle.svg") == true)
  }

  func testWebDocumentInlinesEyeTrackedSVGAndUsesThemeEyeIds() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let asset = try XCTUnwrap(runtime.resolveAsset(
      themeId: "clawd",
      snapshot: StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
    ))

    let document = ThemeWebDocumentBuilder.document(for: asset, cacheBust: "fixed")
    XCTAssertEqual(document.channel, .inlineSVG)
    XCTAssertTrue(document.usesDOMEyeTracking)
    XCTAssertFalse(document.usesLayeredTracking)
    XCTAssertTrue(document.html.contains(#"data-channel="inline-svg""#))
    XCTAssertTrue(document.html.contains(#""eyes":"eyes-js""#))
    XCTAssertTrue(document.html.contains("window.clawdSetEye"))
    XCTAssertFalse(document.html.contains("<object"))
  }

  func testWebDocumentInlinesPlaybackOnlySVGWithoutImageChannel() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let asset = try XCTUnwrap(runtime.resolveAsset(
      themeId: "clawd",
      snapshot: StateSnapshot(currentState: .working, sessions: [], updatedAt: Date())
    ))

    let document = ThemeWebDocumentBuilder.document(for: asset, cacheBust: "fixed")
    XCTAssertEqual(document.channel, .inlineSVG)
    XCTAssertFalse(document.usesDOMEyeTracking)
    XCTAssertFalse(document.usesLayeredTracking)
    XCTAssertTrue(document.html.contains(#"data-channel="inline-svg""#))
    XCTAssertTrue(document.html.contains(#"id="keyboard""#))
    XCTAssertTrue(document.html.contains("body-bounce"))
    XCTAssertTrue(document.html.contains("@keyframes"))
    XCTAssertFalse(document.html.contains("<img"))
    XCTAssertFalse(document.html.contains("_t=fixed"))
    XCTAssertFalse(document.html.contains("data-clawd-native-scripted-svg"))
    XCTAssertFalse(document.html.contains("__clawdNativeSetSVGInnerHTML"))
  }

  func testWebDocumentUsesCacheBustedImageChannelForAPNG() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let asset = try XCTUnwrap(runtime.resolveAsset(
      themeId: "calico",
      snapshot: StateSnapshot(currentState: .working, sessions: [
        AgentSession(id: "a", state: .working, event: nil, updatedAt: Date(), startedAt: Date(), metadata: SessionMetadata(agentId: "codex")),
        AgentSession(id: "b", state: .working, event: nil, updatedAt: Date(), startedAt: Date(), metadata: SessionMetadata(agentId: "claude-code"))
      ], updatedAt: Date())
    ))

    let document = ThemeWebDocumentBuilder.document(for: asset, cacheBust: "fixed")
    XCTAssertEqual(document.channel, .image)
    XCTAssertFalse(document.usesDOMEyeTracking)
    XCTAssertFalse(document.usesLayeredTracking)
    XCTAssertTrue(document.html.contains("<img"))
    XCTAssertTrue(document.html.contains("_t=fixed"))
    XCTAssertTrue(document.html.contains("img.naturalWidth > 0"))
    XCTAssertFalse(document.html.contains(#"data-channel="inline-svg""#))
  }

  func testWebDocumentInlinesTrustedCloudlingScriptedSVGWithExtractedScripts() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let asset = try XCTUnwrap(runtime.resolveAsset(
      themeId: "cloudling",
      fileName: "cloudling-carrying.svg",
      state: .carrying
    ))

    let document = ThemeWebDocumentBuilder.document(for: asset, cacheBust: "fixed")
    XCTAssertEqual(document.channel, .inlineSVG)
    XCTAssertFalse(document.usesDOMEyeTracking)
    XCTAssertFalse(document.usesLayeredTracking)
    XCTAssertTrue(document.html.contains(#"data-channel="inline-svg""#))
    XCTAssertTrue(document.html.contains(#"data-clawd-native-scripted-svg="true""#))
    XCTAssertTrue(document.html.contains("__clawdNativeSetSVGInnerHTML"))
    XCTAssertTrue(document.html.contains("window.__clawdNativeSetSVGInnerHTML(stage, `"))
    XCTAssertTrue(document.html.contains("image/svg+xml"))
    XCTAssertTrue(document.html.contains("window.__clawdNativeReady = false"))
    XCTAssertTrue(document.html.contains("waitForInlineSVG"))
    XCTAssertTrue(document.html.contains("markReadyAfterPaint"))
    XCTAssertTrue(document.html.contains("renderFrame(0);"))
    let fallbackSVG = try XCTUnwrap(document.fallbackSVG)
    XCTAssertTrue(fallbackSVG.contains(#"<svg id="stage""#))
    XCTAssertTrue(fallbackSVG.contains("cloudling-body"))
    XCTAssertTrue(fallbackSVG.contains("food-cloud"))
    XCTAssertFalse(fallbackSVG.contains("<script"))
    XCTAssertFalse(document.html.contains("<object"))
    XCTAssertFalse(document.html.contains(#"<script type="application/ecmascript">"#))
  }

  func testWebDocumentIncludesLayeredTrackingConfigForCalicoIdle() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let asset = try XCTUnwrap(runtime.resolveAsset(
      themeId: "calico",
      snapshot: StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
    ))

    let document = ThemeWebDocumentBuilder.document(for: asset, cacheBust: "fixed")
    XCTAssertEqual(document.channel, .inlineSVG)
    XCTAssertTrue(document.usesDOMEyeTracking)
    XCTAssertTrue(document.usesLayeredTracking)
    XCTAssertTrue(document.html.contains(#""trackingLayers""#))
    XCTAssertTrue(document.html.contains("eye-sockets"))
    XCTAssertTrue(document.html.contains("data-clawd-native-tracking-wrapper"))
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
      "sleepSequence": {
        "mode": "direct"
      },
      "objectScale": {
        "widthRatio": 0.5,
        "heightRatio": 0.4,
        "imgWidthRatio": 0.6,
        "offsetX": 0.2,
        "offsetY": 0.3,
        "fileScales": {
          "idle.svg": 1.2
        },
        "fileOffsets": {
          "idle.svg": { "x": 7, "y": -3 }
        }
      },
      "states": {
        "idle": ["idle.svg"],
        "working": ["work.svg"],
        "thinking": ["think.svg"]
      },
      "variants": {
        "alt": {
          "states": {
            "idle": ["alt.svg"]
          },
          "transitions": {
            "alt.svg": { "in": 120, "out": 80 }
          }
        }
      }
    }
    """
    try manifest.write(to: root.appendingPathComponent("themes/test/theme.json"), atomically: true, encoding: .utf8)
    let runtime = ThemeRuntime(projectRoot: root)
    let snapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
    let variantAsset = try XCTUnwrap(runtime.resolveAsset(themeId: "test", snapshot: snapshot, variantId: "alt"))
    XCTAssertEqual(variantAsset.fileName, "alt.svg")
    XCTAssertEqual(variantAsset.manifest.transitions?["alt.svg"]?.fadeIn, 120)
    XCTAssertEqual(variantAsset.manifest.transitions?["alt.svg"]?.fadeOut, 80)
    XCTAssertEqual(variantAsset.manifest.timing().sleepMode, .direct)
    XCTAssertEqual(variantAsset.manifest.objectScale?.widthRatio, 0.5)
    let overrides: JSONValue = .object([
      "states": .object([
        "idle": .object(["file": .string("override.svg")])
      ]),
      "transitions": .object([
        "override.svg": .object(["in": .number(220), "out": .number(90)])
      ]),
      "objectScale": .object([
        "fileScales": .object([
          "override.svg": .number(1.4)
        ]),
        "fileOffsets": .object([
          "override.svg": .object(["x": .number(-2), "y": .number(5)])
        ])
      ])
    ])
    let overrideAsset = try XCTUnwrap(runtime.resolveAsset(themeId: "test", snapshot: snapshot, variantId: "alt", overrides: overrides))
    XCTAssertEqual(overrideAsset.fileName, "override.svg")
    XCTAssertEqual(overrideAsset.manifest.transitions?["override.svg"]?.fadeIn, 220)
    XCTAssertEqual(overrideAsset.manifest.transitions?["override.svg"]?.fadeOut, 90)
    XCTAssertEqual(overrideAsset.manifest.objectScale?.fileScales?["override.svg"], 1.4)
    XCTAssertEqual(overrideAsset.manifest.objectScale?.fileOffsets?["override.svg"]?.x, -2)
    XCTAssertEqual(overrideAsset.manifest.objectScale?.fileOffsets?["override.svg"]?.y, 5)
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
