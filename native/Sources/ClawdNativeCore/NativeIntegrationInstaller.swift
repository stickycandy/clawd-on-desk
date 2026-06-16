import Foundation
import Dispatch

public struct NativeIntegrationSummary: Equatable, Sendable {
  public var agentId: String
  public var action: String
  public var status: String
  public var message: String
  public var added: Int
  public var updated: Int
  public var skipped: Int
  public var removed: Int
  public var warnings: [String]

  public init(
    agentId: String,
    action: String,
    status: String,
    message: String,
    added: Int = 0,
    updated: Int = 0,
    skipped: Int = 0,
    removed: Int = 0,
    warnings: [String] = []
  ) {
    self.agentId = agentId
    self.action = action
    self.status = status
    self.message = message
    self.added = added
    self.updated = updated
    self.skipped = skipped
    self.removed = removed
    self.warnings = warnings
  }

  public var output: String {
    var parts = [
      message,
      "added=\(added)",
      "updated=\(updated)",
      "skipped=\(skipped)",
      "removed=\(removed)"
    ]
    if !warnings.isEmpty {
      parts.append("warnings=\(warnings.joined(separator: " | "))")
    }
    return parts.joined(separator: "; ")
  }
}

public final class NativeIntegrationInstaller: @unchecked Sendable {
  public static let supportedAgentIds: Set<String> = [
    "claude-code",
    "codebuddy",
    "codex",
    "copilot-cli",
    "cursor-agent",
    "gemini-cli",
    "antigravity-cli",
    "kimi-cli",
    "pi",
    "openclaw",
    "opencode",
    "hermes",
    "kiro-cli",
    "codewhale",
    "qwen-code",
    "qoder",
    "reasonix"
  ]

  private let projectRoot: URL
  private let homeDirectory: URL
  private let environment: [String: String]
  private let fileManager: FileManager

  public init(
    projectRoot: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) {
    self.projectRoot = projectRoot
    self.homeDirectory = homeDirectory
    self.environment = environment
    self.fileManager = fileManager
  }

  public static func supports(_ agentId: String) -> Bool {
    supportedAgentIds.contains(agentId)
  }

  public func install(agentId: String, preferences: Preferences, permissionPort: Int = 23333) -> NativeIntegrationSummary? {
    guard Self.supports(agentId) else { return nil }
    do {
      switch agentId {
      case "claude-code":
        return try installClaude(autoStart: preferences.autoStartWithClaude, permissionPort: permissionPort)
      case "codebuddy":
        return try installCodeBuddy(permissionPort: permissionPort)
      case "codex":
        return try installCodex()
      case "qwen-code":
        return try installQwen()
      case "copilot-cli":
        return try installCopilot()
      case "cursor-agent":
        return try installCursor()
      case "gemini-cli":
        return try installGemini()
      case "antigravity-cli":
        return try installAntigravity()
      case "kimi-cli":
        return try installKimi()
      case "pi":
        return try installPi()
      case "openclaw":
        return try installOpenClaw()
      case "opencode":
        return try installOpencode()
      case "hermes":
        return try installHermes()
      case "kiro-cli":
        return try installKiro()
      case "codewhale":
        return try installCodewhale()
      case "reasonix":
        return try installReasonix()
      case "qoder":
        return try installQoder()
      default:
        return nil
      }
    } catch {
      return NativeIntegrationSummary(
        agentId: agentId,
        action: "install",
        status: "error",
        message: error.localizedDescription
      )
    }
  }

  public func uninstall(agentId: String) -> NativeIntegrationSummary? {
    guard Self.supports(agentId) else { return nil }
    do {
      switch agentId {
      case "claude-code":
        return try uninstallClaude()
      case "codebuddy":
        return try uninstallCodeBuddy()
      case "codex":
        return try uninstallCodex()
      case "qwen-code":
        return try uninstallQwen()
      case "copilot-cli":
        return try uninstallCopilot()
      case "cursor-agent":
        return try uninstallCursor()
      case "gemini-cli":
        return try uninstallGemini()
      case "antigravity-cli":
        return try uninstallAntigravity()
      case "kimi-cli":
        return try uninstallKimi()
      case "pi":
        return try uninstallPi()
      case "openclaw":
        return try uninstallOpenClaw()
      case "opencode":
        return try uninstallOpencode()
      case "hermes":
        return try uninstallHermes()
      case "kiro-cli":
        return try uninstallKiro()
      case "codewhale":
        return try uninstallCodewhale()
      case "reasonix":
        return try uninstallReasonix()
      case "qoder":
        return try uninstallQoder()
      default:
        return nil
      }
    } catch {
      return NativeIntegrationSummary(
        agentId: agentId,
        action: "uninstall",
        status: "error",
        message: error.localizedDescription
      )
    }
  }

  public var nativeStatus: [DiagnosticItem] {
    Self.supportedAgentIds.sorted().map { agentId in
      DiagnosticItem(
        id: "native-installer:\(agentId)",
        status: "ok",
        message: "Swift installer available"
      )
    }
  }

