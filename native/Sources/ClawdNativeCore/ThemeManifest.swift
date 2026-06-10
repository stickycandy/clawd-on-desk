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
    let data = try Data(contentsOf: url)
    let manifest = try JSONDecoder().decode(ThemeManifest.self, from: data)
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
}
