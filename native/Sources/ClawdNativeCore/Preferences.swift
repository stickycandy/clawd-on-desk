import Foundation

public struct AgentSettings: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var permissionsEnabled: Bool
  public var subagentPermissionsEnabled: Bool?
  public var notificationHookEnabled: Bool
  public var permissionMode: String?
  public var nativeNotificationSoundEnabled: Bool?

  public init(
    enabled: Bool = true,
    permissionsEnabled: Bool = true,
    subagentPermissionsEnabled: Bool? = nil,
    notificationHookEnabled: Bool = true,
    permissionMode: String? = nil,
    nativeNotificationSoundEnabled: Bool? = nil
  ) {
    self.enabled = enabled
    self.permissionsEnabled = permissionsEnabled
    self.subagentPermissionsEnabled = subagentPermissionsEnabled
    self.notificationHookEnabled = notificationHookEnabled
    self.permissionMode = permissionMode
    self.nativeNotificationSoundEnabled = nativeNotificationSoundEnabled
  }
}

public struct RemoteSSHProfile: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var host: String
  public var user: String
  public var port: Int
  public var remoteRoot: String
  public var enabled: Bool

  public init(id: String, name: String, host: String, user: String, port: Int = 22, remoteRoot: String = "~/.clawd", enabled: Bool = false) {
    self.id = id
    self.name = name
    self.host = host
    self.user = user
    self.port = port
    self.remoteRoot = remoteRoot
    self.enabled = enabled
  }
}

public struct Preferences: Codable, Equatable, Sendable {
  public var version: Int
  public var x: Double
  public var y: Double
  public var positionSaved: Bool
  public var size: String
  public var miniMode: Bool
  public var miniEdge: String
  public var preMiniX: Double?
  public var preMiniY: Double?
  public var lang: String
  public var showTray: Bool
  public var showDock: Bool
  public var manageClaudeHooksAutomatically: Bool
  public var autoStartWithClaude: Bool
  public var openAtLogin: Bool
  public var bubbleFollowPet: Bool
  public var sessionHudEnabled: Bool
  public var sessionHudShowStateLabels: Bool
  public var sessionHudShowElapsed: Bool
  public var sessionHudShowContextUsage: Bool
  public var sessionHudCleanupDetached: Bool
  public var sessionHudPinned: Bool
  public var sessionStaleMs: Int
  public var workingStaleMs: Int
  public var detachedIdleStaleMs: Int
  public var hideBubbles: Bool
  public var permissionBubblesEnabled: Bool
  public var notificationBubbleAutoCloseSeconds: Int
  public var permissionBubbleAutoCloseSeconds: Int
  public var updateBubbleAutoCloseSeconds: Int
  public var soundMuted: Bool
  public var soundVolume: Double
  public var flashTaskbarOnComplete: Bool
  public var lowPowerIdleMode: Bool
  public var mobilePreviewEnabled: Bool
  public var keepAwakeWhileWorking: Bool
  public var allowEdgePinning: Bool
  public var disableMiniMode: Bool
  public var keepSizeAcrossDisplays: Bool
  public var theme: String
  public var agents: [String: AgentSettings]
  public var sessionAliases: [String: SessionAlias]
  public var remoteSshProfiles: [RemoteSSHProfile]
  public var telegramApproval: TelegramApprovalConfig

