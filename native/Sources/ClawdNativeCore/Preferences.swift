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
  public var label: String
  public var host: String
  public var user: String
  public var port: Int?
  public var remoteRoot: String
  public var enabled: Bool
  public var identityFile: String?
  public var remoteForwardPort: Int
  public var hostPrefix: String?
  public var autoStartCodexMonitor: Bool
  public var connectOnLaunch: Bool
  public var createdAt: Double
  public var lastDeployedAt: Double?
  public var detectedRemoteNodeBin: String?
  public var detectedRemoteNodeVersion: String?
  public var detectedRemoteNodeSource: String?
  public var detectedRemoteNodeAt: Double?

  private enum CodingKeys: String, CodingKey {
    case id, label, host, user, port, remoteRoot, enabled, identityFile, remoteForwardPort, hostPrefix
    case autoStartCodexMonitor, connectOnLaunch, createdAt, lastDeployedAt
    case detectedRemoteNodeBin, detectedRemoteNodeVersion, detectedRemoteNodeSource, detectedRemoteNodeAt
  }

  private enum LegacyCodingKeys: String, CodingKey {
    case name
  }

  public init(
    id: String,
    name: String? = nil,
    label: String? = nil,
    host: String,
    user: String = "",
    port: Int? = 22,
    remoteRoot: String = "~/.clawd",
    enabled: Bool = false,
    identityFile: String? = nil,
    remoteForwardPort: Int = 23333,
    hostPrefix: String? = nil,
    autoStartCodexMonitor: Bool = false,
    connectOnLaunch: Bool = false,
    createdAt: Double = Date().timeIntervalSince1970 * 1000,
    lastDeployedAt: Double? = nil,
    detectedRemoteNodeBin: String? = nil,
    detectedRemoteNodeVersion: String? = nil,
    detectedRemoteNodeSource: String? = nil,
    detectedRemoteNodeAt: Double? = nil
  ) {
    self.id = id
    self.label = label ?? name ?? id
    self.host = host
    self.user = user
    self.port = port
    self.remoteRoot = remoteRoot
    self.enabled = enabled
    self.identityFile = identityFile
    self.remoteForwardPort = remoteForwardPort
    self.hostPrefix = hostPrefix
    self.autoStartCodexMonitor = autoStartCodexMonitor
    self.connectOnLaunch = connectOnLaunch
    self.createdAt = createdAt
    self.lastDeployedAt = lastDeployedAt
    self.detectedRemoteNodeBin = detectedRemoteNodeBin
    self.detectedRemoteNodeVersion = detectedRemoteNodeVersion
    self.detectedRemoteNodeSource = detectedRemoteNodeSource
    self.detectedRemoteNodeAt = detectedRemoteNodeAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
    let now = Date().timeIntervalSince1970 * 1000

    id = try container.decode(String.self, forKey: .id)
    label = try container.decodeIfPresent(String.self, forKey: .label)
      ?? legacy.decodeIfPresent(String.self, forKey: .name)
      ?? id
    host = try container.decode(String.self, forKey: .host)
    user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
    remoteRoot = try container.decodeIfPresent(String.self, forKey: .remoteRoot) ?? "~/.clawd"
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
    remoteForwardPort = try container.decodeIfPresent(Int.self, forKey: .remoteForwardPort) ?? 23333
    hostPrefix = try container.decodeIfPresent(String.self, forKey: .hostPrefix)
    autoStartCodexMonitor = try container.decodeIfPresent(Bool.self, forKey: .autoStartCodexMonitor) ?? false
    connectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? false
    createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? now
    lastDeployedAt = try container.decodeIfPresent(Double.self, forKey: .lastDeployedAt)
    detectedRemoteNodeBin = try container.decodeIfPresent(String.self, forKey: .detectedRemoteNodeBin)
    detectedRemoteNodeVersion = try container.decodeIfPresent(String.self, forKey: .detectedRemoteNodeVersion)
    detectedRemoteNodeSource = try container.decodeIfPresent(String.self, forKey: .detectedRemoteNodeSource)
    detectedRemoteNodeAt = try container.decodeIfPresent(Double.self, forKey: .detectedRemoteNodeAt)
  }

  public var name: String {
    label
  }

  public var effectiveHost: String {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedHost.contains("@") || trimmedUser.isEmpty { return trimmedHost }
    return "\(trimmedUser)@\(trimmedHost)"
  }

  public var effectivePort: Int {
    port ?? 22
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
    copy.remoteSshProfiles = RemoteSSHProfileValidator.sanitize(copy.remoteSshProfiles)
    for descriptor in AgentRegistry.all where copy.agents[descriptor.id] == nil {
      copy.agents[descriptor.id] = Preferences.defaultAgents()[descriptor.id] ?? AgentSettings()
    }
    return copy
  }
}

