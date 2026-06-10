import Foundation

public struct ThemeManifest: Codable, Equatable, Sendable {
  public struct ViewBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
  }

  public struct Timings: Codable, Equatable, Sendable {
    public var minDisplay: [String: Int]?
    public var autoReturn: [String: Int]?
    public var yawnDuration: Int?
    public var wakeDuration: Int?
    public var deepSleepTimeout: Int?
    public var mouseIdleTimeout: Int?
    public var mouseSleepTimeout: Int?
  }

  public struct Tier: Codable, Equatable, Sendable {
    public var minSessions: Int
    public var file: String
  }

  public struct IdleAnimation: Codable, Equatable, Sendable {
    public var file: String
    public var duration: Int?
  }

  public struct MiniMode: Codable, Equatable, Sendable {
    public var supported: Bool?
    public var states: [String: [String]]?
  }

  public struct EyeTracking: Codable, Equatable, Sendable {
    public struct Ids: Codable, Equatable, Sendable {
      public var eyes: String?
      public var body: String?
      public var shadow: String?
      public var dozeEyes: String?
    }

    public var enabled: Bool?
    public var states: [String]?
    public var eyeRatioX: Double?
    public var eyeRatioY: Double?
    public var maxOffset: Double?
    public var ids: Ids?
  }

  public struct HitBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
  }

  public struct Reaction: Codable, Equatable, Sendable {
    public var file: String?
    public var fileLeft: String?
    public var fileRight: String?
    public var duration: Int?
  }

  public var schemaVersion: Int?
  public var name: String
  public var author: String?
  public var version: String?
  public var description: String?
  public var viewBox: ViewBox?
  public var states: [String: [String]]
  public var workingTiers: [Tier]?
  public var jugglingTiers: [Tier]?
  public var idleAnimations: [IdleAnimation]?
  public var miniMode: MiniMode?
  public var eyeTracking: EyeTracking?
  public var hitBoxes: [String: HitBox]?
  public var fileHitBoxes: [String: HitBox]?
  public var wideHitboxFiles: [String]?
  public var sleepingHitboxFiles: [String]?
  public var reactions: [String: Reaction]?
  public var timings: Timings?
  public var displayHintMap: [String: String]?

  public init(name: String, states: [String: [String]], author: String? = nil, version: String? = nil) {
    self.schemaVersion = 1
    self.name = name
    self.author = author
    self.version = version
    self.description = nil
    self.viewBox = nil
    self.states = states
    self.workingTiers = nil
    self.jugglingTiers = nil
    self.idleAnimations = nil
    self.miniMode = nil
    self.eyeTracking = nil
    self.hitBoxes = nil
    self.fileHitBoxes = nil
    self.wideHitboxFiles = nil
    self.sleepingHitboxFiles = nil
    self.reactions = nil
    self.timings = nil
    self.displayHintMap = nil
  }

  public static func load(from url: URL) throws -> ThemeManifest {
    try load(from: url, variantId: "default", overrides: nil)
  }

  public static func load(from url: URL, variantId: String = "default", overrides: JSONValue? = nil) throws -> ThemeManifest {
    let data = try Data(contentsOf: url)
    let patchedData = try patchedThemeData(data, variantId: variantId, overrides: overrides)
    let manifest = try JSONDecoder().decode(ThemeManifest.self, from: patchedData)
    try manifest.validate()
    return manifest
  }

  public func validate() throws {
    for required in ["idle", "working", "thinking"] {
      guard let files = states[required], !files.isEmpty else {
        throw ThemeError.missingRequiredState(required)
      }
    }
  }

  public func stateFiles(for state: ClawdState) -> [String] {
    if state.rawValue.hasPrefix("mini-"), let files = miniMode?.states?[state.rawValue] {
      return files
    }
    return states[state.rawValue] ?? []
  }

  public func timing() -> StateTiming {
    var minDisplay: [ClawdState: Int] = [:]
    var autoReturn: [ClawdState: Int] = [:]
    for (key, value) in timings?.minDisplay ?? [:] {
      if let state = ClawdState(rawValue: key) { minDisplay[state] = value }
    }
    for (key, value) in timings?.autoReturn ?? [:] {
      if let state = ClawdState(rawValue: key) { autoReturn[state] = value }
    }
    return StateTiming(
      minDisplayMs: minDisplay.isEmpty ? StateTiming().minDisplayMs : minDisplay,
      autoReturnMs: autoReturn.isEmpty ? StateTiming().autoReturnMs : autoReturn,
      deepSleepTimeoutMs: timings?.deepSleepTimeout ?? 600_000,
      mouseIdleTimeoutMs: timings?.mouseIdleTimeout ?? 20_000,
      mouseSleepTimeoutMs: timings?.mouseSleepTimeout ?? 60_000
    )
  }

  public enum ThemeError: Error, Equatable {
    case missingRequiredState(String)
  }

  private static func patchedThemeData(_ data: Data, variantId: String, overrides: JSONValue?) throws -> Data {
    guard var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return data
    }
    applyVariant(to: &raw, variantId: variantId)
    if case .object(let map) = overrides {
      applyOverrides(to: &raw, overrides: map.mapValues { $0.anyValue })
    }
    raw.removeValue(forKey: "variants")
    return try JSONSerialization.data(withJSONObject: raw, options: [])
  }

  private static func applyVariant(to raw: inout [String: Any], variantId: String) {
    guard let variants = raw["variants"] as? [String: Any] else { return }
    let requested = variantId.isEmpty ? "default" : variantId
    let spec = (variants[requested] as? [String: Any]) ?? (variants["default"] as? [String: Any])
    guard let spec else { return }
    let allowed: Set<String> = [
      "states", "miniMode",
      "workingTiers", "jugglingTiers", "idleAnimations", "wideHitboxFiles", "sleepingHitboxFiles",
      "hitBoxes", "fileHitBoxes", "timings", "transitions", "objectScale", "displayHintMap"
    ]
    let replace: Set<String> = [
      "workingTiers", "jugglingTiers", "idleAnimations", "wideHitboxFiles", "sleepingHitboxFiles", "displayHintMap"
    ]
    for (key, value) in spec {
      if key == "name" || key == "description" || key == "preview" { continue }
      guard allowed.contains(key) else { continue }
      if replace.contains(key) || value is [Any] {
        raw[key] = value
      } else if let next = value as? [String: Any], let current = raw[key] as? [String: Any] {
        raw[key] = deepMerge(current, next)
      } else {
        raw[key] = value
      }
    }
  }

  private static func applyOverrides(to raw: inout [String: Any], overrides: [String: Any]) {
    if let stateOverrides = overrides["states"] as? [String: Any] {
      var states = raw["states"] as? [String: Any] ?? [:]
      for (state, entry) in stateOverrides {
        if let files = filesFromOverride(entry) {
          states[state] = files
        }
      }
      raw["states"] = states
    }
    if let timings = overrides["timings"] as? [String: Any] {
      raw["timings"] = deepMerge(raw["timings"] as? [String: Any] ?? [:], timings)
    }
    if let reactions = overrides["reactions"] as? [String: Any] {
      raw["reactions"] = deepMerge(raw["reactions"] as? [String: Any] ?? [:], reactions)
    }
    if let hitbox = overrides["hitbox"] as? [String: Any] {
      raw["hitBoxes"] = deepMerge(raw["hitBoxes"] as? [String: Any] ?? [:], hitbox)
    }
    if let idleAnimations = overrides["idleAnimations"] as? [Any] {
      raw["idleAnimations"] = idleAnimations
    }
    if let displayHintMap = overrides["displayHintMap"] as? [String: Any] {
      raw["displayHintMap"] = displayHintMap
    }
  }

  private static func filesFromOverride(_ entry: Any) -> [String]? {
    if let file = entry as? String, !file.isEmpty { return [file] }
    if let files = entry as? [String], !files.isEmpty { return files }
    guard let object = entry as? [String: Any] else { return nil }
    if object["disabled"] as? Bool == true { return nil }
    if let file = object["file"] as? String, !file.isEmpty { return [file] }
    if let file = object["asset"] as? String, !file.isEmpty { return [file] }
    if let files = object["files"] as? [String], !files.isEmpty { return files }
    return nil
  }

  private static func deepMerge(_ current: [String: Any], _ next: [String: Any]) -> [String: Any] {
    var out = current
    for (key, value) in next {
      if let left = out[key] as? [String: Any], let right = value as? [String: Any] {
        out[key] = deepMerge(left, right)
      } else {
        out[key] = value
      }
    }
    return out
  }
}