  private func installClaude(autoStart: Bool, permissionPort: Int) throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".claude/settings.json")
    var settings = try readJSONObject(settingsPath)
    var counters = ChangeCounters()
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "clawd-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/clawd-hook.js").path
    let autoStartScript = projectRoot.appendingPathComponent("hooks/auto-start.js").path

    let versioned = supportedClaudeVersionedEvents()
    for event in Self.claudeCoreEvents + versioned.events {
      let desired = commandHook(
        command: hookCommand(agentId: "claude-code", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "clawd-hook.js"),
        timeout: 5,
        async: true
      )
      counters.merge(syncNestedCommandHook(
        settings: &settings,
        event: event,
        marker: "clawd-hook.js",
        desired: desired,
        wrapperMatcher: ""
      ))
    }

    counters.merge(removeCommandHooks(settings: &settings, event: "WorktreeCreate", marker: "clawd-hook.js"))
    counters.merge(removeCommandHooks(settings: &settings, event: "PermissionRequest", marker: "clawd-hook.js"))

    if autoStart {
      let desired = commandHook(
        command: "\(quote(nodeBin)) \(quote(autoStartScript))",
        timeout: 15,
        async: true
      )
      counters.merge(syncNestedCommandHook(
        settings: &settings,
        event: "SessionStart",
        marker: "auto-start.js",
        desired: desired,
        wrapperMatcher: "",
        insertAtFront: true
      ))
      counters.merge(removeCommandHooks(settings: &settings, event: "SessionStart", marker: "auto-start.sh"))
    }

    let permissionHook: [String: Any] = [
      "type": "http",
      "url": "http://127.0.0.1:\(permissionPort)/permission",
      "timeout": 600
    ]
    counters.merge(syncNestedHTTPHook(
      settings: &settings,
      event: "PermissionRequest",
      marker: "/permission",
      desired: permissionHook,
      wrapperMatcher: ""
    ))

    try writeJSONObject(settings, to: settingsPath)
    return NativeIntegrationSummary(
      agentId: "claude-code",
      action: "install",
      status: "ok",
      message: "Swift Claude hooks -> \(settingsPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed,
      warnings: versioned.warning.map { [$0] } ?? []
    )
  }

  private func uninstallClaude() throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".claude/settings.json")
    var settings = try readJSONObject(settingsPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    let versionedEvents = Self.claudeVersionedHooks.map(\.event)
    for event in Self.claudeCoreEvents + versionedEvents + ["PermissionRequest", "SessionStart", "WorktreeCreate"] {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "clawd-hook.js"))
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "auto-start.js"))
      counters.merge(removeHTTPHooks(settings: &settings, event: event, marker: "/permission"))
    }
    try writeJSONObject(settings, to: settingsPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "claude-code",
      action: "uninstall",
      status: "ok",
      message: "Swift Claude hooks removed from \(settingsPath.path)",
      removed: counters.removed
    )
  }

  private func installCodeBuddy(permissionPort: Int) throws -> NativeIntegrationSummary {
    let codeBuddyDir = homeDirectory.appendingPathComponent(".codebuddy", isDirectory: true)
    guard fileManager.fileExists(atPath: codeBuddyDir.path) else {
      return .init(agentId: "codebuddy", action: "install", status: "skip", message: "\(codeBuddyDir.path) not found")
    }
    let settingsPath = codeBuddyDir.appendingPathComponent("settings.json")
    var settings = try readJSONObject(settingsPath)
    var counters = ChangeCounters()
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "codebuddy-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/codebuddy-hook.js").path

    for event in Self.codeBuddyEvents {
      let desired = commandHook(
        command: hookCommand(agentId: "codebuddy", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "codebuddy-hook.js"),
        timeout: 30
      )
      counters.merge(syncNestedCommandHook(
        settings: &settings,
        event: event,
        marker: "codebuddy-hook.js",
        desired: desired,
        wrapperMatcher: ""
      ))
    }

    let permissionHook: [String: Any] = [
      "type": "http",
      "url": "http://127.0.0.1:\(permissionPort)/permission",
      "timeout": 600
    ]
    counters.merge(syncNestedHTTPHook(
      settings: &settings,
      event: "PermissionRequest",
      marker: "127.0.0.1:",
      desired: permissionHook,
      wrapperMatcher: "",
      replaceAnyHTTP: false
    ))

    try writeJSONObject(settings, to: settingsPath)
    return NativeIntegrationSummary(
      agentId: "codebuddy",
      action: "install",
      status: "ok",
      message: "Swift CodeBuddy hooks -> \(settingsPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed
    )
  }

  private func uninstallCodeBuddy() throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".codebuddy/settings.json")
    var settings = try readJSONObject(settingsPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.codeBuddyEvents {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "codebuddy-hook.js"))
    }
    counters.merge(removeCodeBuddyPermissionHooks(settings: &settings))
    try writeJSONObject(settings, to: settingsPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "codebuddy",
      action: "uninstall",
      status: "ok",
      message: "Swift CodeBuddy hooks removed from \(settingsPath.path)",
      removed: counters.removed
    )
  }

  private func installCodex() throws -> NativeIntegrationSummary {
    let codexDir = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    guard fileManager.fileExists(atPath: codexDir.path) else {
      return .init(agentId: "codex", action: "install", status: "skip", message: "\(codexDir.path) not found")
    }
    let hooksPath = codexDir.appendingPathComponent("hooks.json")
    let configPath = codexDir.appendingPathComponent("config.toml")
    var settings = try readJSONObject(hooksPath)
    var counters = ChangeCounters()
    let feature = try ensureCodexHooksFeature(configPath)
    if feature.changed { counters.updated += 1 }
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "codex-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/codex-hook.js").path
    for event in Self.codexEvents {
      let desiredCommand = hookCommand(agentId: "codex", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "codex-hook.js")
      let desired = commandHook(command: desiredCommand, timeout: event == "PermissionRequest" ? 600 : 30)
      counters.merge(syncNestedCommandHook(
        settings: &settings,
        event: event,
        marker: "codex-hook.js",
        desired: desired,
        wrapperMatcher: nil
      ))
    }
    try writeJSONObject(settings, to: hooksPath)
    return NativeIntegrationSummary(
      agentId: "codex",
      action: "install",
      status: "ok",
      message: "Swift Codex hooks -> \(hooksPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      warnings: feature.warning.map { [$0] } ?? []
    )
  }

  private func uninstallCodex() throws -> NativeIntegrationSummary {
    let hooksPath = homeDirectory.appendingPathComponent(".codex/hooks.json")
    var settings = try readJSONObject(hooksPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.codexEvents {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "codex-hook.js"))
    }
    try writeJSONObject(settings, to: hooksPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "codex",
      action: "uninstall",
      status: "ok",
      message: "Swift Codex hooks removed from \(hooksPath.path)",
      removed: counters.removed
    )
  }

  private func installQwen() throws -> NativeIntegrationSummary {
    let qwenDir = homeDirectory.appendingPathComponent(".qwen", isDirectory: true)
    guard fileManager.fileExists(atPath: qwenDir.path) else {
      return .init(agentId: "qwen-code", action: "install", status: "skip", message: "\(qwenDir.path) not found")
    }
    let settingsPath = qwenDir.appendingPathComponent("settings.json")
    var settings = try readJSONObject(settingsPath)
    var counters = ChangeCounters()
    var warnings: [String] = []
    if settings["disableAllHooks"] as? Bool == true {
      warnings.append("settings.json has disableAllHooks=true; Qwen hooks will not fire until removed.")
    }
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "qwen-code-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/qwen-code-hook.js").path

    for event in Self.qwenEvents {
      var wrapper: [String: Any] = [
        "hooks": [[
          "name": "clawd",
          "type": "command",
          "command": hookCommand(agentId: "qwen-code", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "qwen-code-hook.js"),
          "timeout": event == "PermissionRequest" ? 600_000 : 30_000
        ]]
      ]
      if !Self.qwenMatcherlessEvents.contains(event) {
        wrapper["matcher"] = "*"
      }
      counters.merge(syncWholeHookEntry(
        settings: &settings,
        event: event,
        marker: "qwen-code-hook.js",
        desiredEntry: wrapper
      ))
    }
    try writeJSONObject(settings, to: settingsPath)
    return NativeIntegrationSummary(
      agentId: "qwen-code",
      action: "install",
      status: "ok",
      message: "Swift Qwen hooks -> \(settingsPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      warnings: warnings
    )
  }

  private func uninstallQwen() throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".qwen/settings.json")
    var settings = try readJSONObject(settingsPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.qwenEvents {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "qwen-code-hook.js"))
    }
    try writeJSONObject(settings, to: settingsPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "qwen-code",
      action: "uninstall",
      status: "ok",
      message: "Swift Qwen hooks removed from \(settingsPath.path)",
      removed: counters.removed
    )
  }

  private func installGemini() throws -> NativeIntegrationSummary {
    let geminiDir = homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
    guard fileManager.fileExists(atPath: geminiDir.path) else {
      return .init(agentId: "gemini-cli", action: "install", status: "skip", message: "\(geminiDir.path) not found")
    }
    let settingsPath = geminiDir.appendingPathComponent("settings.json")
    var settings = try readJSONObject(settingsPath)
    var counters = ChangeCounters()
    if normalizeGeminiDisabledHooks(settings: &settings) {
      counters.updated += 1
    }
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "gemini-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/gemini-hook.js").path

    for event in Self.geminiEvents {
      let desiredEntry: [String: Any] = [
        "matcher": "*",
        "hooks": [[
          "name": "clawd",
          "type": "command",
          "command": hookCommand(agentId: "gemini-cli", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "gemini-hook.js")
        ]]
      ]
      counters.merge(syncDedicatedNestedHookEntry(
        settings: &settings,
        event: event,
        marker: "gemini-hook.js",
        desiredEntry: desiredEntry
      ))
    }
    try writeJSONObject(settings, to: settingsPath)
    return NativeIntegrationSummary(
      agentId: "gemini-cli",
      action: "install",
      status: "ok",
      message: "Swift Gemini hooks -> \(settingsPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed
    )
  }

  private func uninstallGemini() throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".gemini/settings.json")
    var settings = try readJSONObject(settingsPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.geminiEvents {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "gemini-hook.js"))
    }
    try writeJSONObject(settings, to: settingsPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "gemini-cli",
      action: "uninstall",
      status: "ok",
      message: "Swift Gemini hooks removed from \(settingsPath.path)",
      removed: counters.removed
    )
  }

  private func installAntigravity() throws -> NativeIntegrationSummary {
    let configDir = homeDirectory.appendingPathComponent(".gemini/config", isDirectory: true)
    guard fileManager.fileExists(atPath: configDir.path) else {
      return .init(agentId: "antigravity-cli", action: "install", status: "skip", message: "\(configDir.path) not found")
    }
    let hooksPath = configDir.appendingPathComponent("hooks.json")
    var settings = try readJSONObject(hooksPath)
    let existingGroup = settings["clawd"] as? [String: Any]
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "antigravity-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/antigravity-hook.js").path
    var desiredGroup = antigravityHookGroup(nodeBin: nodeBin, hookScript: hookScript)
    if existingGroup?["enabled"] as? Bool == false {
      desiredGroup["enabled"] = false
    }

    var counters = ChangeCounters()
    for event in Self.antigravityEvents {
      guard let desired = desiredGroup[event] else { continue }
      if existingGroup == nil || existingGroup?[event] == nil {
        counters.added += 1
      } else if !jsonValueEquals(existingGroup?[event], desired) {
        counters.updated += 1
      } else {
        counters.skipped += 1
      }
    }

    if existingGroup == nil || !jsonValueEquals(existingGroup, desiredGroup) {
      settings["clawd"] = desiredGroup
      try writeJSONObject(settings, to: hooksPath)
    }

    return NativeIntegrationSummary(
      agentId: "antigravity-cli",
      action: "install",
      status: "ok",
      message: "Swift Antigravity hooks -> \(hooksPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped
    )
  }

  private func uninstallAntigravity() throws -> NativeIntegrationSummary {
    let hooksPath = homeDirectory.appendingPathComponent(".gemini/config/hooks.json")
    var settings = try readJSONObject(hooksPath, missingIsEmpty: false)
    guard let group = settings["clawd"], containsMarker(group, marker: "antigravity-hook.js") else {
      return NativeIntegrationSummary(
        agentId: "antigravity-cli",
        action: "uninstall",
        status: "ok",
        message: "Swift Antigravity hooks not found in \(hooksPath.path)"
      )
    }
    settings.removeValue(forKey: "clawd")
    try writeJSONObject(settings, to: hooksPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "antigravity-cli",
      action: "uninstall",
      status: "ok",
      message: "Swift Antigravity hooks removed from \(hooksPath.path)",
      removed: 1
    )
  }

  private func installKimi() throws -> NativeIntegrationSummary {
    let configPath = homeDirectory.appendingPathComponent(".kimi/config.toml")
    let kimiDir = configPath.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: kimiDir.path) else {
      return .init(agentId: "kimi-cli", action: "install", status: "skip", message: "\(kimiDir.path) not found")
    }
    let original = (try? String(contentsOf: configPath, encoding: .utf8)) ?? "default_model = \"kimi-for-coding\"\n"
    let stripped = stripKimiHookBlocks(from: original)
    let base = removeKimiEmptyHooksArray(from: stripped.content)
    let nodeBin = resolveNodeBin(existingSettings: ["content": original], marker: "kimi-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/kimi-hook.js").path
    let mode = normalizeKimiPermissionMode(environment["CLAWD_KIMI_PERMISSION_MODE"]) ?? extractExistingKimiPermissionMode(from: original)
    let modePrefix = mode.map { "CLAWD_KIMI_PERMISSION_MODE=\($0) " } ?? ""
    let hookBlocks = Self.kimiEvents.map { event in
      kimiHookBlock(
        event: event,
        command: "\(modePrefix)\(hookCommand(agentId: "kimi-cli", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "kimi-hook.js"))"
      )
    }.joined(separator: "\n")
    let next = trimTrailingWhitespace(base) + "\n\n" + hookBlocks

    var counters = ChangeCounters()
    if stripped.removed == 0 {
      counters.added = Self.kimiEvents.count
    } else if next == original {
      counters.skipped = 1
    } else {
      counters.updated = 1
    }

    if next != original {
      try writeText(next, to: configPath)
    }
    return NativeIntegrationSummary(
      agentId: "kimi-cli",
      action: "install",
      status: "ok",
      message: "Swift Kimi hooks -> \(configPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: stripped.removed
    )
  }

  private func uninstallKimi() throws -> NativeIntegrationSummary {
    let configPath = homeDirectory.appendingPathComponent(".kimi/config.toml")
    let original = try String(contentsOf: configPath, encoding: .utf8)
    let stripped = stripKimiHookBlocks(from: original)
    if stripped.content != original {
      try writeText(stripped.content, to: configPath)
    }
    return NativeIntegrationSummary(
      agentId: "kimi-cli",
      action: "uninstall",
      status: "ok",
      message: "Swift Kimi hooks removed from \(configPath.path)",
      removed: stripped.removed
    )
  }

  private func installPi() throws -> NativeIntegrationSummary {
    let parentDir = homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
    guard fileManager.fileExists(atPath: parentDir.path) || commandExistsOnPath("pi") else {
      return .init(agentId: "pi", action: "install", status: "skip", message: "Pi not found")
    }
    let extensionDir = parentDir.appendingPathComponent("extensions/clawd-on-desk", isDirectory: true)
    let markerPath = extensionDir.appendingPathComponent(".clawd-managed.json")
    if fileManager.fileExists(atPath: extensionDir.path), !isManagedPiMarker(markerPath) {
      return .init(agentId: "pi", action: "install", status: "skip", message: "\(extensionDir.path) exists but is not Clawd-managed")
    }

    let sourceExtension = projectRoot.appendingPathComponent("hooks/pi-extension.ts")
    let sourceCore = projectRoot.appendingPathComponent("hooks/pi-extension-core.js")
    let extensionText = try String(contentsOf: sourceExtension, encoding: .utf8)
    let coreText = try String(contentsOf: sourceCore, encoding: .utf8)
    let targetExtension = extensionDir.appendingPathComponent("index.ts")
    let targetCore = extensionDir.appendingPathComponent("pi-extension-core.js")
    let existed = fileManager.fileExists(atPath: extensionDir.path)
    let updated = (try? String(contentsOf: targetExtension, encoding: .utf8)) != extensionText
      || (try? String(contentsOf: targetCore, encoding: .utf8)) != coreText

    try writeText(extensionText, to: targetExtension)
    try writeText(coreText, to: targetCore)
    try writeJSONObject(piMarker(), to: markerPath)
    return NativeIntegrationSummary(
      agentId: "pi",
      action: "install",
      status: "ok",
      message: "Swift Pi extension -> \(extensionDir.path)",
      added: existed ? 0 : 1,
      updated: updated ? 1 : 0,
      skipped: updated ? 0 : 1
    )
  }

  private func uninstallPi() throws -> NativeIntegrationSummary {
    let extensionDir = homeDirectory.appendingPathComponent(".pi/agent/extensions/clawd-on-desk", isDirectory: true)
    let markerPath = extensionDir.appendingPathComponent(".clawd-managed.json")
    guard fileManager.fileExists(atPath: extensionDir.path) else {
      return .init(agentId: "pi", action: "uninstall", status: "ok", message: "Swift Pi extension not installed", skipped: 1)
    }
    guard isManagedPiMarker(markerPath) else {
      return .init(agentId: "pi", action: "uninstall", status: "skip", message: "\(extensionDir.path) is not Clawd-managed")
    }
    try fileManager.removeItem(at: extensionDir)
    return NativeIntegrationSummary(
      agentId: "pi",
      action: "uninstall",
      status: "ok",
      message: "Swift Pi extension removed from \(extensionDir.path)",
      removed: 1
    )
  }

  private func installOpenClaw() throws -> NativeIntegrationSummary {
    let paths = resolveOpenClawPaths()
    let pluginDir = projectRoot.appendingPathComponent("hooks/openclaw-plugin", isDirectory: true).path
    let stateDirExists = fileManager.fileExists(atPath: paths.stateDir.path)
    let configExists = fileManager.fileExists(atPath: paths.configPath.path)
    guard stateDirExists || configExists else {
      return .init(agentId: "openclaw", action: "install", status: "skip", message: "OpenClaw not found")
    }
    guard configExists else {
      return .init(agentId: "openclaw", action: "install", status: "skip", message: "\(paths.configPath.path) missing")
    }
    var config = try readJSONObject(paths.configPath, missingIsEmpty: false)
    let linked = ensureOpenClawConfigLinked(config: &config, pluginDir: pluginDir)
    if let reason = linked.reason {
      return .init(agentId: "openclaw", action: "install", status: "skip", message: reason)
    }
    if linked.updated {
      try writeJSONObject(config, to: paths.configPath)
    }
    return NativeIntegrationSummary(
      agentId: "openclaw",
      action: "install",
      status: "ok",
      message: "Swift OpenClaw plugin -> \(paths.configPath.path)",
      added: linked.updated ? 1 : 0,
      skipped: linked.updated ? 0 : 1
    )
  }

  private func uninstallOpenClaw() throws -> NativeIntegrationSummary {
    let paths = resolveOpenClawPaths()
    let pluginDir = projectRoot.appendingPathComponent("hooks/openclaw-plugin", isDirectory: true).path
    guard fileManager.fileExists(atPath: paths.configPath.path) else {
      return .init(agentId: "openclaw", action: "uninstall", status: "ok", message: "\(paths.configPath.path) missing", skipped: 1)
    }
    var config = try readJSONObject(paths.configPath, missingIsEmpty: false)
    guard !hasOpenClawIncludeDirective(config) else {
      return .init(agentId: "openclaw", action: "uninstall", status: "skip", message: "config-has-include")
    }
    let removed = removeOpenClawConfigLink(config: &config, pluginDir: pluginDir)
    if removed {
      try writeJSONObject(config, to: paths.configPath, backup: true)
    }
    return NativeIntegrationSummary(
      agentId: "openclaw",
      action: "uninstall",
      status: "ok",
      message: "Swift OpenClaw plugin removed from \(paths.configPath.path)",
      skipped: removed ? 0 : 1,
      removed: removed ? 1 : 0
    )
  }

  private func installOpencode() throws -> NativeIntegrationSummary {
    let configDir = homeDirectory.appendingPathComponent(".config/opencode", isDirectory: true)
    let configPath = configDir.appendingPathComponent("opencode.json")
    let pluginDir = projectRoot.appendingPathComponent("hooks/opencode-plugin", isDirectory: true).path
    guard fileManager.fileExists(atPath: configDir.path) else {
      return .init(agentId: "opencode", action: "install", status: "skip", message: "\(configDir.path) not found")
    }

    var settings: [String: Any]
    var created = false
    if fileManager.fileExists(atPath: configPath.path) {
      settings = try readJSONObject(configPath, missingIsEmpty: false)
    } else {
      settings = ["$schema": "https://opencode.ai/config.json"]
      created = true
    }
    var plugins = settings["plugin"] as? [Any] ?? []
    let index = opencodePluginIndex(plugins, pluginDir: pluginDir)
    let changed: Bool
    if let index {
      if plugins[index] as? String == pluginDir {
        changed = false
      } else {
        plugins[index] = pluginDir
        changed = true
      }
    } else {
      plugins.append(pluginDir)
      changed = true
    }
    settings["plugin"] = plugins
    if changed || created {
      try writeJSONObject(settings, to: configPath)
    }
    return NativeIntegrationSummary(
      agentId: "opencode",
      action: "install",
      status: "ok",
      message: "Swift opencode plugin -> \(configPath.path)",
      added: changed ? 1 : 0,
      skipped: changed ? 0 : 1
    )
  }

  private func uninstallOpencode() throws -> NativeIntegrationSummary {
    let configPath = homeDirectory.appendingPathComponent(".config/opencode/opencode.json")
    let pluginDir = projectRoot.appendingPathComponent("hooks/opencode-plugin", isDirectory: true).path
    var settings = try readJSONObject(configPath, missingIsEmpty: false)
    guard var plugins = settings["plugin"] as? [Any] else {
      return .init(agentId: "opencode", action: "uninstall", status: "ok", message: "Swift opencode plugin not installed", skipped: 1)
    }
    let before = plugins.count
    let normalizedPluginDir = normalizeOpenClawPath(pluginDir)
    plugins = plugins.filter { entry in
      guard let string = entry as? String else { return true }
      return normalizeOpenClawPath(string) != normalizedPluginDir
    }
    let removed = before - plugins.count
    if removed > 0 {
      settings["plugin"] = plugins
      try writeJSONObject(settings, to: configPath, backup: true)
    }
    return NativeIntegrationSummary(
      agentId: "opencode",
      action: "uninstall",
      status: "ok",
      message: "Swift opencode plugin removed from \(configPath.path)",
      skipped: removed > 0 ? 0 : 1,
      removed: removed
    )
  }

  private func installHermes() throws -> NativeIntegrationSummary {
    guard isHermesInstalled() else {
      return .init(agentId: "hermes", action: "install", status: "skip", message: "Hermes Agent is not installed; skipped plugin sync")
    }

    let hermesHome = resolveHermesHome()
    let syncHomes = hermesHomesForSync(hermesHome)
    let primaryCommand = resolveHermesCommand(hermesHome: hermesHome)
    var counters = ChangeCounters()
    var warnings: [String] = []
    var primaryError: String?

    for targetHome in syncHomes {
      let pluginDir = targetHome.appendingPathComponent("plugins/clawd-on-desk", isDirectory: true)
      counters.merge(try copyManagedHermesPluginFiles(to: pluginDir))

      let enable = runHermesCli(
        args: ["plugins", "enable", "clawd-on-desk"],
        hermesHome: targetHome,
        hermesCommand: primaryCommand
      )
      guard !enable.ok else { continue }

      let command = formatHermesCommand(primaryCommand, ["plugins", "enable", "clawd-on-desk"])
      let message = enable.unavailable
        ? "Hermes plugin files were installed, but Hermes CLI was not found. Run: \(command)"
        : "Hermes plugin files were installed, but enabling failed: \(enable.message)"
      if targetHome.standardizedFileURL.path == hermesHome.standardizedFileURL.path {
        primaryError = message
      } else {
        warnings.append(message)
      }
    }

    if let primaryError {
      return NativeIntegrationSummary(
        agentId: "hermes",
        action: "install",
        status: "error",
        message: primaryError,
        added: counters.added,
        updated: counters.updated,
        skipped: counters.skipped,
        warnings: warnings
      )
    }

    return NativeIntegrationSummary(
      agentId: "hermes",
      action: "install",
      status: "ok",
      message: counters.added > 0 || counters.updated > 0 ? "Swift Hermes plugin installed" : "Swift Hermes plugin already installed",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      warnings: warnings
    )
  }

  private func uninstallHermes() throws -> NativeIntegrationSummary {
    let hermesHome = resolveHermesHome()
    let pluginDir = hermesHome.appendingPathComponent("plugins/clawd-on-desk", isDirectory: true)
    let command = resolveHermesCommand(hermesHome: hermesHome)
    let disable = runHermesCli(args: ["plugins", "disable", "clawd-on-desk"], hermesHome: hermesHome, hermesCommand: command)
    var warnings: [String] = []
    if !disable.ok {
      let display = formatHermesCommand(command, ["plugins", "disable", "clawd-on-desk"])
      warnings.append(
        disable.unavailable
          ? "Hermes CLI was not found; skipped disable. If Hermes keeps a stale enabled entry, run: \(display)"
          : "Hermes CLI disable failed: \(disable.message)"
      )
    }

    var removed = 0
    if fileManager.fileExists(atPath: pluginDir.path) {
      try fileManager.removeItem(at: pluginDir)
      removed = 1
    }
    return NativeIntegrationSummary(
      agentId: "hermes",
      action: "uninstall",
      status: "ok",
      message: warnings.isEmpty ? "Swift Hermes plugin removed" : "Swift Hermes plugin removed with warnings",
      skipped: removed == 0 ? 1 : 0,
      removed: removed,
      warnings: warnings
    )
  }

  private func installCursor() throws -> NativeIntegrationSummary {
    let cursorDir = homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
    guard fileManager.fileExists(atPath: cursorDir.path) else {
      return .init(agentId: "cursor-agent", action: "install", status: "skip", message: "\(cursorDir.path) not found")
    }
    let hooksPath = cursorDir.appendingPathComponent("hooks.json")
    var settings = try readJSONObject(hooksPath)
    if settings["version"] == nil { settings["version"] = 1 }
    var counters = ChangeCounters()
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "cursor-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/cursor-hook.js").path
    for event in Self.cursorEvents {
      let desiredEntry = [
        "command": hookCommand(agentId: "cursor-agent", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "cursor-hook.js")
      ]
      counters.merge(syncWholeHookEntry(
        settings: &settings,
        event: event,
        marker: "cursor-hook.js",
        desiredEntry: desiredEntry
      ))
    }
    try writeJSONObject(settings, to: hooksPath)
    return NativeIntegrationSummary(
      agentId: "cursor-agent",
      action: "install",
      status: "ok",
      message: "Swift Cursor hooks -> \(hooksPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed
    )
  }

  private func uninstallCursor() throws -> NativeIntegrationSummary {
    let hooksPath = homeDirectory.appendingPathComponent(".cursor/hooks.json")
    var settings = try readJSONObject(hooksPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.cursorEvents {
      counters.merge(removeWholeHookEntries(settings: &settings, event: event, marker: "cursor-hook.js"))
    }
    try writeJSONObject(settings, to: hooksPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "cursor-agent",
      action: "uninstall",
      status: "ok",
      message: "Swift Cursor hooks removed from \(hooksPath.path)",
      removed: counters.removed
    )
  }

  private func installKiro() throws -> NativeIntegrationSummary {
    let agentsDir = homeDirectory.appendingPathComponent(".kiro/agents", isDirectory: true)
    guard fileManager.fileExists(atPath: agentsDir.path) else {
      return .init(agentId: "kiro-cli", action: "install", status: "skip", message: "\(agentsDir.path) not found")
    }
    var counters = ChangeCounters()
    var processed = 0
    for url in try kiroAgentConfigFiles(in: agentsDir) {
      if url.lastPathComponent == "clawd.json" { continue }
      let result = try syncKiroAgentFile(url)
      counters.merge(result)
      processed += 1
    }
    let clawdURL = agentsDir.appendingPathComponent("clawd.json")
    let clawdResult = try syncKiroAgentFile(clawdURL, createMinimal: true)
    counters.merge(clawdResult)
    processed += 1
    return NativeIntegrationSummary(
      agentId: "kiro-cli",
      action: "install",
      status: "ok",
      message: "Swift Kiro hooks -> \(agentsDir.path) (\(processed) agent config(s))",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed
    )
  }

  private func uninstallKiro() throws -> NativeIntegrationSummary {
    let agentsDir = homeDirectory.appendingPathComponent(".kiro/agents", isDirectory: true)
    guard fileManager.fileExists(atPath: agentsDir.path) else {
      return .init(agentId: "kiro-cli", action: "uninstall", status: "ok", message: "\(agentsDir.path) not found")
    }
    var counters = ChangeCounters()
    for url in try kiroAgentConfigFiles(in: agentsDir) {
      var settings = try readJSONObject(url, missingIsEmpty: false)
      var fileCounters = ChangeCounters()
      for event in Self.kiroEvents {
        fileCounters.merge(removeWholeHookEntries(settings: &settings, event: event, marker: "kiro-hook.js"))
      }
      if fileCounters.removed > 0 {
        try writeJSONObject(settings, to: url, backup: true)
      }
      counters.merge(fileCounters)
    }
    return NativeIntegrationSummary(
      agentId: "kiro-cli",
      action: "uninstall",
      status: "ok",
      message: "Swift Kiro hooks removed from \(agentsDir.path)",
      removed: counters.removed
    )
  }

  private func installCodewhale() throws -> NativeIntegrationSummary {
    let resolved = resolveCodewhaleConfigPath()
    let configPath = resolved.url
    let configDir = configPath.deletingLastPathComponent()
    guard resolved.explicit || fileManager.fileExists(atPath: configDir.path) else {
      return .init(agentId: "codewhale", action: "install", status: "skip", message: "\(configDir.path) not found")
    }
    let original = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
    let nodeBin = resolveNodeBin(existingSettings: ["content": original], marker: "codewhale-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/codewhale-hook.js").path
    let result = buildCodewhaleConfig(original: original, nodeBin: nodeBin, hookScript: hookScript)
    if result.text != original {
      try writeText(result.text, to: configPath)
    }
    return NativeIntegrationSummary(
      agentId: "codewhale",
      action: "install",
      status: "ok",
      message: "Swift CodeWhale hooks -> \(configPath.path)",
      added: result.counters.added,
      updated: result.counters.updated,
      skipped: result.counters.skipped,
      removed: result.counters.removed
    )
  }

  private func uninstallCodewhale() throws -> NativeIntegrationSummary {
    let configPath = resolveCodewhaleConfigPath().url
    guard let original = try? String(contentsOf: configPath, encoding: .utf8) else {
      return NativeIntegrationSummary(
        agentId: "codewhale",
        action: "uninstall",
        status: "ok",
        message: "Swift CodeWhale config not found: \(configPath.path)"
      )
    }
    let stripped = removeCodewhaleManagedHookSections(from: original)
    if stripped.removed > 0 {
      try writeText(stripped.text, to: configPath)
    }
    return NativeIntegrationSummary(
      agentId: "codewhale",
      action: "uninstall",
      status: "ok",
      message: "Swift CodeWhale hooks removed from \(configPath.path)",
      removed: stripped.removed
    )
  }

  private func installQoder() throws -> NativeIntegrationSummary {
    let qoderDir = homeDirectory.appendingPathComponent(".qoder", isDirectory: true)
    guard fileManager.fileExists(atPath: qoderDir.path) else {
      return .init(agentId: "qoder", action: "install", status: "skip", message: "\(qoderDir.path) not found")
    }
    let settingsPath = qoderDir.appendingPathComponent("settings.json")
    var settings = try readJSONObject(settingsPath)
    var counters = ChangeCounters()
    if normalizeCommandDisabledHooks(settings: &settings, marker: "qoder-hook.js") {
      counters.updated += 1
    }
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "qoder-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/qoder-hook.js").path

    for event in Self.qoderEvents {
      let desiredEntry: [String: Any] = [
        "matcher": "*",
        "hooks": [[
          "name": "clawd",
          "type": "command",
          "command": hookCommand(agentId: "qoder", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "qoder-hook.js")
        ]]
      ]
      counters.merge(syncDedicatedNestedHookEntry(
        settings: &settings,
        event: event,
        marker: "qoder-hook.js",
        desiredEntry: desiredEntry
      ))
    }
    try writeJSONObject(settings, to: settingsPath)
    return NativeIntegrationSummary(
      agentId: "qoder",
      action: "install",
      status: "ok",
      message: "Swift Qoder hooks -> \(settingsPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed
    )
  }

  private func uninstallQoder() throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".qoder/settings.json")
    var settings = try readJSONObject(settingsPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.qoderEvents {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "qoder-hook.js"))
    }
    try writeJSONObject(settings, to: settingsPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "qoder",
      action: "uninstall",
      status: "ok",
      message: "Swift Qoder hooks removed from \(settingsPath.path)",
      removed: counters.removed
    )
  }

  private func installReasonix() throws -> NativeIntegrationSummary {
    let reasonixDir = homeDirectory.appendingPathComponent(".reasonix", isDirectory: true)
    guard fileManager.fileExists(atPath: reasonixDir.path) else {
      return .init(agentId: "reasonix", action: "install", status: "skip", message: "\(reasonixDir.path) not found")
    }
    let settingsPath = reasonixDir.appendingPathComponent("settings.json")
    var settings = try readJSONObject(settingsPath)
    var counters = ChangeCounters()
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "reasonix-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/reasonix-hook.js").path

    for event in Self.reasonixEvents {
      let desiredEntry: [String: Any] = [
        "match": "*",
        "command": hookCommand(agentId: "reasonix", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "reasonix-hook.js")
      ]
      counters.merge(syncWholeHookEntry(
        settings: &settings,
        event: event,
        marker: "reasonix-hook.js",
        desiredEntry: desiredEntry
      ))
    }
    try writeJSONObject(settings, to: settingsPath)
    return NativeIntegrationSummary(
      agentId: "reasonix",
      action: "install",
      status: "ok",
      message: "Swift Reasonix hooks -> \(settingsPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed
    )
  }

  private func uninstallReasonix() throws -> NativeIntegrationSummary {
    let settingsPath = homeDirectory.appendingPathComponent(".reasonix/settings.json")
    var settings = try readJSONObject(settingsPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.reasonixEvents {
      counters.merge(removeCommandHooks(settings: &settings, event: event, marker: "reasonix-hook.js"))
    }
    try writeJSONObject(settings, to: settingsPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "reasonix",
      action: "uninstall",
      status: "ok",
      message: "Swift Reasonix hooks removed from \(settingsPath.path)",
      removed: counters.removed
    )
  }

  private func installCopilot() throws -> NativeIntegrationSummary {
    let copilotDir = resolveCopilotHome()
    guard fileManager.fileExists(atPath: copilotDir.path) else {
      return .init(agentId: "copilot-cli", action: "install", status: "skip", message: "\(copilotDir.path) not found")
    }
    let hooksPath = copilotDir.appendingPathComponent("hooks/hooks.json")
    let settingsPath = copilotDir.appendingPathComponent("settings.json")
    var settings = try readJSONObject(hooksPath)
    if settings["version"] == nil { settings["version"] = 1 }
    var counters = ChangeCounters()
    var warnings: [String] = []
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "copilot-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/copilot-hook.js").path
    let hasExternalPermissionHook = hasCopilotPermissionHookOutsideManagedFile(hooksPath: hooksPath, settingsPath: settingsPath)

    for event in Self.copilotEvents {
      let desired = copilotEntry(
        nodeBin: nodeBin,
        hookScript: hookScript,
        event: event,
        command: hookCommand(agentId: "copilot-cli", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "copilot-hook.js")
      )
      if event == "permissionRequest", hasExternalPermissionHook || copilotPermissionArrayHasUserEntry(settings: settings) {
        counters.merge(removeWholeHookEntries(settings: &settings, event: event, marker: "copilot-hook.js"))
        counters.skipped += 1
        warnings.append("permissionRequest left untouched because a user hook is already registered.")
        continue
      }
      counters.merge(syncWholeHookEntry(
        settings: &settings,
        event: event,
        marker: "copilot-hook.js",
        desiredEntry: desired
      ))
    }
    try writeJSONObject(settings, to: hooksPath)
    return NativeIntegrationSummary(
      agentId: "copilot-cli",
      action: "install",
      status: "ok",
      message: "Swift Copilot hooks -> \(hooksPath.path)",
      added: counters.added,
      updated: counters.updated,
      skipped: counters.skipped,
      removed: counters.removed,
      warnings: Array(Set(warnings)).sorted()
    )
  }

  private func uninstallCopilot() throws -> NativeIntegrationSummary {
    let hooksPath = resolveCopilotHome().appendingPathComponent("hooks/hooks.json")
    var settings = try readJSONObject(hooksPath, missingIsEmpty: false)
    var counters = ChangeCounters()
    for event in Self.copilotEvents {
      counters.merge(removeWholeHookEntries(settings: &settings, event: event, marker: "copilot-hook.js"))
    }
    try writeJSONObject(settings, to: hooksPath, backup: true)
    return NativeIntegrationSummary(
      agentId: "copilot-cli",
      action: "uninstall",
      status: "ok",
      message: "Swift Copilot hooks removed from \(hooksPath.path)",
      removed: counters.removed
    )
  }

  private func readJSONObject(_ url: URL, missingIsEmpty: Bool = true) throws -> [String: Any] {
    do {
      let data = try Data(contentsOf: url)
      guard !data.isEmpty else { return [:] }
      let object = try JSONSerialization.jsonObject(with: data)
      return object as? [String: Any] ?? [:]
    } catch CocoaError.fileReadNoSuchFile {
      if missingIsEmpty { return [:] }
      throw CocoaError(.fileReadNoSuchFile)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      if missingIsEmpty { return [:] }
      throw error
    }
  }

  private func writeJSONObject(_ object: [String: Any], to url: URL, backup: Bool = false) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if backup, fileManager.fileExists(atPath: url.path) {
      let backupURL = url.deletingPathExtension().appendingPathExtension("json.bak")
      try? fileManager.removeItem(at: backupURL)
      try fileManager.copyItem(at: url, to: backupURL)
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    let temp = url.deletingPathExtension().appendingPathExtension("tmp")
    try data.write(to: temp, options: .atomic)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    try fileManager.moveItem(at: temp, to: url)
  }

  private func commandHook(command: String, timeout: Int, async: Bool? = nil) -> [String: Any] {
    var hook: [String: Any] = [
      "type": "command",
      "command": command,
      "timeout": timeout
    ]
    if let async {
      hook["async"] = async
    }
    return hook
  }

  private func copilotEntry(nodeBin: String, hookScript: String, event: String, command explicitCommand: String? = nil) -> [String: Any] {
    let command = explicitCommand ?? "\(quote(nodeBin)) \(quote(hookScript)) \(quote(event))"
    return [
      "type": "command",
      "bash": command,
      "powershell": "& \(command)",
      "timeoutSec": event == "permissionRequest" ? 600 : 5
    ]
  }

  private func hookCommand(agentId: String, event: String, nodeBin: String, scriptPath: String, marker: String) -> String {
    if let nativeHook = resolveNativeHookBinary() {
      return "\(quote(nativeHook)) \(quote(agentId)) \(quote(event)) --marker \(quote(marker))"
    }
    return "\(quote(nodeBin)) \(quote(scriptPath)) \(quote(event))"
  }

  private func antigravityHookGroup(nodeBin: String, hookScript: String) -> [String: Any] {
    var group: [String: Any] = [:]
    for event in Self.antigravityEvents {
      let rawCommand = hookCommand(
        agentId: "antigravity-cli",
        event: event,
        nodeBin: nodeBin,
        scriptPath: hookScript,
        marker: "antigravity-hook.js"
      )
      let hook = commandHook(command: antigravityFailOpenCommand(rawCommand, event: event, nodeBin: nodeBin), timeout: 10)
      if event == "PostToolUse" {
        group[event] = [[
          "matcher": "*",
          "hooks": [hook]
        ]]
      } else {
        group[event] = [hook]
      }
    }
    return group
  }

  private func antigravityFailOpenCommand(_ command: String, event: String, nodeBin: String) -> String {
    let fallback = shellSingleQuote(Self.antigravityFallbackStdout(event))
    let validatorScript = [
      "let s='';",
      "process.stdin.setEncoding('utf8');",
      "process.stdin.on('data',c=>s+=c);",
      "process.stdin.on('end',()=>{",
      "try{const v=JSON.parse(s);if(!v||typeof v!=='object'||Array.isArray(v))process.exit(1);}",
      "catch{process.exit(1);}",
      "});"
    ].joined()
    let validator = [nodeBin, "-e", validatorScript].map(shellSingleQuote).joined(separator: " ")
    return [
      "tmp_dir=${TMPDIR:-/tmp}",
      "in_file=$(mktemp \"$tmp_dir/clawd-agy-in.XXXXXX\" 2>/dev/null || printf '%s/clawd-agy-in-%s' \"$tmp_dir\" \"$$\")",
      "out_file=$(mktemp \"$tmp_dir/clawd-agy-out.XXXXXX\" 2>/dev/null || printf '%s/clawd-agy-out-%s' \"$tmp_dir\" \"$$\")",
      "pid=",
      "watchdog=",
      "cleanup(){ trap - EXIT HUP INT TERM; [ -n \"$watchdog\" ] && kill \"$watchdog\" 2>/dev/null; [ -n \"$pid\" ] && kill \"$pid\" 2>/dev/null; rm -f \"$in_file\" \"$out_file\"; }",
      "trap cleanup EXIT HUP INT",
      "cat > \"$in_file\" 2>/dev/null || :",
      "\(command) < \"$in_file\" > \"$out_file\" 2>/dev/null & pid=$!",
      "( sleep 8; kill \"$pid\" 2>/dev/null ) & watchdog=$!",
      "wait \"$pid\" 2>/dev/null",
      "status=$?",
      "[ -n \"$watchdog\" ] && kill \"$watchdog\" 2>/dev/null",
      "[ -n \"$watchdog\" ] && wait \"$watchdog\" 2>/dev/null",
      "pid=",
      "watchdog=",
      "out=$(cat \"$out_file\" 2>/dev/null)",
      "if [ \"$status\" -eq 0 ] && [ -n \"$out\" ] && printf '%s' \"$out\" | \(validator) 2>/dev/null; then printf '%s\\n' \"$out\"; else printf '%s\\n' \(fallback); fi",
      "exit 0"
    ].joined(separator: "; ")
  }

  private func kimiHookBlock(event: String, command: String) -> String {
    [
      "[[hooks]]",
      "event = \"\(event)\"",
      "command = '\(command)'",
      "matcher = \"\"",
      "timeout = 30",
      ""
    ].joined(separator: "\n")
  }

  private func stripKimiHookBlocks(from content: String) -> (content: String, removed: Int) {
    guard !content.isEmpty else { return ("", 0) }
    let lines = content.components(separatedBy: "\n")
    var output: [String] = []
    var removed = 0
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if isKimiHooksHeader(line) {
        let start = index
        var end = index + 1
        while end < lines.count, !isTomlSectionHeader(lines[end]) {
          end += 1
        }
        let block = lines[start..<end].joined(separator: "\n")
        if block.contains("kimi-hook.js") {
          removed += 1
        } else {
          output.append(block)
        }
        index = end
      } else {
        output.append(line)
        index += 1
      }
    }
    return (output.joined(separator: "\n"), removed)
  }

  private func removeKimiEmptyHooksArray(from content: String) -> String {
    content
      .components(separatedBy: "\n")
      .filter { line in
        line.range(of: #"^\s*hooks\s*=\s*\[\]\s*$"#, options: .regularExpression) == nil
      }
      .joined(separator: "\n")
  }

  private func isKimiHooksHeader(_ line: String) -> Bool {
    line.range(of: #"^\s*\[\[hooks\]\]\s*(?:#.*)?$"#, options: .regularExpression) != nil
  }

  private func isTomlSectionHeader(_ line: String) -> Bool {
    line.range(of: #"^\s*\[\[?[^\]]+\]\]?\s*(?:#.*)?$"#, options: .regularExpression) != nil
  }

  private func normalizeKimiPermissionMode(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return normalized == "explicit" || normalized == "suspect" ? normalized : nil
  }

  private func extractExistingKimiPermissionMode(from content: String) -> String? {
    guard content.contains("kimi-hook.js") else { return nil }
    guard let range = content.range(of: #"CLAWD_KIMI_PERMISSION_MODE=([A-Za-z]+)"#, options: .regularExpression) else {
      return nil
    }
    let match = String(content[range])
    let value = match.replacingOccurrences(of: "CLAWD_KIMI_PERMISSION_MODE=", with: "")
    return normalizeKimiPermissionMode(value)
  }

  private func trimTrailingWhitespace(_ value: String) -> String {
    var result = value
    while let last = result.last, last.isWhitespace {
      result.removeLast()
    }
    return result
  }

  private func commandExistsOnPath(_ command: String) -> Bool {
    let path = environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command).path
      if fileManager.isExecutableFile(atPath: candidate) {
        return true
      }
    }
    return false
  }

  private func piMarker() -> [String: Any] {
    [
      "app": "clawd-on-desk",
      "integration": "pi",
      "managed": true,
      "version": 1,
      "installedAt": ISO8601DateFormatter().string(from: Date())
    ]
  }

  private func isManagedPiMarker(_ markerPath: URL) -> Bool {
    guard let marker = try? readJSONObject(markerPath, missingIsEmpty: false) else { return false }
    return marker["app"] as? String == "clawd-on-desk"
      && marker["integration"] as? String == "pi"
      && marker["managed"] as? Bool == true
  }

  private func resolveHermesHome() -> URL {
    if let value = trimmedEnvironment("HERMES_HOME") {
      return URL(fileURLWithPath: value).standardizedFileURL
    }
    if let localAppData = trimmedEnvironment("LOCALAPPDATA") {
      let localHermes = URL(fileURLWithPath: localAppData)
        .appendingPathComponent("hermes", isDirectory: true)
        .standardizedFileURL
      if fileManager.fileExists(atPath: localHermes.appendingPathComponent("config.yaml").path)
        || fileManager.fileExists(atPath: localHermes.appendingPathComponent("hermes-agent/venv/Scripts/hermes.exe").path) {
        return localHermes
      }
    }
    return homeDirectory.appendingPathComponent(".hermes", isDirectory: true).standardizedFileURL
  }

  private func isHermesInstalled() -> Bool {
    let homes: [URL]
    if let value = trimmedEnvironment("HERMES_HOME") {
      homes = [URL(fileURLWithPath: value).standardizedFileURL]
    } else {
      var candidates: [URL] = []
      if let localAppData = trimmedEnvironment("LOCALAPPDATA") {
        candidates.append(URL(fileURLWithPath: localAppData).appendingPathComponent("hermes", isDirectory: true).standardizedFileURL)
      }
      candidates.append(homeDirectory.appendingPathComponent(".hermes", isDirectory: true).standardizedFileURL)
      homes = candidates
    }

    for home in homes {
      if fileManager.fileExists(atPath: home.appendingPathComponent("config.yaml").path) {
        return true
      }
      if hermesCommandCandidates(hermesHome: home).contains(where: { fileManager.fileExists(atPath: $0.path) }) {
        return true
      }
    }
    return false
  }

  private func hermesHomesForSync(_ hermesHome: URL) -> [URL] {
    var homes = [hermesHome]
    let profilesDir = hermesHome.appendingPathComponent("profiles", isDirectory: true)
    guard let entries = try? fileManager.contentsOfDirectory(
      at: profilesDir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return homes
    }

    for entry in entries.sorted(by: { $0.path < $1.path }) {
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
      guard fileManager.fileExists(atPath: entry.appendingPathComponent("config.yaml").path) else { continue }
      if !homes.contains(where: { $0.standardizedFileURL.path == entry.standardizedFileURL.path }) {
        homes.append(entry.standardizedFileURL)
      }
    }
    return homes
  }

  private func copyManagedHermesPluginFiles(to pluginDir: URL) throws -> ChangeCounters {
    let sourceDir = projectRoot.appendingPathComponent("hooks/hermes-plugin", isDirectory: true)
    var counters = ChangeCounters()
    try fileManager.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    for file in ["plugin.yaml", "__init__.py"] {
      let source = try Data(contentsOf: sourceDir.appendingPathComponent(file))
      let target = pluginDir.appendingPathComponent(file)
      if !fileManager.fileExists(atPath: target.path) {
        try source.write(to: target)
        counters.added += 1
        continue
      }
      let current = try Data(contentsOf: target)
      if current == source {
        counters.skipped += 1
      } else {
        try source.write(to: target)
        counters.updated += 1
      }
    }
    return counters
  }

  private func hermesCommandCandidates(hermesHome: URL) -> [URL] {
    var candidates = [
      hermesHome.appendingPathComponent("hermes-agent/venv/bin/hermes"),
      hermesHome.appendingPathComponent("hermes-agent/venv/Scripts/hermes.exe")
    ]
    if let localAppData = trimmedEnvironment("LOCALAPPDATA") {
      candidates.append(
        URL(fileURLWithPath: localAppData)
          .appendingPathComponent("hermes/hermes-agent/venv/Scripts/hermes.exe")
      )
    }
    var seen = Set<String>()
    return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private func resolveHermesCommand(hermesHome: URL) -> String {
    if let override = trimmedEnvironment("CLAWD_HERMES_COMMAND") {
      return override
    }
    for candidate in hermesCommandCandidates(hermesHome: hermesHome) where fileManager.fileExists(atPath: candidate.path) {
      return candidate.path
    }
    return "hermes"
  }

  private func runHermesCli(args: [String], hermesHome: URL, hermesCommand: String, timeout: TimeInterval = 5) -> HermesCommandResult {
    let process = Process()
    let pipe = Pipe()
    if hermesCommand.contains("/") {
      process.executableURL = URL(fileURLWithPath: hermesCommand)
      process.arguments = args
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [hermesCommand] + args
    }
    var env = ProcessInfo.processInfo.environment
    for (key, value) in environment {
      env[key] = value
    }
    env["HERMES_HOME"] = hermesHome.path
    process.environment = env
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      return HermesCommandResult(ok: false, unavailable: true, message: error.localizedDescription)
    }

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      group.leave()
    }
    if group.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      return HermesCommandResult(ok: false, unavailable: false, message: "Hermes CLI timed out")
    }

    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      let unavailable = !hermesCommand.contains("/") && (process.terminationStatus == 126 || process.terminationStatus == 127)
      return HermesCommandResult(
        ok: false,
        unavailable: unavailable,
        message: output.isEmpty ? "Hermes CLI exited with status \(process.terminationStatus)" : output
      )
    }
    return HermesCommandResult(ok: true, unavailable: false, message: output)
  }

  private func formatHermesCommand(_ command: String, _ args: [String]) -> String {
    ([command] + args).map(quoteCommandToken).joined(separator: " ")
  }

  private func quoteCommandToken(_ value: String) -> String {
    value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      ? value
      : "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  private func trimmedEnvironment(_ key: String) -> String? {
    guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private func resolveOpenClawPaths() -> (stateDir: URL, configPath: URL) {
    let stateDir = environment["OPENCLAW_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let configPath = environment["OPENCLAW_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedStateDir = stateDir?.isEmpty == false
      ? URL(fileURLWithPath: stateDir!)
      : homeDirectory.appendingPathComponent(".openclaw", isDirectory: true)
    let resolvedConfigPath = configPath?.isEmpty == false
      ? URL(fileURLWithPath: configPath!)
      : resolvedStateDir.appendingPathComponent("openclaw.json")
    return (resolvedStateDir, resolvedConfigPath)
  }

  private func ensureOpenClawConfigLinked(config: inout [String: Any], pluginDir: String) -> (updated: Bool, reason: String?) {
    if hasOpenClawIncludeDirective(config) {
      return (false, "config-has-include")
    }

    var updated = false
    if config["plugins"] == nil {
      config["plugins"] = [:] as [String: Any]
      updated = true
    }
    guard var plugins = config["plugins"] as? [String: Any] else {
      return (false, "plugins-not-object")
    }

    if plugins["load"] == nil {
      plugins["load"] = [:] as [String: Any]
      updated = true
    }
    guard var load = plugins["load"] as? [String: Any] else {
      return (false, "plugins-load-not-object")
    }
    if load["paths"] == nil {
      load["paths"] = [] as [Any]
      updated = true
    }
    guard var paths = load["paths"] as? [Any] else {
      return (false, "plugins-load-paths-not-array")
    }
    let pathIndex = openClawPluginPathIndex(paths, pluginDir: pluginDir)
    if pathIndex == nil {
      paths.append(pluginDir)
      updated = true
    } else if let pathIndex, paths[pathIndex] as? String != pluginDir {
      paths[pathIndex] = pluginDir
      updated = true
    }
    load["paths"] = paths
    plugins["load"] = load

    if plugins["entries"] == nil {
      plugins["entries"] = [:] as [String: Any]
      updated = true
    }
    guard var entries = plugins["entries"] as? [String: Any] else {
      return (false, "plugins-entries-not-object")
    }
    var currentEntry = entries["clawd-on-desk"] as? [String: Any] ?? [:]
    var currentHooks = currentEntry["hooks"] as? [String: Any] ?? [:]
    if currentEntry["enabled"] as? Bool != true {
      currentEntry["enabled"] = true
      updated = true
    }
    if currentHooks["allowConversationAccess"] as? Bool != false {
      currentHooks["allowConversationAccess"] = false
      currentEntry["hooks"] = currentHooks
      updated = true
    } else if currentEntry["hooks"] == nil {
      currentEntry["hooks"] = currentHooks
      updated = true
    }
    if !jsonValueEquals(entries["clawd-on-desk"], currentEntry) {
      entries["clawd-on-desk"] = currentEntry
      updated = true
    }
    plugins["entries"] = entries
    config["plugins"] = plugins
    return (updated, nil)
  }

  private func removeOpenClawConfigLink(config: inout [String: Any], pluginDir: String) -> Bool {
    var updated = false
    guard var plugins = config["plugins"] as? [String: Any] else { return false }
    if var load = plugins["load"] as? [String: Any],
       var paths = load["paths"] as? [Any],
       let index = openClawPluginPathIndex(paths, pluginDir: pluginDir) {
      paths.remove(at: index)
      load["paths"] = paths
      plugins["load"] = load
      updated = true
    }
    if var entries = plugins["entries"] as? [String: Any], entries["clawd-on-desk"] != nil {
      entries.removeValue(forKey: "clawd-on-desk")
      plugins["entries"] = entries
      updated = true
    }
    if updated {
      config["plugins"] = plugins
    }
    return updated
  }

  private func openClawPluginPathIndex(_ paths: [Any], pluginDir: String) -> Int? {
    let normalizedPluginDir = normalizeOpenClawPath(pluginDir)
    for (index, entry) in paths.enumerated() {
      guard let path = entry as? String else { continue }
      let normalized = normalizeOpenClawPath(path)
      if normalized == normalizedPluginDir { return index }
      if openClawPathLooksAbsolute(normalized), URL(fileURLWithPath: normalized).lastPathComponent == "openclaw-plugin" {
        return index
      }
    }
    return nil
  }

  private func opencodePluginIndex(_ plugins: [Any], pluginDir: String) -> Int? {
    let normalizedPluginDir = normalizeOpenClawPath(pluginDir)
    for (index, entry) in plugins.enumerated() {
      guard let string = entry as? String else { continue }
      let normalized = normalizeOpenClawPath(string)
      if normalized == normalizedPluginDir { return index }
      if openClawPathLooksAbsolute(normalized), URL(fileURLWithPath: normalized).lastPathComponent == "opencode-plugin" {
        return index
      }
    }
    return nil
  }

  private func normalizeOpenClawPath(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "/")
  }

  private func openClawPathLooksAbsolute(_ value: String) -> Bool {
    value.hasPrefix("/") || value.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
  }

  private func hasOpenClawIncludeDirective(_ value: Any) -> Bool {
    if let array = value as? [Any] {
      return array.contains { hasOpenClawIncludeDirective($0) }
    }
    guard let object = value as? [String: Any] else { return false }
    for (key, entry) in object {
      if key == "$include" { return true }
      if key == "include", entry is [Any] { return true }
      if hasOpenClawIncludeDirective(entry) { return true }
    }
    return false
  }

  private func resolveNativeHookBinary() -> String? {
    var candidates: [String] = []
    if let explicit = environment["CLAWD_NATIVE_HOOK_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      candidates.append(explicit)
    }
    candidates.append(projectRoot.appendingPathComponent("native/.build/release/ClawdNativeHook").path)
    candidates.append(projectRoot.appendingPathComponent("native/.build/debug/ClawdNativeHook").path)
    candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ClawdNativeHook").path)
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
  }

  private func syncNestedCommandHook(
    settings: inout [String: Any],
    event: String,
    marker: String,
    desired: [String: Any],
    wrapperMatcher: String?,
    insertAtFront: Bool = false
  ) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var entries = hooks[event] as? [Any] ?? []
    var counters = ChangeCounters()

    for index in entries.indices {
      guard var entry = entries[index] as? [String: Any] else { continue }
      if var inner = entry["hooks"] as? [Any] {
        for hookIndex in inner.indices {
          guard var hook = inner[hookIndex] as? [String: Any],
                containsMarker(hook, marker: marker)
          else { continue }
          if !NSDictionary(dictionary: hook).isEqual(to: desired) {
            hook = desired
            inner[hookIndex] = hook
            entry["hooks"] = inner
            entries[index] = entry
            counters.updated += 1
          } else {
            counters.skipped += 1
          }
          hooks[event] = entries
          settings["hooks"] = hooks
          return counters
        }
      }
      if containsMarker(entry, marker: marker) {
        var next = entry
        for key in Array(next.keys) { next.removeValue(forKey: key) }
        for (key, value) in desired { next[key] = value }
        if !NSDictionary(dictionary: entry).isEqual(to: next) {
          entries[index] = next
          counters.updated += 1
        } else {
          counters.skipped += 1
        }
        hooks[event] = entries
        settings["hooks"] = hooks
        return counters
      }
    }

    var wrapper: [String: Any] = ["hooks": [desired]]
    if let wrapperMatcher {
      wrapper["matcher"] = wrapperMatcher
    }
    if insertAtFront {
      entries.insert(wrapper, at: 0)
    } else {
      entries.append(wrapper)
    }
    counters.added += 1
    hooks[event] = entries
    settings["hooks"] = hooks
    return counters
  }

  private func syncNestedHTTPHook(
    settings: inout [String: Any],
    event: String,
    marker: String,
    desired: [String: Any],
    wrapperMatcher: String?,
    replaceAnyHTTP: Bool = true
  ) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var entries = hooks[event] as? [Any] ?? []
    var counters = ChangeCounters()

    for index in entries.indices {
      guard var entry = entries[index] as? [String: Any] else { continue }
      if var inner = entry["hooks"] as? [Any] {
        for hookIndex in inner.indices {
          guard var hook = inner[hookIndex] as? [String: Any],
                containsMarker(hook, marker: marker) || (replaceAnyHTTP && hook["type"] as? String == "http")
          else { continue }
          if !NSDictionary(dictionary: hook).isEqual(to: desired) {
            hook = desired
            inner[hookIndex] = hook
            entry["hooks"] = inner
            entries[index] = entry
            counters.updated += 1
          } else {
            counters.skipped += 1
          }
          hooks[event] = entries
          settings["hooks"] = hooks
          return counters
        }
      }
    }

    var wrapper: [String: Any] = ["hooks": [desired]]
    if let wrapperMatcher {
      wrapper["matcher"] = wrapperMatcher
    }
    entries.append(wrapper)
    counters.added += 1
    hooks[event] = entries
    settings["hooks"] = hooks
    return counters
  }

  private func syncWholeHookEntry(
    settings: inout [String: Any],
    event: String,
    marker: String,
    desiredEntry: [String: Any]
  ) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var entries = hooks[event] as? [Any] ?? []
    var counters = ChangeCounters()
    for index in entries.indices {
      guard let entry = entries[index] as? [String: Any],
            containsMarker(entry, marker: marker)
      else { continue }
      if !NSDictionary(dictionary: entry).isEqual(to: desiredEntry) {
        entries[index] = desiredEntry
        counters.updated += 1
      } else {
        counters.skipped += 1
      }
      hooks[event] = entries
      settings["hooks"] = hooks
      return counters
    }
    entries.append(desiredEntry)
    counters.added += 1
    hooks[event] = entries
    settings["hooks"] = hooks
    return counters
  }

  private func syncDedicatedNestedHookEntry(
    settings: inout [String: Any],
    event: String,
    marker: String,
    desiredEntry: [String: Any]
  ) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    let entries = hooks[event] as? [Any] ?? []
    var next: [Any] = []
    var counters = ChangeCounters()
    var wroteDedicatedEntry = false

    for entryValue in entries {
      guard var entry = entryValue as? [String: Any] else {
        next.append(entryValue)
        continue
      }

      if containsMarker(entry, marker: marker), entry["hooks"] == nil {
        if wroteDedicatedEntry {
          counters.removed += 1
          continue
        }
        if NSDictionary(dictionary: entry).isEqual(to: desiredEntry) {
          counters.skipped += 1
        } else {
          counters.updated += 1
        }
        next.append(desiredEntry)
        wroteDedicatedEntry = true
        continue
      }

      guard let inner = entry["hooks"] as? [Any] else {
        next.append(entry)
        continue
      }
      let clawdCount = inner.compactMap { $0 as? [String: Any] }.filter { containsMarker($0, marker: marker) }.count
      guard clawdCount > 0 else {
        next.append(entry)
        continue
      }

      let otherHooks = inner.filter { hook in
        guard let hookDict = hook as? [String: Any] else { return true }
        return !containsMarker(hookDict, marker: marker)
      }
      if !otherHooks.isEmpty {
        entry["hooks"] = otherHooks
        next.append(entry)
        counters.updated += 1
        continue
      }

      if wroteDedicatedEntry {
        counters.removed += 1
        continue
      }
      if NSDictionary(dictionary: entry).isEqual(to: desiredEntry) {
        counters.skipped += 1
      } else {
        counters.updated += 1
      }
      next.append(desiredEntry)
      wroteDedicatedEntry = true
    }

    if !wroteDedicatedEntry {
      next.append(desiredEntry)
      counters.added += 1
    }
    hooks[event] = next
    settings["hooks"] = hooks
    return counters
  }

  private func removeCodeBuddyPermissionHooks(settings: inout [String: Any]) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    guard var entries = hooks["PermissionRequest"] as? [Any] else { return ChangeCounters() }
    var removed = 0
    entries = entries.compactMap { entryValue in
      guard var entry = entryValue as? [String: Any] else { return entryValue }
      if isManagedLocalPermissionHook(entry) {
        removed += 1
        return nil
      }
      if let inner = entry["hooks"] as? [Any] {
        let nextInner = inner.filter { hookValue in
          guard let hook = hookValue as? [String: Any] else { return true }
          if isManagedLocalPermissionHook(hook) {
            removed += 1
            return false
          }
          return true
        }
        if nextInner.isEmpty, entry["command"] == nil, entry["type"] == nil {
          return nil
        }
        entry["hooks"] = nextInner
      }
      return entry
    }
    guard removed > 0 else { return ChangeCounters() }
    if entries.isEmpty {
      hooks.removeValue(forKey: "PermissionRequest")
    } else {
      hooks["PermissionRequest"] = entries
    }
    settings["hooks"] = hooks
    return ChangeCounters(removed: removed)
  }

  private func isManagedLocalPermissionHook(_ hook: [String: Any]) -> Bool {
    guard hook["type"] as? String == "http",
          let url = hook["url"] as? String
    else { return false }
    let pattern = #"^http://127\.0\.0\.1:(2333[3-7])/permission$"#
    return url.range(of: pattern, options: .regularExpression) != nil
  }

  private func removeCommandHooks(settings: inout [String: Any], event: String, marker: String) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    guard var entries = hooks[event] as? [Any] else { return ChangeCounters() }
    let originalCount = countMarkedHooks(entries, marker: marker)
    entries = removeMarkedHooks(entries, marker: marker)
    guard originalCount > 0 else { return ChangeCounters() }
    if entries.isEmpty {
      hooks.removeValue(forKey: event)
    } else {
      hooks[event] = entries
    }
    settings["hooks"] = hooks
    return ChangeCounters(removed: originalCount)
  }

  private func removeHTTPHooks(settings: inout [String: Any], event: String, marker: String) -> ChangeCounters {
    removeCommandHooks(settings: &settings, event: event, marker: marker)
  }

  private func removeWholeHookEntries(settings: inout [String: Any], event: String, marker: String) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    guard let entries = hooks[event] as? [Any] else { return ChangeCounters() }
    let next = entries.filter { entry in
      guard let dict = entry as? [String: Any] else { return true }
      return !containsMarker(dict, marker: marker)
    }
    let removed = entries.count - next.count
    guard removed > 0 else { return ChangeCounters() }
    if next.isEmpty {
      hooks.removeValue(forKey: event)
    } else {
      hooks[event] = next
    }
    settings["hooks"] = hooks
    return ChangeCounters(removed: removed)
  }

  private func countMarkedHooks(_ entries: [Any], marker: String) -> Int {
    var count = 0
    for entry in entries {
      guard let dict = entry as? [String: Any] else { continue }
      if containsMarker(dict, marker: marker), dict["hooks"] == nil {
        count += 1
      }
      if let inner = dict["hooks"] as? [Any] {
        count += inner.compactMap { $0 as? [String: Any] }.filter { containsMarker($0, marker: marker) }.count
      }
    }
    return count
  }

  private func removeMarkedHooks(_ entries: [Any], marker: String) -> [Any] {
    entries.compactMap { entry in
      guard var dict = entry as? [String: Any] else { return entry }
      if containsMarker(dict, marker: marker), dict["hooks"] == nil {
        return nil
      }
      if let inner = dict["hooks"] as? [Any] {
        let nextInner = inner.filter { hook in
          guard let hookDict = hook as? [String: Any] else { return true }
          return !containsMarker(hookDict, marker: marker)
        }
        if nextInner.isEmpty, dict["command"] == nil, dict["type"] == nil {
          return nil
        }
        dict["hooks"] = nextInner
      }
      return dict
    }
  }

  private func containsMarker(_ value: Any, marker: String) -> Bool {
    if let string = value as? String {
      return string.contains(marker)
    }
    if let dict = value as? [String: Any] {
      return dict.values.contains { containsMarker($0, marker: marker) }
    }
    if let array = value as? [Any] {
      return array.contains { containsMarker($0, marker: marker) }
    }
    return false
  }

  private func jsonValueEquals(_ lhs: Any?, _ rhs: Any) -> Bool {
    switch (lhs, rhs) {
    case let (left as [String: Any], right as [String: Any]):
      return NSDictionary(dictionary: left).isEqual(to: right)
    case let (left as [Any], right as [Any]):
      return NSArray(array: left).isEqual(to: right)
    case let (left as String, right as String):
      return left == right
    case let (left as Bool, right as Bool):
      return left == right
    case let (left as Int, right as Int):
      return left == right
    case let (left as Double, right as Double):
      return left == right
    default:
      return false
    }
  }

  private func ensureCodexHooksFeature(_ configPath: URL) throws -> (changed: Bool, warning: String?) {
    let text = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.isEmpty ? [] : text.components(separatedBy: CharacterSet.newlines)
    if let featuresIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[features]" }) {
      var endIndex = lines.count
      if featuresIndex + 1 < lines.count {
        for index in (featuresIndex + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
          endIndex = index
          break
        }
      }
      for index in (featuresIndex + 1)..<endIndex {
        let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
          return (false, nil)
        }
        if trimmed.range(of: #"^hooks\s*=\s*false\b"#, options: .regularExpression) != nil {
          return (false, "config.toml already has [features].hooks = false; leaving Codex hooks disabled.")
        }
        if trimmed.range(of: #"^codex_hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
          lines[index] = lines[index].replacingOccurrences(of: "codex_hooks", with: "hooks")
          try writeText(lines.joined(separator: newline), to: configPath)
          return (true, nil)
        }
      }
      lines.insert("hooks = true", at: featuresIndex + 1)
    } else {
      if !lines.isEmpty, lines.last != "" { lines.append("") }
      lines.append("[features]")
      lines.append("hooks = true")
    }
    try writeText(lines.joined(separator: newline).trimmingCharacters(in: .whitespacesAndNewlines) + newline, to: configPath)
    return (true, nil)
  }

  private func writeText(_ text: String, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func resolveNodeBin(existingSettings: [String: Any], marker: String) -> String {
    if let fromEnv = environment["CLAWD_NODE_BIN"],
       !fromEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return fromEnv
    }
    let pathCandidates = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node").path }
    let fixedCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    for candidate in pathCandidates + fixedCandidates where fileManager.isExecutableFile(atPath: candidate) {
      return candidate
    }
    if let existing = findExistingNodeBin(in: existingSettings, marker: marker) {
      return existing
    }
    return "node"
  }

  private func findExistingNodeBin(in value: Any, marker: String) -> String? {
    if let string = value as? String, string.contains(marker) {
      let pattern = #"^"?([^"\s]+(?:/node|node))"?"#
      if let range = string.range(of: pattern, options: .regularExpression) {
        return String(string[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    }
    if let dict = value as? [String: Any] {
      for nested in dict.values {
        if let found = findExistingNodeBin(in: nested, marker: marker) { return found }
      }
    }
    if let array = value as? [Any] {
      for nested in array {
        if let found = findExistingNodeBin(in: nested, marker: marker) { return found }
      }
    }
    return nil
  }

  private func resolveCopilotHome() -> URL {
    if let explicit = environment["COPILOT_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
      return URL(fileURLWithPath: explicit)
    }
    return homeDirectory.appendingPathComponent(".copilot", isDirectory: true)
  }

  private func resolveCodewhaleConfigPath() -> (url: URL, explicit: Bool) {
    for key in ["CODEWHALE_CONFIG_PATH", "DEEPSEEK_CONFIG_PATH"] {
      if let explicit = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
        return (URL(fileURLWithPath: explicit), true)
      }
    }
    return (homeDirectory.appendingPathComponent(".codewhale/config.toml"), false)
  }

  private func buildCodewhaleConfig(original: String, nodeBin: String, hookScript: String) -> (text: String, counters: ChangeCounters) {
    var counters = ChangeCounters()
    if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      counters.added = Self.codewhaleEvents.count
      return (bootstrapCodewhaleConfig(nodeBin: nodeBin, hookScript: hookScript), counters)
    }

    let stripped = removeCodewhaleManagedHookSections(from: original)
    counters.removed = stripped.removed
    let existingManaged = Set(stripped.removedEvents)
    var ensured = ensureCodewhaleHooksEnabled(stripped.text)
    if ensured.changed {
      counters.updated += 1
    }
    let entries = Self.codewhaleEvents.map { event, background in
      codewhaleHookEntry(
        event: event,
        background: background,
        command: hookCommand(agentId: "codewhale", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "codewhale-hook.js")
      )
    }
    ensured.text = appendCodewhaleHookEntries(entries, to: ensured.text)
    if ensured.text == original {
      counters = ChangeCounters(skipped: Self.codewhaleEvents.count)
    } else {
      counters.added += Self.codewhaleEvents.filter { !existingManaged.contains($0.event) }.count
      counters.updated += existingManaged.count
    }
    return (ensured.text, counters)
  }

  private func bootstrapCodewhaleConfig(nodeBin: String, hookScript: String) -> String {
    let entries = Self.codewhaleEvents.map { event, background in
      codewhaleHookEntry(
        event: event,
        background: background,
        command: hookCommand(agentId: "codewhale", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "codewhale-hook.js")
      )
    }
    return [
      "# codewhale Configuration",
      "",
      "[hooks]",
      "enabled = true",
      "",
      entries.joined(separator: "\n\n")
    ].joined(separator: "\n") + "\n"
  }

  private func codewhaleHookEntry(event: String, background: Bool, command: String) -> String {
    var lines = [
      "[[hooks.hooks]]",
      "# managed by clawd-on-desk",
      "event = \"\(event)\"",
      "command = '''\(command)'''"
    ]
    if background {
      lines.append("background = true")
      lines.append("timeout_secs = 5")
    } else {
      lines.append("timeout_secs = 30")
      lines.append("continue_on_error = true")
    }
    return lines.joined(separator: "\n")
  }

  private func removeCodewhaleManagedHookSections(from text: String) -> (text: String, removed: Int, removedEvents: [String]) {
    let lines = text.components(separatedBy: "\n")
    var output: [String] = []
    var removed = 0
    var removedEvents: [String] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "[[hooks.hooks]]" {
        var section = [line]
        var end = index + 1
        while end < lines.count {
          let trimmed = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.hasPrefix("[") { break }
          section.append(lines[end])
          end += 1
        }
        if codewhaleHookSectionIsManaged(section) {
          if output.last?.contains("managed by clawd-on-desk") == true {
            output.removeLast()
          }
          removed += 1
          if let event = codewhaleHookSectionEvent(section) {
            removedEvents.append(event)
          }
        } else {
          output.append(contentsOf: section)
        }
        index = end
        continue
      }
      output.append(line)
      index += 1
    }
    return (output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n", removed, removedEvents)
  }

  private func codewhaleHookSectionIsManaged(_ lines: [String]) -> Bool {
    lines.contains { $0.contains("managed by clawd-on-desk") || $0.contains("codewhale-hook.js") }
  }

  private func codewhaleHookSectionEvent(_ lines: [String]) -> String? {
    for line in lines {
      guard let range = line.range(of: #"^\s*event\s*=\s*"([^"]+)""#, options: .regularExpression) else { continue }
      let matched = String(line[range])
      return matched
        .replacingOccurrences(of: #"^\s*event\s*=\s*""#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #""$"#, with: "", options: .regularExpression)
    }
    return nil
  }

  private func ensureCodewhaleHooksEnabled(_ text: String) -> (text: String, changed: Bool) {
    var lines = text.components(separatedBy: "\n")
    if let hooksIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[hooks]" }) {
      var endIndex = lines.count
      for index in (hooksIndex + 1)..<lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
          endIndex = index
          break
        }
      }
      for index in (hooksIndex + 1)..<endIndex {
        if lines[index].range(of: #"^\s*enabled\s*="#, options: .regularExpression) != nil {
          if lines[index].range(of: #"^\s*enabled\s*=\s*true(?:\s*(?:#.*)?)?$"#, options: .regularExpression) != nil {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", false)
          }
          lines[index] = "enabled = true"
          return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n", true)
        }
      }
      lines.insert("enabled = true", at: hooksIndex + 1)
      return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n", true)
    }
    var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !base.isEmpty { base += "\n\n" }
    base += "[hooks]\nenabled = true\n"
    return (base, true)
  }

  private func appendCodewhaleHookEntries(_ entries: [String], to text: String) -> String {
    var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !base.isEmpty { base += "\n\n" }
    base += entries.joined(separator: "\n\n")
    return base + "\n"
  }

  private func kiroAgentConfigFiles(in agentsDir: URL) throws -> [URL] {
    let entries = try fileManager.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil)
    return entries
      .filter { url in
        let name = url.lastPathComponent
        return name.hasSuffix(".json") && !name.contains(".example") && name != "kiro_default.json"
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func syncKiroAgentFile(_ url: URL, createMinimal: Bool = false) throws -> ChangeCounters {
    let existed = fileManager.fileExists(atPath: url.path)
    var settings = try readJSONObject(url)
    var counters = ChangeCounters()
    var changed = false
    let baseName = url.deletingPathExtension().lastPathComponent
    if settings["name"] == nil {
      settings["name"] = baseName
      changed = true
    }
    if createMinimal, !existed, settings["description"] == nil {
      settings["description"] = "Clawd desktop pet hook integration"
      changed = true
    }
    let nodeBin = resolveNodeBin(existingSettings: settings, marker: "kiro-hook.js")
    let hookScript = projectRoot.appendingPathComponent("hooks/kiro-hook.js").path
    for event in Self.kiroEvents {
      let desiredEntry: [String: Any] = [
        "command": hookCommand(agentId: "kiro-cli", event: event, nodeBin: nodeBin, scriptPath: hookScript, marker: "kiro-hook.js")
      ]
      let before = counters
      counters.merge(syncWholeHookEntry(
        settings: &settings,
        event: event,
        marker: "kiro-hook.js",
        desiredEntry: desiredEntry
      ))
      if counters.added != before.added || counters.updated != before.updated || counters.removed != before.removed {
        changed = true
      }
    }
    if changed {
      try writeJSONObject(settings, to: url)
    }
    return counters
  }

  private func supportedClaudeVersionedEvents() -> (events: [String], warning: String?) {
    guard let version = detectClaudeVersion() else {
      return ([], "Claude Code version could not be detected; versioned hooks skipped.")
    }
    let events = Self.claudeVersionedHooks
      .filter { !versionLessThan(version, $0.minimumVersion) }
      .map(\.event)
    return (events, nil)
  }

  private func detectClaudeVersion() -> String? {
    if let injected = environment["CLAWD_CLAUDE_VERSION"], let parsed = parseVersion(injected) {
      return parsed
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return parseVersion(String(decoding: data, as: UTF8.self))
    } catch {
      return nil
    }
  }

  private func parseVersion(_ value: String) -> String? {
    value.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(value[$0]) }
  }

  private func versionLessThan(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      if l < r { return true }
      if l > r { return false }
    }
    return false
  }

  private func copilotPermissionArrayHasUserEntry(settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any],
          let entries = hooks["permissionRequest"] as? [Any]
    else { return false }
    return entries.contains { entry in
      guard let dict = entry as? [String: Any] else { return false }
      return !containsMarker(dict, marker: "copilot-hook.js")
    }
  }

  private func hasCopilotPermissionHookOutsideManagedFile(hooksPath: URL, settingsPath: URL) -> Bool {
    if hasInlineCopilotPermissionHook(settingsPath) { return true }
    let hooksDir = hooksPath.deletingLastPathComponent()
    guard let files = try? fileManager.contentsOfDirectory(atPath: hooksDir.path) else { return false }
    for name in files where name.hasSuffix(".json") && name != hooksPath.lastPathComponent {
      let url = hooksDir.appendingPathComponent(name)
      guard let object = try? readJSONObject(url, missingIsEmpty: false),
            let hooks = object["hooks"] as? [String: Any],
            let entries = hooks["permissionRequest"] as? [Any],
            !entries.isEmpty
      else { continue }
      return true
    }
    return false
  }

  private func hasInlineCopilotPermissionHook(_ settingsPath: URL) -> Bool {
    guard let object = try? readJSONObject(settingsPath, missingIsEmpty: false),
          let hooks = object["hooks"] as? [String: Any],
          let entries = hooks["permissionRequest"] as? [Any]
    else { return false }
    return !entries.isEmpty
  }

  private func normalizeGeminiDisabledHooks(settings: inout [String: Any]) -> Bool {
    normalizeCommandDisabledHooks(settings: &settings, marker: "gemini-hook.js")
  }

  private func normalizeCommandDisabledHooks(settings: inout [String: Any], marker: String) -> Bool {
    guard var hooksConfig = settings["hooksConfig"] as? [String: Any],
          let disabled = hooksConfig["disabled"] as? [Any]
    else { return false }

    var next: [Any] = []
    var sawClawd = false
    var changed = false
    for entry in disabled {
      if let string = entry as? String, string == "clawd" {
        if sawClawd {
          changed = true
          continue
        }
        sawClawd = true
        next.append(entry)
        continue
      }
      if containsMarker(entry, marker: marker) {
        if !sawClawd {
          next.append("clawd")
          sawClawd = true
        }
        changed = true
        continue
      }
      next.append(entry)
    }

    guard changed else { return false }
    hooksConfig["disabled"] = next
    settings["hooksConfig"] = hooksConfig
    return true
  }

  private func quote(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
  }

  private func shellSingleQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private struct ChangeCounters: Sendable {
    var added = 0
    var updated = 0
    var skipped = 0
    var removed = 0

    init(added: Int = 0, updated: Int = 0, skipped: Int = 0, removed: Int = 0) {
      self.added = added
      self.updated = updated
      self.skipped = skipped
      self.removed = removed
    }

    mutating func merge(_ other: ChangeCounters) {
      added += other.added
      updated += other.updated
      skipped += other.skipped
      removed += other.removed
    }
  }

  private struct HermesCommandResult: Sendable {
    var ok: Bool
    var unavailable: Bool
    var message: String
  }

  private static let claudeCoreEvents = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "SubagentStart",
    "SubagentStop",
    "Notification",
    "Elicitation"
  ]

  private static let claudeVersionedHooks = [
    (event: "PreCompact", minimumVersion: "2.1.76"),
    (event: "PostCompact", minimumVersion: "2.1.76"),
    (event: "StopFailure", minimumVersion: "2.1.78")
  ]

  private static let codeBuddyEvents = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "Notification",
    "PreCompact"
  ]

  private static let codexEvents = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop"
  ]

  private static let qwenEvents = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "Notification",
    "PermissionRequest"
  ]

  private static let qwenMatcherlessEvents: Set<String> = ["UserPromptSubmit", "Stop"]

  private static let geminiEvents = [
    "SessionStart",
    "SessionEnd",
    "BeforeAgent",
    "AfterAgent",
    "BeforeTool",
    "AfterTool",
    "Notification",
    "PreCompress"
  ]

  private static let antigravityEvents = [
    "PreInvocation",
    "PostToolUse",
    "PostInvocation",
    "Stop"
  ]

  private static func antigravityFallbackStdout(_ event: String) -> String {
    if event == "PreToolUse" { return #"{"decision":"ask"}"# }
    if event == "Stop" { return #"{"decision":"allow"}"# }
    return "{}"
  }

  private static let kimiEvents = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "Notification"
  ]

  private static let cursorEvents = [
    "sessionStart",
    "sessionEnd",
    "beforeSubmitPrompt",
    "preToolUse",
    "postToolUse",
    "postToolUseFailure",
    "subagentStart",
    "subagentStop",
    "preCompact",
    "afterAgentThought",
    "stop"
  ]

  private static let kiroEvents = [
    "agentSpawn",
    "userPromptSubmit",
    "preToolUse",
    "postToolUse",
    "stop"
  ]

  private static let reasonixEvents = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "SubagentStop",
    "Notification",
    "PreCompact"
  ]

  private static let qoderEvents = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "Notification",
    "PermissionRequest",
    "PermissionDenied",
    "SessionEnd"
  ]

  private static let codewhaleEvents: [(event: String, background: Bool)] = [
    ("session_start", true),
    ("session_end", false),
    ("message_submit", true),
    ("tool_call_before", true),
    ("tool_call_after", true),
    ("mode_change", true),
    ("on_error", true)
  ]

  private static let copilotEvents = [
    "sessionStart",
    "userPromptSubmitted",
    "preToolUse",
    "postToolUse",
    "sessionEnd",
    "errorOccurred",
    "agentStop",
    "subagentStart",
    "subagentStop",
    "preCompact",
    "permissionRequest"
  ]
}