  public init(
    version: Int = 1,
    x: Double = 0,
    y: Double = 0,
    positionSaved: Bool = false,
    size: String = "P:9",
    miniMode: Bool = false,
    miniEdge: String = "right",
    preMiniX: Double? = nil,
    preMiniY: Double? = nil,
    lang: String = "en",
    showTray: Bool = true,
    showDock: Bool = true,
    manageClaudeHooksAutomatically: Bool = true,
    autoStartWithClaude: Bool = false,
    openAtLogin: Bool = false,
    bubbleFollowPet: Bool = false,
    sessionHudEnabled: Bool = true,
    sessionHudShowStateLabels: Bool = true,
    sessionHudShowElapsed: Bool = true,
    sessionHudShowContextUsage: Bool = true,
    sessionHudCleanupDetached: Bool = false,
    sessionHudPinned: Bool = false,
    sessionStaleMs: Int = 600_000,
    workingStaleMs: Int = 300_000,
    detachedIdleStaleMs: Int = 30_000,
    hideBubbles: Bool = false,
    permissionBubblesEnabled: Bool = true,
    notificationBubbleAutoCloseSeconds: Int = 30,
    permissionBubbleAutoCloseSeconds: Int = 0,
    updateBubbleAutoCloseSeconds: Int = 12,
    soundMuted: Bool = false,
    soundVolume: Double = 1,
    flashTaskbarOnComplete: Bool = true,
    lowPowerIdleMode: Bool = false,
    mobilePreviewEnabled: Bool = false,
    keepAwakeWhileWorking: Bool = false,
    allowEdgePinning: Bool = false,
    disableMiniMode: Bool = false,
    keepSizeAcrossDisplays: Bool = false,
    theme: String = "clawd",
    agents: [String: AgentSettings] = Preferences.defaultAgents(),
    sessionAliases: [String: SessionAlias] = [:],
    remoteSshProfiles: [RemoteSSHProfile] = [],
    telegramApproval: TelegramApprovalConfig = TelegramApprovalConfig()
  ) {
    self.version = version
    self.x = x
    self.y = y
    self.positionSaved = positionSaved
    self.size = size
    self.miniMode = miniMode
    self.miniEdge = miniEdge
    self.preMiniX = preMiniX
    self.preMiniY = preMiniY
    self.lang = lang
    self.showTray = showTray
    self.showDock = showDock
    self.manageClaudeHooksAutomatically = manageClaudeHooksAutomatically
    self.autoStartWithClaude = autoStartWithClaude
    self.openAtLogin = openAtLogin
    self.bubbleFollowPet = bubbleFollowPet
    self.sessionHudEnabled = sessionHudEnabled
    self.sessionHudShowStateLabels = sessionHudShowStateLabels
    self.sessionHudShowElapsed = sessionHudShowElapsed
    self.sessionHudShowContextUsage = sessionHudShowContextUsage
    self.sessionHudCleanupDetached = sessionHudCleanupDetached
    self.sessionHudPinned = sessionHudPinned
    self.sessionStaleMs = sessionStaleMs
    self.workingStaleMs = workingStaleMs
    self.detachedIdleStaleMs = detachedIdleStaleMs
    self.hideBubbles = hideBubbles
    self.permissionBubblesEnabled = permissionBubblesEnabled
    self.notificationBubbleAutoCloseSeconds = notificationBubbleAutoCloseSeconds
    self.permissionBubbleAutoCloseSeconds = permissionBubbleAutoCloseSeconds
    self.updateBubbleAutoCloseSeconds = updateBubbleAutoCloseSeconds
    self.soundMuted = soundMuted
    self.soundVolume = soundVolume
    self.flashTaskbarOnComplete = flashTaskbarOnComplete
    self.lowPowerIdleMode = lowPowerIdleMode
    self.mobilePreviewEnabled = mobilePreviewEnabled
    self.keepAwakeWhileWorking = keepAwakeWhileWorking
    self.allowEdgePinning = allowEdgePinning
    self.disableMiniMode = disableMiniMode
    self.keepSizeAcrossDisplays = keepSizeAcrossDisplays
    self.theme = theme
    self.agents = agents
    self.sessionAliases = sessionAliases
    self.remoteSshProfiles = remoteSshProfiles
    self.telegramApproval = telegramApproval
  }

