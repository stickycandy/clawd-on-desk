import Foundation

public struct ThemeAsset: Equatable, Sendable {
  public var themeId: String
  public var state: ClawdState
  public var fileName: String
  public var url: URL
  public var readAccessURL: URL
  public var manifest: ThemeManifest

  public init(themeId: String, state: ClawdState, fileName: String, url: URL, readAccessURL: URL, manifest: ThemeManifest) {
    self.themeId = themeId
    self.state = state
    self.fileName = fileName
    self.url = url
    self.readAccessURL = readAccessURL
    self.manifest = manifest
  }
}

public struct ThemeSound: Equatable, Sendable {
  public var themeId: String
  public var name: String
  public var fileName: String
  public var url: URL

  public init(themeId: String, name: String, fileName: String, url: URL) {
    self.themeId = themeId
    self.name = name
    self.fileName = fileName
    self.url = url
  }
}

public final class ThemeRuntime: @unchecked Sendable {
  public let projectRoot: URL
  public let userThemesRoot: URL
  private let fileManager: FileManager

  public init(
    projectRoot: URL,
    userThemesRoot: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".clawd", isDirectory: true)
      .appendingPathComponent("themes", isDirectory: true),
    fileManager: FileManager = .default
  ) {
    self.projectRoot = projectRoot
    self.userThemesRoot = userThemesRoot
    self.fileManager = fileManager
  }

  public func loadTheme(id: String, variantId: String = "default", overrides: JSONValue? = nil) throws -> LoadedTheme {
    let safeId = id.lastPathComponent
    let builtInURL = projectRoot
      .appendingPathComponent("themes", isDirectory: true)
      .appendingPathComponent(safeId, isDirectory: true)
      .appendingPathComponent("theme.json")
    if fileManager.fileExists(atPath: builtInURL.path) {
      let manifest = try ThemeManifest.load(from: builtInURL, variantId: variantId, overrides: overrides)
      return LoadedTheme(id: safeId, variantId: variantId, manifest: manifest, themeDirectory: builtInURL.deletingLastPathComponent(), isBuiltIn: true, projectRoot: projectRoot)
    }

    let userURL = userThemesRoot
      .appendingPathComponent(safeId, isDirectory: true)
      .appendingPathComponent("theme.json")
    if fileManager.fileExists(atPath: userURL.path) {
      let manifest = try ThemeManifest.load(from: userURL, variantId: variantId, overrides: overrides)
      return LoadedTheme(id: safeId, variantId: variantId, manifest: manifest, themeDirectory: userURL.deletingLastPathComponent(), isBuiltIn: false, projectRoot: projectRoot)
    }

    if safeId != "clawd" {
      return try loadTheme(id: "clawd", variantId: variantId, overrides: overrides)
    }
    throw ThemeRuntimeError.themeNotFound(id)
  }

  public func resolveAsset(themeId: String, snapshot: StateSnapshot, variantId: String = "default", overrides: JSONValue? = nil) -> ThemeAsset? {
    guard let loaded = try? loadTheme(id: themeId, variantId: variantId, overrides: overrides) else { return nil }
    return loaded.resolveAsset(snapshot: snapshot)
  }

  public func resolveAsset(themeId: String, fileName: String, state: ClawdState, variantId: String = "default", overrides: JSONValue? = nil) -> ThemeAsset? {
    guard let loaded = try? loadTheme(id: themeId, variantId: variantId, overrides: overrides), loaded.assetExists(fileName) else { return nil }
    return loaded.makeAsset(fileName: fileName.lastPathComponent, state: state)
  }

  public func resolveReactionAsset(themeId: String, reaction: String, side: String? = nil, variantId: String = "default", overrides: JSONValue? = nil) -> (asset: ThemeAsset, durationMs: Int?)? {
    guard let loaded = try? loadTheme(id: themeId, variantId: variantId, overrides: overrides),
          let descriptor = loaded.manifest.reactions?[reaction]
    else { return nil }
    let candidate: String?
    if side == "left" {
      candidate = descriptor.fileLeft ?? descriptor.file
    } else if side == "right" {
      candidate = descriptor.fileRight ?? descriptor.file
    } else {
      candidate = descriptor.file
    }
    guard let file = candidate, loaded.assetExists(file) else { return nil }
    return (loaded.makeAsset(fileName: file.lastPathComponent, state: .attention), descriptor.duration)
  }

  public func resolveSound(themeId: String, name: String, variantId: String = "default", overrides: JSONValue? = nil) -> ThemeSound? {
    guard let loaded = try? loadTheme(id: themeId, variantId: variantId, overrides: overrides) else { return nil }
    return loaded.resolveSound(name: name)
  }

  public enum ThemeRuntimeError: Error, Equatable {
    case themeNotFound(String)
  }
}

public struct LoadedTheme: Equatable, Sendable {
  public var id: String
  public var variantId: String
  public var manifest: ThemeManifest
  public var themeDirectory: URL
  public var isBuiltIn: Bool
  public var projectRoot: URL

  public func resolveAsset(snapshot: StateSnapshot) -> ThemeAsset? {
    let state = snapshot.currentState
    guard let fileName = resolveFileName(snapshot: snapshot) else { return nil }
    return makeAsset(fileName: fileName, state: state)
  }

