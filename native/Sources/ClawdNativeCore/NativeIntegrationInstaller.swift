import Foundation

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
    "codex",
    "copilot-cli",
    "gemini-cli",
    "qwen-code"
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
      case "codex":
        return try installCodex()
      case "qwen-code":
        return try installQwen()
      case "copilot-cli":
        return try installCopilot()
      case "gemini-cli":
        return try installGemini()
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
      case "codex":
        return try uninstallCodex()
      case "qwen-code":
        return try uninstallQwen()
      case "copilot-cli":
        return try uninstallCopilot()
      case "gemini-cli":
        return try uninstallGemini()
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
      counters.merge(syncGeminiHookEntry(
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
    wrapperMatcher: String?
  ) -> ChangeCounters {
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var entries = hooks[event] as? [Any] ?? []
    var counters = ChangeCounters()

    for index in entries.indices {
      guard var entry = entries[index] as? [String: Any] else { continue }
      if var inner = entry["hooks"] as? [Any] {
        for hookIndex in inner.indices {
          guard var hook = inner[hookIndex] as? [String: Any],
                containsMarker(hook, marker: marker) || hook["type"] as? String == "http"
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

  private func syncGeminiHookEntry(
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
      if containsMarker(entry, marker: "gemini-hook.js") {
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
