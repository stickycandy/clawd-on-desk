import Foundation

public struct ProcessNames: Codable, Equatable, Sendable {
  public var win: [String]
  public var mac: [String]
  public var linux: [String]

  public init(win: [String], mac: [String], linux: [String]) {
    self.win = win
    self.mac = mac
    self.linux = linux
  }
}

public struct AgentCapabilities: Codable, Equatable, Sendable {
  public var httpHook: Bool
  public var permissionApproval: Bool
  public var interactiveBubble: Bool
  public var sessionEnd: Bool
  public var terminalFocus: Bool
  public var stateOnly: Bool

  public init(
    httpHook: Bool = true,
    permissionApproval: Bool,
    interactiveBubble: Bool,
    sessionEnd: Bool = true,
    terminalFocus: Bool = true,
    stateOnly: Bool = false
  ) {
    self.httpHook = httpHook
    self.permissionApproval = permissionApproval
    self.interactiveBubble = interactiveBubble
    self.sessionEnd = sessionEnd
    self.terminalFocus = terminalFocus
    self.stateOnly = stateOnly
  }
}

public struct AgentDescriptor: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var displayName: String
  public var processNames: ProcessNames
  public var capabilities: AgentCapabilities
  public var installCommand: [String]?
  public var uninstallCommand: [String]?

  public init(
    id: String,
    displayName: String,
    processNames: ProcessNames,
    capabilities: AgentCapabilities,
    installCommand: [String]? = nil,
    uninstallCommand: [String]? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.processNames = processNames
    self.capabilities = capabilities
    self.installCommand = installCommand
    self.uninstallCommand = uninstallCommand
  }
}

public enum AgentRegistry {
  public static let all: [AgentDescriptor] = [
    AgentDescriptor(
      id: "claude-code",
      displayName: "Claude Code",
      processNames: .init(win: ["claude.exe"], mac: ["claude"], linux: ["claude"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/install.js"],
      uninstallCommand: ["node", "hooks/uninstall.js"]
    ),
    AgentDescriptor(
      id: "codex",
      displayName: "Codex CLI",
      processNames: .init(win: ["codex.exe"], mac: ["codex"], linux: ["codex"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/codex-install.js"],
      uninstallCommand: ["node", "hooks/codex-install.js", "--uninstall"]
    ),
    AgentDescriptor(
      id: "copilot-cli",
      displayName: "Copilot CLI",
      processNames: .init(win: ["copilot.exe"], mac: ["copilot"], linux: ["copilot"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/copilot-install.js"]
    ),
    AgentDescriptor(
      id: "gemini-cli",
      displayName: "Gemini CLI",
      processNames: .init(win: ["gemini.exe"], mac: ["gemini"], linux: ["gemini"]),
      capabilities: .init(permissionApproval: false, interactiveBubble: false, stateOnly: true),
      installCommand: ["node", "hooks/gemini-install.js"]
    ),
    AgentDescriptor(
      id: "antigravity-cli",
      displayName: "Antigravity CLI",
      processNames: .init(win: ["agy.exe"], mac: ["agy"], linux: ["agy"]),
      capabilities: .init(permissionApproval: false, interactiveBubble: false, stateOnly: true),
      installCommand: ["node", "hooks/antigravity-install.js"]
    ),
    AgentDescriptor(
      id: "cursor-agent",
      displayName: "Cursor Agent",
      processNames: .init(win: ["cursor-agent.exe"], mac: ["cursor-agent"], linux: ["cursor-agent"]),
      capabilities: .init(permissionApproval: false, interactiveBubble: false),
      installCommand: ["node", "hooks/cursor-install.js"]
    ),
    AgentDescriptor(
      id: "codebuddy",
      displayName: "CodeBuddy",
      processNames: .init(win: ["codebuddy.exe"], mac: ["codebuddy"], linux: ["codebuddy"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/codebuddy-install.js"]
    ),
    AgentDescriptor(
      id: "kiro-cli",
      displayName: "Kiro CLI",
      processNames: .init(win: ["kiro-cli.exe"], mac: ["kiro-cli"], linux: ["kiro-cli"]),
      capabilities: .init(permissionApproval: false, interactiveBubble: false),
      installCommand: ["node", "hooks/kiro-install.js"]
    ),
    AgentDescriptor(
      id: "kimi-cli",
      displayName: "Kimi Code CLI",
      processNames: .init(win: ["kimi.exe"], mac: ["kimi", "Kimi Code"], linux: ["kimi"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: false),
      installCommand: ["node", "hooks/kimi-install.js"]
    ),
    AgentDescriptor(
      id: "qwen-code",
      displayName: "Qwen Code",
      processNames: .init(win: ["qwen.exe"], mac: ["qwen"], linux: ["qwen"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/qwen-code-install.js"],
      uninstallCommand: ["node", "hooks/qwen-code-install.js", "--uninstall"]
    ),
    AgentDescriptor(
      id: "opencode",
      displayName: "opencode",
      processNames: .init(win: ["opencode.exe"], mac: ["opencode"], linux: ["opencode"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/opencode-install.js"]
    ),
    AgentDescriptor(
      id: "pi",
      displayName: "Pi",
      processNames: .init(win: ["pi.exe"], mac: ["pi"], linux: ["pi"]),
      capabilities: .init(permissionApproval: false, interactiveBubble: false, stateOnly: true),
      installCommand: ["node", "hooks/pi-install.js"],
      uninstallCommand: ["node", "hooks/pi-install.js", "--uninstall"]
    ),
    AgentDescriptor(
      id: "openclaw",
      displayName: "OpenClaw",
      processNames: .init(win: [], mac: [], linux: []),
      capabilities: .init(permissionApproval: false, interactiveBubble: false, terminalFocus: false, stateOnly: true),
      installCommand: ["node", "hooks/openclaw-install.js"],
      uninstallCommand: ["node", "hooks/openclaw-install.js", "--uninstall"]
    ),
    AgentDescriptor(
      id: "hermes",
      displayName: "Hermes Agent",
      processNames: .init(win: ["hermes.exe"], mac: ["hermes"], linux: ["hermes"]),
      capabilities: .init(permissionApproval: true, interactiveBubble: true),
      installCommand: ["node", "hooks/hermes-install.js"],
      uninstallCommand: ["node", "hooks/hermes-install.js", "--uninstall"]
    ),
    AgentDescriptor(
      id: "qoder",
      displayName: "Qoder",
      processNames: .init(win: ["qodercli.exe", "qoder-cli.exe"], mac: ["qodercli", "qoder-cli"], linux: ["qodercli", "qoder-cli"]),
      capabilities: .init(permissionApproval: false, interactiveBubble: false, stateOnly: true),
      installCommand: ["node", "hooks/qoder-install.js"],
      uninstallCommand: ["node", "hooks/qoder-install.js", "--uninstall"]
    )
  ]

  public static let byId: [String: AgentDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  public static func agent(_ id: String) -> AgentDescriptor? {
    byId[id]
  }

  public static func allProcessNames(platform: String = currentPlatform) -> [(name: String, agentId: String)] {
    all.flatMap { agent in
      let names: [String]
      switch platform {
      case "win32":
        names = agent.processNames.win
      case "linux":
        names = agent.processNames.linux.isEmpty ? agent.processNames.mac : agent.processNames.linux
      default:
        names = agent.processNames.mac
      }
      return names.map { ($0, agent.id) }
    }
  }

  public static var currentPlatform: String {
    #if os(Windows)
    return "win32"
    #elseif os(Linux)
    return "linux"
    #else
    return "darwin"
    #endif
  }
}