  public func makeAsset(fileName: String, state: ClawdState) -> ThemeAsset {
    let url = resolveAssetURL(fileName: fileName)
    let readAccess = readAccessURL(for: url)
    return ThemeAsset(themeId: id, state: state, fileName: fileName, url: url, readAccessURL: readAccess, manifest: manifest)
  }

  public func resolveSound(name: String) -> ThemeSound? {
    guard let fileName = manifest.soundFile(named: name),
          let url = resolveSoundURL(fileName: fileName)
    else { return nil }
    return ThemeSound(themeId: id, name: name, fileName: fileName, url: url)
  }

  public func hitBox(for asset: ThemeAsset) -> ThemeManifest.HitBox? {
    let file = asset.fileName.lastPathComponent
    if let specific = manifest.fileHitBoxes?[file] {
      return specific
    }
    if manifest.sleepingHitboxFiles?.map({ $0.lastPathComponent }).contains(file) == true,
       let sleeping = manifest.hitBoxes?["sleeping"] {
      return sleeping
    }
    if manifest.wideHitboxFiles?.map({ $0.lastPathComponent }).contains(file) == true,
       let wide = manifest.hitBoxes?["wide"] {
      return wide
    }
    return manifest.hitBoxes?["default"]
  }

  public func resolveFileName(snapshot: StateSnapshot) -> String? {
    if let hint = snapshot.sessions.first(where: { !$0.metadata.headless })?.metadata.displayHint,
       let mapped = manifest.displayHintMap?[hint],
       assetExists(mapped) {
      return mapped.lastPathComponent
    }

    if snapshot.currentState == .working,
       let tierFile = tierFile(manifest.workingTiers, count: visibleSessionCount(snapshot)) {
      return tierFile
    }

    if snapshot.currentState == .juggling,
       let tierFile = tierFile(manifest.jugglingTiers, count: jugglingSessionCount(snapshot)) {
      return tierFile
    }

    for state in fallbackChain(for: snapshot.currentState) {
      if let file = manifest.stateFiles(for: state).first(where: assetExists) {
        return file.lastPathComponent
      }
    }
    return nil
  }

  public func resolveAssetURL(fileName: String) -> URL {
    let safe = fileName.lastPathComponent
    if isBuiltIn {
      let themeAsset = themeDirectory.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(safe)
      if FileManager.default.fileExists(atPath: themeAsset.path) {
        return themeAsset
      }
      return projectRoot.appendingPathComponent("assets", isDirectory: true)
        .appendingPathComponent("svg", isDirectory: true)
        .appendingPathComponent(safe)
    }
    if safe.lowercased().hasSuffix(".svg") {
      let cached = themeDirectory.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(safe)
      return cached
    }
    return themeDirectory.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(safe)
  }

  public func resolveSoundURL(fileName: String) -> URL? {
    let safe = fileName.lastPathComponent
    let bundled = projectRoot
      .appendingPathComponent("assets", isDirectory: true)
      .appendingPathComponent("sounds", isDirectory: true)
      .appendingPathComponent(safe)
    if isBuiltIn {
      return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }

    let themeSound = themeDirectory
      .appendingPathComponent("sounds", isDirectory: true)
      .appendingPathComponent(safe)
    if FileManager.default.fileExists(atPath: themeSound.path) {
      return themeSound
    }
    return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
  }

  private func readAccessURL(for assetURL: URL) -> URL {
    if isBuiltIn {
      return projectRoot
    }
    return themeDirectory
  }

  private func tierFile(_ tiers: [ThemeManifest.Tier]?, count: Int) -> String? {
    guard let tiers else { return nil }
    return tiers
      .sorted { $0.minSessions > $1.minSessions }
      .first { count >= $0.minSessions && assetExists($0.file) }?
      .file
      .lastPathComponent
  }

  private func visibleSessionCount(_ snapshot: StateSnapshot) -> Int {
    let count = snapshot.sessions.filter { !$0.metadata.headless && $0.state.priority >= ClawdState.working.priority }.count
    return max(count, 1)
  }

  private func jugglingSessionCount(_ snapshot: StateSnapshot) -> Int {
    let count = snapshot.sessions.filter { !$0.metadata.headless && $0.state == .juggling }.count
    return max(count, 1)
  }

  private func fallbackChain(for state: ClawdState) -> [ClawdState] {
    if state.rawValue.hasPrefix("mini-") {
      switch state {
      case .miniAlert:
        return [.miniAlert, .notification, .idle]
      case .miniHappy:
        return [.miniHappy, .attention, .idle]
      case .miniSleep, .miniEnterSleep:
        return [state, .sleeping, .idle]
      case .miniWorking:
        return [.miniWorking, .miniIdle, .idle]
      default:
        return [state, .idle]
      }
    }
    switch state {
    case .sleeping, .dozing, .collapsing, .yawning, .waking:
      return [state, .sleeping, .idle]
    case .error:
      return [.error, .notification, .idle]
    case .attention:
      return [.attention, .idle]
    case .notification:
      return [.notification, .idle]
    case .carrying, .sweeping, .juggling, .working, .thinking:
      return [state, .working, .thinking, .idle]
    default:
      return [state, .idle]
    }
  }

  public func assetExists(_ fileName: String) -> Bool {
    FileManager.default.fileExists(atPath: resolveAssetURL(fileName: fileName).path)
  }
}

private extension String {
  var lastPathComponent: String {
    (self as NSString).lastPathComponent
  }
}