public struct RemoteSSHProfileValidationError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String
  public var description: String { message }

  public init(_ message: String) {
    self.message = message
  }
}

public enum RemoteSSHProfileValidator {
  public static let remoteForwardPorts: Set<Int> = [23333, 23334, 23335, 23336, 23337]
  private static let hostBare = try! NSRegularExpression(pattern: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#)
  private static let hostUser = try! NSRegularExpression(pattern: #"^[a-zA-Z0-9][a-zA-Z0-9._-]*@[a-zA-Z0-9][a-zA-Z0-9._-]*$"#)
  private static let idRegex = try! NSRegularExpression(pattern: #"^[a-zA-Z0-9_-]{1,64}$"#)

  public static func validate(_ profile: RemoteSSHProfile) -> Result<Void, RemoteSSHProfileValidationError> {
    guard matches(idRegex, profile.id) else {
      return .failure(.init("profile.id must be 1-64 chars [a-zA-Z0-9_-]"))
    }
    guard isValidLabel(profile.label) else {
      return .failure(.init("profile.label must be 1-100 chars and contain no control characters"))
    }
    guard isValidHost(profile.effectiveHost) else {
      return .failure(.init("profile.host must be a hostname or user@hostname"))
    }
    if let port = profile.port, port < 1 || port > 65535 {
      return .failure(.init("profile.port must be in [1, 65535]"))
    }
    if let identityFile = profile.identityFile, !identityFile.isEmpty, !isValidIdentityFile(identityFile) {
      return .failure(.init("profile.identityFile must be absolute and not start with '-'"))
    }
    guard remoteForwardPorts.contains(profile.remoteForwardPort) else {
      return .failure(.init("profile.remoteForwardPort must be one of \(remoteForwardPorts.sorted())"))
    }
    if let hostPrefix = profile.hostPrefix, !hostPrefix.isEmpty, !isValidHostPrefix(hostPrefix) {
      return .failure(.init("profile.hostPrefix contains forbidden shell characters"))
    }
    if let node = profile.detectedRemoteNodeBin, !isValidRemoteNodeBin(node) {
      return .failure(.init("profile.detectedRemoteNodeBin must be an absolute POSIX path"))
    }
    if let version = profile.detectedRemoteNodeVersion, !isSupportedRemoteNodeVersion(version) {
      return .failure(.init("profile.detectedRemoteNodeVersion must be v14+"))
    }
    return .success(())
  }

  public static func sanitize(_ profiles: [RemoteSSHProfile]) -> [RemoteSSHProfile] {
    var seen = Set<String>()
    var out: [RemoteSSHProfile] = []
    for var profile in profiles {
      profile.id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
      profile.label = profile.label.trimmingCharacters(in: .whitespacesAndNewlines)
      profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
      profile.user = profile.user.trimmingCharacters(in: .whitespacesAndNewlines)
      profile.identityFile = profile.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      profile.hostPrefix = profile.hostPrefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      profile.detectedRemoteNodeBin = profile.detectedRemoteNodeBin?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      profile.detectedRemoteNodeVersion = profile.detectedRemoteNodeVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      profile.detectedRemoteNodeSource = profile.detectedRemoteNodeSource?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      if profile.remoteForwardPort == 0 { profile.remoteForwardPort = 23333 }
      if profile.createdAt <= 0 { profile.createdAt = Date().timeIntervalSince1970 * 1000 }
      if case .success = validate(profile), !seen.contains(profile.id) {
        seen.insert(profile.id)
        out.append(profile)
      }
    }
    return out
  }

  public static func isValidHost(_ value: String) -> Bool {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 255 else { return false }
    return matches(hostBare, value) || matches(hostUser, value)
  }

  public static func isValidIdentityFile(_ value: String) -> Bool {
    !value.isEmpty
      && !value.hasPrefix("-")
      && value.hasPrefix("/")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  public static func isValidHostPrefix(_ value: String) -> Bool {
    value.rangeOfCharacter(from: .controlCharacters) == nil
      && value.rangeOfCharacter(from: CharacterSet(charactersIn: "'\"`$\\!")) == nil
  }

  public static func isValidRemoteNodeBin(_ value: String) -> Bool {
    value.hasPrefix("/") && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  public static func isSupportedRemoteNodeVersion(_ value: String) -> Bool {
    guard value.lowercased().hasPrefix("v") else { return false }
    let majorText = value.dropFirst().split(separator: ".").first.flatMap(String.init) ?? ""
    return (Int(majorText) ?? 0) >= 14
  }

  private static func isValidLabel(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 100 && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range)?.range == range
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }

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