  public static func defaultAgents() -> [String: AgentSettings] {
    [
      "claude-code": .init(enabled: true, permissionsEnabled: true, subagentPermissionsEnabled: true),
      "codex": .init(enabled: true, permissionsEnabled: true, permissionMode: "intercept", nativeNotificationSoundEnabled: false),
      "copilot-cli": .init(),
      "cursor-agent": .init(permissionsEnabled: true),
      "gemini-cli": .init(),
      "antigravity-cli": .init(enabled: true, permissionsEnabled: false),
      "codebuddy": .init(),
      "kiro-cli": .init(),
      "kimi-cli": .init(),
      "qwen-code": .init(),
      "opencode": .init(),
      "pi": .init(enabled: true, permissionsEnabled: false),
      "openclaw": .init(enabled: true, permissionsEnabled: false),
      "hermes": .init(),
      "qoder": .init(enabled: true, permissionsEnabled: false)
    ]
  }

  public func validated() -> Preferences {
    var copy = self
    if !["en", "zh", "zh-TW", "ko", "ja"].contains(copy.lang) { copy.lang = "en" }
    if copy.miniEdge != "left" && copy.miniEdge != "right" { copy.miniEdge = "right" }
    if !copy.size.isValidClawdSize { copy.size = "P:9" }
    copy.sessionStaleMs = copy.sessionStaleMs == 0 ? 0 : min(max(copy.sessionStaleMs, 60_000), 86_400_000)
    copy.workingStaleMs = min(max(copy.workingStaleMs, 30_000), 86_400_000)
    copy.detachedIdleStaleMs = min(max(copy.detachedIdleStaleMs, 5_000), 300_000)
    copy.soundVolume = min(max(copy.soundVolume, 0), 1)
    copy.notificationBubbleAutoCloseSeconds = min(max(copy.notificationBubbleAutoCloseSeconds, 0), 600)
    copy.permissionBubbleAutoCloseSeconds = min(max(copy.permissionBubbleAutoCloseSeconds, 0), 600)
    copy.updateBubbleAutoCloseSeconds = min(max(copy.updateBubbleAutoCloseSeconds, 0), 600)
    for descriptor in AgentRegistry.all where copy.agents[descriptor.id] == nil {
      copy.agents[descriptor.id] = Preferences.defaultAgents()[descriptor.id] ?? AgentSettings()
    }
    return copy
  }
}

private extension String {
  var isValidClawdSize: Bool {
    self == "S" || self == "M" || self == "L" || range(of: #"^P:\d+(?:\.\d+)?$"#, options: .regularExpression) != nil
  }
}

public final class PreferencesStore: @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private var snapshot: Preferences

  public init(url: URL = PreferencesStore.defaultURL()) {
    self.url = url
    self.snapshot = PreferencesStore.load(from: url)
  }

  public static func defaultURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".clawd", isDirectory: true)
      .appendingPathComponent("clawd-prefs-native.json")
  }

  public static func load(from url: URL) -> Preferences {
    guard let data = try? Data(contentsOf: url) else {
      return Preferences()
    }
    do {
      return try JSONDecoder().decode(Preferences.self, from: data).validated()
    } catch {
      return Preferences()
    }
  }

  public func get() -> Preferences {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  @discardableResult
  public func update(_ transform: (inout Preferences) -> Void) throws -> Preferences {
    lock.lock()
    var copy = snapshot
    transform(&copy)
    copy = copy.validated()
    snapshot = copy
    lock.unlock()
    try save(copy)
    NotificationCenter.default.post(name: .clawdNativePreferencesDidChange, object: self)
    return copy
  }

  public func replace(_ preferences: Preferences) throws {
    let validated = preferences.validated()
    lock.lock()
    snapshot = validated
    lock.unlock()
    try save(validated)
    NotificationCenter.default.post(name: .clawdNativePreferencesDidChange, object: self)
  }

  private func save(_ preferences: Preferences) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(preferences)
    try data.write(to: url, options: [.atomic])
  }
}

public extension Notification.Name {
  static let clawdNativePreferencesDidChange = Notification.Name("ClawdNativePreferencesDidChange")
}
