import Foundation

public enum ClawdState: String, Codable, CaseIterable, Sendable {
  case idle
  case yawning
  case dozing
  case collapsing
  case thinking
  case working
  case juggling
  case sweeping
  case error
  case attention
  case notification
  case carrying
  case sleeping
  case waking
  case miniIdle = "mini-idle"
  case miniEnter = "mini-enter"
  case miniPeek = "mini-peek"
  case miniAlert = "mini-alert"
  case miniHappy = "mini-happy"
  case miniCrabwalk = "mini-crabwalk"
  case miniEnterSleep = "mini-enter-sleep"
  case miniSleep = "mini-sleep"
  case miniWorking = "mini-working"

  public var priority: Int {
    switch self {
    case .error:
      return 8
    case .notification, .miniAlert:
      return 7
    case .sweeping:
      return 6
    case .attention, .miniHappy:
      return 5
    case .carrying, .juggling:
      return 4
    case .working, .miniWorking:
      return 3
    case .thinking:
      return 2
    case .idle, .miniIdle, .miniEnter, .miniPeek, .miniCrabwalk, .miniEnterSleep:
      return 1
    case .sleeping, .miniSleep, .yawning, .dozing, .collapsing, .waking:
      return 0
    }
  }

  public var isOneShot: Bool {
    switch self {
    case .attention, .error, .sweeping, .notification, .carrying, .miniAlert, .miniHappy:
      return true
    default:
      return false
    }
  }

  public var isSleepSequence: Bool {
    switch self {
    case .yawning, .dozing, .collapsing, .sleeping, .waking, .miniSleep, .miniEnterSleep:
      return true
    default:
      return false
    }
  }
}

public struct ContextUsage: Codable, Equatable, Sendable {
  public var used: Double
  public var limit: Double?
  public var percent: Int?
  public var source: String?

  public init(used: Double, limit: Double? = nil, percent: Int? = nil, source: String? = nil) {
    self.used = used
    self.limit = limit
    self.percent = percent
    self.source = source
  }
}

public struct SessionMetadata: Codable, Equatable, Sendable {
  public var sourcePid: Int?
  public var agentPid: Int?
  public var cwd: String
  public var editor: String?
  public var pidChain: [Int]?
  public var agentId: String
  public var host: String
  public var headless: Bool
  public var platform: String?
  public var model: String?
  public var provider: String?
  public var codexOriginator: String?
  public var codexSource: String?
  public var wtHwnd: String?
  public var ghosttyTerminalId: String?
  public var toolName: String?
  public var toolUseId: String?
  public var toolInputFingerprint: String?
  public var displayHint: String?
  public var sessionTitle: String?
  public var contextUsage: ContextUsage?
  public var assistantLastOutput: String?
  public var assistantLastOutputTruncated: Bool
  public var permissionSuspect: Bool
  public var preserveState: Bool
  public var backgroundTasksCount: Int
  public var sessionCronsCount: Int
  public var stopHookActive: Bool
  public var transientPermissionEvent: Bool
  public var hookSource: String?

  public init(
    sourcePid: Int? = nil,
    agentPid: Int? = nil,
    cwd: String = "",
    editor: String? = nil,
    pidChain: [Int]? = nil,
    agentId: String = "claude-code",
    host: String = "local",
    headless: Bool = false,
    platform: String? = nil,
    model: String? = nil,
    provider: String? = nil,
    codexOriginator: String? = nil,
    codexSource: String? = nil,
    wtHwnd: String? = nil,
    ghosttyTerminalId: String? = nil,
    toolName: String? = nil,
    toolUseId: String? = nil,
    toolInputFingerprint: String? = nil,
    displayHint: String? = nil,
    sessionTitle: String? = nil,
    contextUsage: ContextUsage? = nil,
    assistantLastOutput: String? = nil,
    assistantLastOutputTruncated: Bool = false,
    permissionSuspect: Bool = false,
    preserveState: Bool = false,
    backgroundTasksCount: Int = 0,
    sessionCronsCount: Int = 0,
    stopHookActive: Bool = false,
    transientPermissionEvent: Bool = false,
    hookSource: String? = nil
  ) {
    self.sourcePid = sourcePid
    self.agentPid = agentPid
    self.cwd = cwd
    self.editor = editor
    self.pidChain = pidChain
    self.agentId = agentId
    self.host = host
    self.headless = headless
    self.platform = platform
    self.model = model
    self.provider = provider
    self.codexOriginator = codexOriginator
    self.codexSource = codexSource
    self.wtHwnd = wtHwnd
    self.ghosttyTerminalId = ghosttyTerminalId
    self.toolName = toolName
    self.toolUseId = toolUseId
    self.toolInputFingerprint = toolInputFingerprint
    self.displayHint = displayHint
    self.sessionTitle = sessionTitle
    self.contextUsage = contextUsage
    self.assistantLastOutput = assistantLastOutput
    self.assistantLastOutputTruncated = assistantLastOutputTruncated
    self.permissionSuspect = permissionSuspect
    self.preserveState = preserveState
    self.backgroundTasksCount = backgroundTasksCount
    self.sessionCronsCount = sessionCronsCount
    self.stopHookActive = stopHookActive
    self.transientPermissionEvent = transientPermissionEvent
    self.hookSource = hookSource
  }
}

public struct AgentSession: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var state: ClawdState
  public var event: String?
  public var updatedAt: Date
  public var startedAt: Date
  public var metadata: SessionMetadata
  public var recentEvents: [String]

  public init(
    id: String,
    state: ClawdState,
    event: String?,
    updatedAt: Date,
    startedAt: Date,
    metadata: SessionMetadata,
    recentEvents: [String] = []
  ) {
    self.id = id
    self.state = state
    self.event = event
    self.updatedAt = updatedAt
    self.startedAt = startedAt
    self.metadata = metadata
    self.recentEvents = recentEvents
  }

  public var visibleInHUD: Bool {
    !metadata.headless && state != .sleeping && state != .miniSleep
  }

  public var badge: String {
    if state == .attention { return "Done" }
    if state == .notification { return "Input" }
    if state == .error { return "Error" }
    if state == .working || state == .thinking || state == .juggling || state == .carrying || state == .sweeping {
      return "Live"
    }
    return "Idle"
  }
}

public struct StateSnapshot: Codable, Equatable, Sendable {
  public var currentState: ClawdState
  public var sessions: [AgentSession]
  public var updatedAt: Date

  public init(currentState: ClawdState, sessions: [AgentSession], updatedAt: Date) {
    self.currentState = currentState
    self.sessions = sessions
    self.updatedAt = updatedAt
  }
}
