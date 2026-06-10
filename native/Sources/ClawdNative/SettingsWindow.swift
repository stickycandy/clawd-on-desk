import AppKit
import ClawdNativeCore

private enum SettingsTab: Int, CaseIterable {
  case general
  case appearance
  case agents
  case integrations
  case shortcuts
  case remote
  case telegram
  case about

  var localizationKey: String {
    switch self {
    case .general: return "general"
    case .appearance: return "appearance"
    case .agents: return "agents"
    case .integrations: return "integrations"
    case .shortcuts: return "shortcuts"
    case .remote: return "remote"
    case .telegram: return "telegram"
    case .about: return "about"
    }
  }
}

@MainActor
final class SettingsWindowController: NSWindowController {
  private let preferencesStore: PreferencesStore
  private let remoteSSHRuntime: RemoteSSHRuntime
  private let projectRoot: URL
  private let localPort: () -> Int?
  private let stack = NSStackView()
  private var remoteStatusObserver: UUID?
  private var remoteFields: [String: NSTextField] = [:]
  private var remoteChecks: [String: NSButton] = [:]
  private var selectedTab: SettingsTab = .general

  init(
    preferencesStore: PreferencesStore,
    remoteSSHRuntime: RemoteSSHRuntime,
    projectRoot: URL,
    localPort: @escaping () -> Int?
  ) {
    self.preferencesStore = preferencesStore
    self.remoteSSHRuntime = remoteSSHRuntime
    self.projectRoot = projectRoot
    self.localPort = localPort
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Clawd Settings"
    super.init(window: window)
    window.center()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesChanged),
      name: .clawdNativePreferencesDidChange,
      object: preferencesStore
    )
    remoteStatusObserver = remoteSSHRuntime.onStatusChange { [weak self] _ in
      Task { @MainActor in
        self?.reload()
      }
    }
    build()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func build() {
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = stack
    window?.contentView = scroll
    reload()
  }

  @objc nonisolated private func preferencesChanged() {
    Task { @MainActor in
      self.reload()
    }
  }

  private func reload() {
    remoteFields.removeAll()
    remoteChecks.removeAll()
    stack.arrangedSubviews.forEach { view in
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    let prefs = preferencesStore.get()
    stack.addArrangedSubview(tabControl(prefs))
    stack.addArrangedSubview(separator())

    switch selectedTab {
    case .general:
      addGeneralSection(prefs)
    case .appearance:
      addAppearanceSection(prefs)
    case .agents:
      addAgentsSection(prefs)
    case .integrations:
      addIntegrationsSection(prefs)
    case .shortcuts:
      addShortcutsSection(prefs)
    case .remote:
      addRemoteSSHSection(prefs)
    case .telegram:
      addTelegramSection(prefs)
    case .about:
      addAboutSection(prefs)
    }
  }

  private func tabControl(_ prefs: Preferences) -> NSSegmentedControl {
    let control = NSSegmentedControl(labels: SettingsTab.allCases.map { localized($0.localizationKey, prefs: prefs) }, trackingMode: .selectOne, target: self, action: #selector(changeSettingsTab(_:)))
    control.segmentStyle = .rounded
    control.selectedSegment = selectedTab.rawValue
    return control
  }

  @objc private func changeSettingsTab(_ sender: NSSegmentedControl) {
    selectedTab = SettingsTab(rawValue: sender.selectedSegment) ?? .general
    reload()
  }

  private func addGeneralSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle(localized("general", prefs: prefs)))
    stack.addArrangedSubview(languageRow(prefs))
    stack.addArrangedSubview(booleanRow("Show Dock icon", key: "showDock", value: prefs.showDock))
    stack.addArrangedSubview(booleanRow("Open at login", key: "openAtLogin", value: prefs.openAtLogin))
    stack.addArrangedSubview(booleanRow("Bubble follows pet", key: "bubbleFollowPet", value: prefs.bubbleFollowPet))
    stack.addArrangedSubview(booleanRow("Low power idle", key: "lowPowerIdleMode", value: prefs.lowPowerIdleMode))
    stack.addArrangedSubview(booleanRow("Keep awake while working", key: "keepAwakeWhileWorking", value: prefs.keepAwakeWhileWorking))
    stack.addArrangedSubview(booleanRow("Allow edge pinning", key: "allowEdgePinning", value: prefs.allowEdgePinning))
    stack.addArrangedSubview(booleanRow("Keep size across displays", key: "keepSizeAcrossDisplays", value: prefs.keepSizeAcrossDisplays))
    stack.addArrangedSubview(booleanRow("Enable mobile preview", key: "mobilePreviewEnabled", value: prefs.mobilePreviewEnabled))
    stack.addArrangedSubview(booleanRow("Mute sounds", key: "soundMuted", value: prefs.soundMuted))
    stack.addArrangedSubview(booleanRow("Flash on complete", key: "flashTaskbarOnComplete", value: prefs.flashTaskbarOnComplete))
    stack.addArrangedSubview(booleanRow("Auto-approve all permissions", key: "autoApproveAllPermissions", value: prefs.autoApproveAllPermissions))
  }

  private func addAppearanceSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle(localized("appearance", prefs: prefs)))
    stack.addArrangedSubview(themeRow(prefs))
    stack.addArrangedSubview(textRow(label: "Theme variant", value: prefs.themeVariant[prefs.theme] ?? "default", identifier: "theme-variant", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(textRow(label: "Overrides JSON", value: prefs.themeOverrides[prefs.theme]?.shortDescription ?? "", identifier: "theme-overrides-json", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(NSTextField(labelWithString: "Overrides support theme states, miniMode, timings, reactions, hitbox, idleAnimations, and displayHintMap."))

    let mini = NSButton(checkboxWithTitle: "Mini mode", target: self, action: #selector(toggleMini(_:)))
    mini.state = prefs.miniMode ? .on : .off
    stack.addArrangedSubview(mini)
    stack.addArrangedSubview(miniEdgeRow(prefs))

    stack.addArrangedSubview(separator())
    stack.addArrangedSubview(sectionTitle("Session HUD"))
    stack.addArrangedSubview(booleanRow("Enable Session HUD", key: "sessionHudEnabled", value: prefs.sessionHudEnabled))
    stack.addArrangedSubview(booleanRow("Show state labels", key: "sessionHudShowStateLabels", value: prefs.sessionHudShowStateLabels))
    stack.addArrangedSubview(booleanRow("Show elapsed time", key: "sessionHudShowElapsed", value: prefs.sessionHudShowElapsed))
    stack.addArrangedSubview(booleanRow("Show context usage", key: "sessionHudShowContextUsage", value: prefs.sessionHudShowContextUsage))
    stack.addArrangedSubview(booleanRow("Cleanup detached sessions", key: "sessionHudCleanupDetached", value: prefs.sessionHudCleanupDetached))
    stack.addArrangedSubview(booleanRow("Pin Session HUD", key: "sessionHudPinned", value: prefs.sessionHudPinned))
  }

  private func addAgentsSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle(localized("agents", prefs: prefs)))
    for agent in AgentRegistry.all {
      let row = NSStackView()
      row.orientation = .horizontal
      row.spacing = 8
      let enabled = NSButton(checkboxWithTitle: agent.displayName, target: self, action: #selector(toggleAgent(_:)))
      enabled.identifier = NSUserInterfaceItemIdentifier(agent.id)
      enabled.state = AgentGate.isAgentEnabled(prefs, agent.id) ? .on : .off
      row.addArrangedSubview(enabled)

      let permissions = NSButton(checkboxWithTitle: "permission bubble", target: self, action: #selector(toggleAgentPermission(_:)))
      permissions.identifier = NSUserInterfaceItemIdentifier(agent.id)
      permissions.state = AgentGate.isAgentPermissionsEnabled(prefs, agent.id) ? .on : .off
      permissions.isEnabled = agent.capabilities.permissionApproval
      row.addArrangedSubview(permissions)

      let notifications = NSButton(checkboxWithTitle: "notification hook", target: self, action: #selector(toggleAgentNotification(_:)))
      notifications.identifier = NSUserInterfaceItemIdentifier(agent.id)
      notifications.state = (prefs.agents[agent.id]?.notificationHookEnabled ?? true) ? .on : .off
      row.addArrangedSubview(notifications)
      stack.addArrangedSubview(row)

      let details = [
        agent.capabilities.stateOnly ? "state-only" : "state+permission",
        agent.capabilities.terminalFocus ? "terminal focus" : "no terminal focus",
        NativeIntegrationInstaller.supports(agent.id) ? "native installer" : "JS installer"
      ].joined(separator: " / ")
      stack.addArrangedSubview(NSTextField(labelWithString: "  \(agent.id): \(details)"))

      if agent.id == "claude-code" {
        stack.addArrangedSubview(agentSubagentRow(agentId: agent.id, prefs: prefs))
      }
      if agent.id == "codex" {
        stack.addArrangedSubview(textRow(label: "Codex mode", value: prefs.agents[agent.id]?.permissionMode ?? "intercept", identifier: "agent-permissionMode-\(agent.id)", action: #selector(updateTextPreference(_:))))
      }
    }
  }

  private func addIntegrationsSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle(localized("integrations", prefs: prefs)))
    stack.addArrangedSubview(booleanRow("Manage Claude hooks automatically", key: "manageClaudeHooksAutomatically", value: prefs.manageClaudeHooksAutomatically))
    stack.addArrangedSubview(booleanRow("Auto-start with Claude", key: "autoStartWithClaude", value: prefs.autoStartWithClaude))

    let bubbles = NSButton(checkboxWithTitle: "Enable permission bubbles", target: self, action: #selector(toggleBubbles(_:)))
    bubbles.state = prefs.permissionBubblesEnabled && !prefs.hideBubbles ? .on : .off
    stack.addArrangedSubview(bubbles)

    let tray = NSButton(checkboxWithTitle: "Show status menu", target: self, action: #selector(toggleTray(_:)))
    tray.state = prefs.showTray ? .on : .off
    stack.addArrangedSubview(tray)

    stack.addArrangedSubview(separator())
    stack.addArrangedSubview(sectionTitle("Runtime"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Local hook server: \(localPort().map { "127.0.0.1:\($0)" } ?? "not running")"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Mobile preview: GET /mobile-preview"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Remote SSH status: GET /remote-ssh/status"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Updater: \(UpdaterRuntime.gitModePlan().check.joined(separator: " "))"))
  }

  private func addShortcutsSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle(localized("shortcuts", prefs: prefs)))
    stack.addArrangedSubview(textRow(label: "Toggle pet", value: prefs.shortcuts["togglePet"] ?? "", identifier: "shortcut-togglePet", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(textRow(label: "Allow", value: prefs.shortcuts["permissionAllow"] ?? "", identifier: "shortcut-permissionAllow", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(textRow(label: "Deny", value: prefs.shortcuts["permissionDeny"] ?? "", identifier: "shortcut-permissionDeny", action: #selector(updateTextPreference(_:))))

    stack.addArrangedSubview(separator())
    stack.addArrangedSubview(sectionTitle("Diagnostics"))
    for diagnostic in ShortcutDiagnostics.validate(prefs.shortcuts) {
      stack.addArrangedSubview(NSTextField(labelWithString: "\(diagnostic.status): \(diagnostic.message)"))
    }

    stack.addArrangedSubview(separator())
    stack.addArrangedSubview(sectionTitle("Hardware Buddy"))
    stack.addArrangedSubview(booleanRow("Enable Hardware Buddy", key: "hardwareBuddy.enabled", value: prefs.hardwareBuddy.enabled))
    stack.addArrangedSubview(booleanRow("Allow hardware permission replies", key: "hardwareBuddy.permissionsEnabled", value: prefs.hardwareBuddy.permissionsEnabled))
    stack.addArrangedSubview(booleanRow("Enable quick commands", key: "hardwareBuddy.quickCommandsEnabled", value: prefs.hardwareBuddy.quickCommandsEnabled))
    stack.addArrangedSubview(textRow(label: "Device", value: prefs.hardwareBuddy.deviceAddress ?? "", identifier: "hardware-device", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(textRow(label: "Name prefix", value: prefs.hardwareBuddy.namePrefix, identifier: "hardware-prefix", action: #selector(updateTextPreference(_:))))
  }

  private func addTelegramSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle("Telegram Approval"))
    let tgEnabled = NSButton(checkboxWithTitle: "Enable Telegram approval", target: self, action: #selector(toggleTelegram(_:)))
    tgEnabled.state = prefs.telegramApproval.enabled ? .on : .off
    stack.addArrangedSubview(tgEnabled)
    stack.addArrangedSubview(textRow(label: "Token file", value: prefs.telegramApproval.botTokenFile, identifier: "telegram-token-file", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(textRow(label: "Chat ID", value: prefs.telegramApproval.chatId, identifier: "telegram-chat-id", action: #selector(updateTextPreference(_:))))
  }

  private func addAboutSection(_ prefs: Preferences) {
    stack.addArrangedSubview(sectionTitle(localized("about", prefs: prefs)))
    stack.addArrangedSubview(NSTextField(labelWithString: "Clawd Native"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Project root: \(projectRoot.path)"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Preferences: \(PreferencesStore.defaultURL().path)"))

    let actions = NSStackView()
    actions.orientation = .horizontal
    actions.spacing = 8
    actions.addArrangedSubview(NSButton(title: localized("doctor", prefs: prefs), target: self, action: #selector(showDoctor)))
    actions.addArrangedSubview(NSButton(title: localized("about", prefs: prefs), target: self, action: #selector(showAbout)))
    stack.addArrangedSubview(actions)

    stack.addArrangedSubview(separator())
    stack.addArrangedSubview(sectionTitle("Doctor Preview"))
    for item in Diagnostics.localReport(
      serverPort: localPort(),
      preferencesURL: PreferencesStore.defaultURL(),
      projectRoot: projectRoot,
      preferences: prefs,
      remoteSSHStatuses: remoteSSHRuntime.listStatuses()
    ) {
      stack.addArrangedSubview(NSTextField(labelWithString: "\(item.status): \(item.id) - \(item.message)"))
    }
  }

  private func languageRow(_ prefs: Preferences) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    row.addArrangedSubview(NSTextField(labelWithString: "Language"))
    let popup = NSPopUpButton()
    for lang in ["en", "zh", "ko", "ja"] {
      popup.addItem(withTitle: lang)
      popup.lastItem?.representedObject = lang
    }
    popup.selectItem(withTitle: prefs.lang)
    popup.target = self
    popup.action = #selector(changeLanguage(_:))
    row.addArrangedSubview(popup)
    return row
  }

  private func themeRow(_ prefs: Preferences) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    row.addArrangedSubview(NSTextField(labelWithString: "Theme"))
    let themePopup = NSPopUpButton()
    for theme in ["clawd", "calico", "cloudling"] {
      themePopup.addItem(withTitle: theme)
      themePopup.lastItem?.representedObject = theme
    }
    themePopup.selectItem(withTitle: prefs.theme)
    themePopup.target = self
    themePopup.action = #selector(changeTheme(_:))
    row.addArrangedSubview(themePopup)
    return row
  }

  private func miniEdgeRow(_ prefs: Preferences) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    row.addArrangedSubview(NSTextField(labelWithString: "Mini edge"))
    let edgePopup = NSPopUpButton()
    for edge in ["right", "left"] {
      edgePopup.addItem(withTitle: edge)
      edgePopup.lastItem?.representedObject = edge
    }
    edgePopup.selectItem(withTitle: prefs.miniEdge)
    edgePopup.target = self
    edgePopup.action = #selector(changeMiniEdge(_:))
    row.addArrangedSubview(edgePopup)
    return row
  }

  private func agentSubagentRow(agentId: String, prefs: Preferences) -> NSButton {
    let button = NSButton(checkboxWithTitle: "subagent permissions", target: self, action: #selector(toggleAgentSubagent(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(agentId)
    button.state = (prefs.agents[agentId]?.subagentPermissionsEnabled ?? true) ? .on : .off
    return button
  }

  private func addRemoteSSHSection(_ prefs: Preferences) {
    let headingRow = NSStackView()
    headingRow.orientation = .horizontal
    headingRow.spacing = 8
    headingRow.addArrangedSubview(sectionTitle("Remote SSH"))
    let add = NSButton(title: "Add Profile", target: self, action: #selector(addRemoteProfile))
    headingRow.addArrangedSubview(add)
    stack.addArrangedSubview(headingRow)

    if prefs.remoteSshProfiles.isEmpty {
      stack.addArrangedSubview(NSTextField(labelWithString: "No Remote SSH profiles configured."))
      return
    }

    for profile in prefs.remoteSshProfiles {
      stack.addArrangedSubview(remoteProfileView(profile))
    }
  }

  private func remoteProfileView(_ profile: RemoteSSHProfile) -> NSView {
    let container = NSStackView()
    container.orientation = .vertical
    container.spacing = 6
    container.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

    let status = remoteSSHRuntime.status(profileId: profile.id)
    let title = NSTextField(labelWithString: "\(profile.label)  \(profile.effectiveHost)")
    title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    container.addArrangedSubview(title)

    let statusLabel = NSTextField(labelWithString: "Status: \(status.state) - \(status.message)")
    statusLabel.lineBreakMode = .byTruncatingTail
    container.addArrangedSubview(statusLabel)

    let flags = NSStackView()
    flags.orientation = .horizontal
    flags.spacing = 10
    flags.addArrangedSubview(remoteCheck(profile: profile, field: "enabled", title: "Enabled", value: profile.enabled))
    flags.addArrangedSubview(remoteCheck(profile: profile, field: "connectOnLaunch", title: "Connect on launch", value: profile.connectOnLaunch))
    flags.addArrangedSubview(remoteCheck(profile: profile, field: "autoStartCodexMonitor", title: "Codex monitor", value: profile.autoStartCodexMonitor))
    container.addArrangedSubview(flags)

    container.addArrangedSubview(remoteTextRow(profile: profile, field: "label", label: "Label", value: profile.label))
    container.addArrangedSubview(remoteTextRow(profile: profile, field: "host", label: "Host", value: profile.host))
    container.addArrangedSubview(remoteTextRow(profile: profile, field: "user", label: "User", value: profile.user))
    container.addArrangedSubview(remoteTextRow(profile: profile, field: "port", label: "SSH port", value: profile.port.map(String.init) ?? ""))
    container.addArrangedSubview(remoteTextRow(profile: profile, field: "identityFile", label: "Identity file", value: profile.identityFile ?? ""))
    container.addArrangedSubview(remoteTextRow(profile: profile, field: "remoteForwardPort", label: "Forward port", value: String(profile.remoteForwardPort)))
    container.addArrangedSubview(remoteTextRow(profile: profile, field: "hostPrefix", label: "Host prefix", value: profile.hostPrefix ?? ""))
    if let node = profile.detectedRemoteNodeBin, let version = profile.detectedRemoteNodeVersion {
      container.addArrangedSubview(NSTextField(labelWithString: "Remote Node: \(node) \(version)"))
    }
    if let lastDeployedAt = profile.lastDeployedAt {
      container.addArrangedSubview(NSTextField(labelWithString: "Last deployed: \(Date(timeIntervalSince1970: lastDeployedAt / 1000).formatted())"))
    }

    let primaryActions = NSStackView()
    primaryActions.orientation = .horizontal
    primaryActions.spacing = 8
    primaryActions.addArrangedSubview(remoteButton("Save", id: profile.id, action: #selector(saveRemoteProfile(_:))))
    primaryActions.addArrangedSubview(remoteButton("Connect", id: profile.id, action: #selector(connectRemoteProfile(_:))))
    primaryActions.addArrangedSubview(remoteButton("Disconnect", id: profile.id, action: #selector(disconnectRemoteProfile(_:))))
    primaryActions.addArrangedSubview(remoteButton("Probe", id: profile.id, action: #selector(probeRemoteProfile(_:))))
    container.addArrangedSubview(primaryActions)

    let secondaryActions = NSStackView()
    secondaryActions.orientation = .horizontal
    secondaryActions.spacing = 8
    secondaryActions.addArrangedSubview(remoteButton("Deploy / Repair Hooks", id: profile.id, action: #selector(deployRemoteProfile(_:))))
    secondaryActions.addArrangedSubview(remoteButton("Open Terminal", id: profile.id, action: #selector(openRemoteTerminal(_:))))
    secondaryActions.addArrangedSubview(remoteButton("Delete", id: profile.id, action: #selector(deleteRemoteProfile(_:))))
    container.addArrangedSubview(secondaryActions)
    container.addArrangedSubview(separator())
    return container
  }

  private func remoteCheck(profile: RemoteSSHProfile, field: String, title: String, value: Bool) -> NSButton {
    let check = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleRemoteProfileFlag(_:)))
    let id = remoteKey(profile.id, field)
    check.identifier = NSUserInterfaceItemIdentifier(id)
    check.state = value ? .on : .off
    remoteChecks[id] = check
    return check
  }

  private func remoteTextRow(profile: RemoteSSHProfile, field: String, label: String, value: String) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    let labelView = NSTextField(labelWithString: label)
    labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true
    row.addArrangedSubview(labelView)
    let textField = NSTextField(string: value)
    let id = remoteKey(profile.id, field)
    textField.identifier = NSUserInterfaceItemIdentifier(id)
    textField.target = self
    textField.action = #selector(saveRemoteProfileField(_:))
    textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
    row.addArrangedSubview(textField)
    remoteFields[id] = textField
    return row
  }

  private func remoteButton(_ title: String, id: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.identifier = NSUserInterfaceItemIdentifier(id)
    return button
  }

  @objc private func addRemoteProfile() {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let used = Set(preferencesStore.get().remoteSshProfiles.map(\.remoteForwardPort))
    let forwardPort = RemoteSSHProfileValidator.remoteForwardPorts.sorted().first { !used.contains($0) } ?? 23333
    let profile = RemoteSSHProfile(
      id: "remote-\(now)",
      label: "Remote SSH",
      host: "localhost",
      remoteForwardPort: forwardPort
    )
    _ = try? preferencesStore.update { prefs in
      prefs.remoteSshProfiles.append(profile)
    }
  }

  @objc private func saveRemoteProfileField(_ sender: NSTextField) {
    guard let parsed = parseRemoteKey(sender.identifier?.rawValue) else { return }
    saveRemoteProfile(id: parsed.profileId)
  }

  @objc private func saveRemoteProfile(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    saveRemoteProfile(id: id)
  }

  private func saveRemoteProfile(id: String) {
    let prefs = preferencesStore.get()
    guard var profile = prefs.remoteSshProfiles.first(where: { $0.id == id }) else { return }
    profile.label = remoteValue(id, "label").trimmingCharacters(in: .whitespacesAndNewlines)
    profile.host = remoteValue(id, "host").trimmingCharacters(in: .whitespacesAndNewlines)
    profile.user = remoteValue(id, "user").trimmingCharacters(in: .whitespacesAndNewlines)
    profile.port = intValue(remoteValue(id, "port"))
    profile.identityFile = remoteValue(id, "identityFile").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    profile.remoteForwardPort = intValue(remoteValue(id, "remoteForwardPort")) ?? profile.remoteForwardPort
    profile.hostPrefix = remoteValue(id, "hostPrefix").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    profile.enabled = remoteBool(id, "enabled")
    profile.connectOnLaunch = remoteBool(id, "connectOnLaunch")
    profile.autoStartCodexMonitor = remoteBool(id, "autoStartCodexMonitor")

    if case .failure(let error) = RemoteSSHProfileValidator.validate(profile) {
      showAlert("Remote SSH profile is invalid: \(error.message)")
      return
    }
    _ = try? preferencesStore.update { prefs in
      if let index = prefs.remoteSshProfiles.firstIndex(where: { $0.id == id }) {
        prefs.remoteSshProfiles[index] = profile
      }
    }
  }

  @objc private func toggleRemoteProfileFlag(_ sender: NSButton) {
    guard let parsed = parseRemoteKey(sender.identifier?.rawValue) else { return }
    _ = try? preferencesStore.update { prefs in
      guard let index = prefs.remoteSshProfiles.firstIndex(where: { $0.id == parsed.profileId }) else { return }
      switch parsed.field {
      case "enabled":
        prefs.remoteSshProfiles[index].enabled = sender.state == .on
      case "connectOnLaunch":
        prefs.remoteSshProfiles[index].connectOnLaunch = sender.state == .on
      case "autoStartCodexMonitor":
        prefs.remoteSshProfiles[index].autoStartCodexMonitor = sender.state == .on
      default:
        break
      }
    }
  }

  @objc private func connectRemoteProfile(_ sender: NSButton) {
    guard let profile = profile(id: sender.identifier?.rawValue) else { return }
    guard let port = localPort() else {
      showAlert("Local hook server is not running.")
      return
    }
    DispatchQueue.global(qos: .utility).async { [remoteSSHRuntime] in
      let status = remoteSSHRuntime.connect(profile: profile, localPort: port)
      if status.state == "running", profile.autoStartCodexMonitor {
        _ = remoteSSHRuntime.startCodexMonitor(profile: profile)
      }
    }
  }

  @objc private func disconnectRemoteProfile(_ sender: NSButton) {
    guard let profile = profile(id: sender.identifier?.rawValue) else { return }
    DispatchQueue.global(qos: .utility).async { [remoteSSHRuntime] in
      if profile.autoStartCodexMonitor {
        _ = remoteSSHRuntime.stopCodexMonitor(profile: profile)
      }
      _ = remoteSSHRuntime.disconnect(profileId: profile.id)
    }
  }

  @objc private func probeRemoteProfile(_ sender: NSButton) {
    guard let profile = profile(id: sender.identifier?.rawValue) else { return }
    DispatchQueue.global(qos: .utility).async { [weak self, remoteSSHRuntime] in
      let status = remoteSSHRuntime.probe(profile: profile)
      Task { @MainActor in
        self?.showAlert("Probe \(status.state): \(status.message)")
      }
    }
  }

  @objc private func deployRemoteProfile(_ sender: NSButton) {
    guard let profile = profile(id: sender.identifier?.rawValue) else { return }
    DispatchQueue.global(qos: .utility).async { [weak self, preferencesStore, remoteSSHRuntime, projectRoot] in
      let result = remoteSSHRuntime.deploy(profile: profile, projectRoot: projectRoot)
      if result.ok {
        _ = try? preferencesStore.update { prefs in
          guard let index = prefs.remoteSshProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
          prefs.remoteSshProfiles[index].lastDeployedAt = Date().timeIntervalSince1970 * 1000
          if let remoteNode = result.remoteNode {
            prefs.remoteSshProfiles[index].detectedRemoteNodeBin = remoteNode.nodeBin
            prefs.remoteSshProfiles[index].detectedRemoteNodeVersion = remoteNode.version
            prefs.remoteSshProfiles[index].detectedRemoteNodeSource = remoteNode.source
            prefs.remoteSshProfiles[index].detectedRemoteNodeAt = Date().timeIntervalSince1970 * 1000
          }
        }
      }
      let warning = result.warnings.isEmpty ? "" : "\nWarnings:\n\(result.warnings.joined(separator: "\n"))"
      let message = result.ok
        ? "\(result.message)\(warning)"
        : "Deploy failed at \(result.step): \(result.message)"
      Task { @MainActor in
        self?.showAlert(message)
      }
    }
  }

  @objc private func openRemoteTerminal(_ sender: NSButton) {
    guard let profile = profile(id: sender.identifier?.rawValue) else { return }
    let command = remoteSSHRuntime.openInteractiveTerminalCommand(profile: profile)
    let script = #"tell application "Terminal" to do script "\#(escapeAppleScript(command))""#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    do {
      try process.run()
    } catch {
      showAlert("Could not open Terminal: \(error.localizedDescription)")
    }
  }

  @objc private func deleteRemoteProfile(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    _ = remoteSSHRuntime.disconnect(profileId: id)
    _ = try? preferencesStore.update { prefs in
      prefs.remoteSshProfiles.removeAll { $0.id == id }
    }
  }

  @objc private func changeTheme(_ sender: NSPopUpButton) {
    guard let theme = sender.selectedItem?.representedObject as? String else { return }
    _ = try? preferencesStore.update { prefs in
      prefs.theme = theme
    }
  }

  @objc private func toggleMini(_ sender: NSButton) {
    _ = try? preferencesStore.update { prefs in
      prefs.miniMode = sender.state == .on
    }
  }

  @objc private func changeMiniEdge(_ sender: NSPopUpButton) {
    guard let edge = sender.selectedItem?.representedObject as? String else { return }
    _ = try? preferencesStore.update { prefs in
      prefs.miniEdge = edge
    }
  }

  @objc private func changeLanguage(_ sender: NSPopUpButton) {
    guard let lang = sender.selectedItem?.representedObject as? String else { return }
    _ = try? preferencesStore.update { prefs in
      prefs.lang = lang
    }
  }

  @objc private func toggleTelegram(_ sender: NSButton) {
    _ = try? preferencesStore.update { prefs in
      prefs.telegramApproval.enabled = sender.state == .on
    }
  }

  @objc private func updateTextPreference(_ sender: NSTextField) {
    guard let id = sender.identifier?.rawValue else { return }
    _ = try? preferencesStore.update { prefs in
      if id == "telegram-token-file" {
        prefs.telegramApproval.botTokenFile = sender.stringValue
      } else if id == "telegram-chat-id" {
        prefs.telegramApproval.chatId = sender.stringValue
      } else if id == "theme-variant" {
        prefs.themeVariant[prefs.theme] = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "default"
      } else if id == "theme-overrides-json" {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          prefs.themeOverrides.removeValue(forKey: prefs.theme)
        } else if let data = trimmed.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
          prefs.themeOverrides[prefs.theme] = value
        } else {
          showAlert("Theme overrides must be valid JSON.")
        }
      } else if id.hasPrefix("shortcut-") {
        let key = String(id.dropFirst("shortcut-".count))
        prefs.shortcuts[key] = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      } else if id.hasPrefix("agent-permissionMode-") {
        let agentId = String(id.dropFirst("agent-permissionMode-".count))
        var entry = prefs.agents[agentId] ?? AgentSettings()
        entry.permissionMode = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        prefs.agents[agentId] = entry
      } else if id == "hardware-device" {
        prefs.hardwareBuddy.deviceAddress = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      } else if id == "hardware-prefix" {
        prefs.hardwareBuddy.namePrefix = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }

  private func booleanRow(_ title: String, key: String, value: Bool) -> NSButton {
    let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleBooleanPreference(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(key)
    button.state = value ? .on : .off
    return button
  }

  @objc private func toggleBooleanPreference(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue else { return }
    let enabled = sender.state == .on
    if key == "autoApproveAllPermissions", enabled {
      let alert = NSAlert()
      alert.messageText = "Enable auto-approve all permissions?"
      alert.informativeText = "All agent permission requests will be approved without showing a bubble until Clawd Native quits."
      alert.addButton(withTitle: "Enable")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else {
        sender.state = .off
        return
      }
    }
    _ = try? preferencesStore.update { prefs in
      switch key {
      case "showDock": prefs.showDock = enabled
      case "openAtLogin": prefs.openAtLogin = enabled
      case "manageClaudeHooksAutomatically": prefs.manageClaudeHooksAutomatically = enabled
      case "autoStartWithClaude": prefs.autoStartWithClaude = enabled
      case "bubbleFollowPet": prefs.bubbleFollowPet = enabled
      case "lowPowerIdleMode": prefs.lowPowerIdleMode = enabled
      case "keepAwakeWhileWorking": prefs.keepAwakeWhileWorking = enabled
      case "allowEdgePinning": prefs.allowEdgePinning = enabled
      case "keepSizeAcrossDisplays": prefs.keepSizeAcrossDisplays = enabled
      case "mobilePreviewEnabled": prefs.mobilePreviewEnabled = enabled
      case "soundMuted": prefs.soundMuted = enabled
      case "flashTaskbarOnComplete": prefs.flashTaskbarOnComplete = enabled
      case "autoApproveAllPermissions": prefs.autoApproveAllPermissions = enabled
      case "sessionHudEnabled": prefs.sessionHudEnabled = enabled
      case "sessionHudShowStateLabels": prefs.sessionHudShowStateLabels = enabled
      case "sessionHudShowElapsed": prefs.sessionHudShowElapsed = enabled
      case "sessionHudShowContextUsage": prefs.sessionHudShowContextUsage = enabled
      case "sessionHudCleanupDetached": prefs.sessionHudCleanupDetached = enabled
      case "sessionHudPinned": prefs.sessionHudPinned = enabled
      case "hardwareBuddy.enabled": prefs.hardwareBuddy.enabled = enabled
      case "hardwareBuddy.permissionsEnabled": prefs.hardwareBuddy.permissionsEnabled = enabled
      case "hardwareBuddy.quickCommandsEnabled": prefs.hardwareBuddy.quickCommandsEnabled = enabled
      default: break
      }
    }
  }

  private func textRow(label: String, value: String, identifier: String, action: Selector) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    let labelView = NSTextField(labelWithString: label)
    labelView.widthAnchor.constraint(equalToConstant: 90).isActive = true
    row.addArrangedSubview(labelView)
    let field = NSTextField(string: value)
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.target = self
    field.action = action
    row.addArrangedSubview(field)
    return row
  }

  @objc private func toggleAgent(_ sender: NSButton) {
    guard let agentId = sender.identifier?.rawValue else { return }
    _ = try? preferencesStore.update { prefs in
      var entry = prefs.agents[agentId] ?? AgentSettings()
      entry.enabled = sender.state == .on
      prefs.agents[agentId] = entry
    }
  }

  @objc private func toggleAgentPermission(_ sender: NSButton) {
    guard let agentId = sender.identifier?.rawValue else { return }
    _ = try? preferencesStore.update { prefs in
      var entry = prefs.agents[agentId] ?? AgentSettings()
      entry.permissionsEnabled = sender.state == .on
      prefs.agents[agentId] = entry
    }
  }

  @objc private func toggleAgentNotification(_ sender: NSButton) {
    guard let agentId = sender.identifier?.rawValue else { return }
    _ = try? preferencesStore.update { prefs in
      var entry = prefs.agents[agentId] ?? AgentSettings()
      entry.notificationHookEnabled = sender.state == .on
      prefs.agents[agentId] = entry
    }
  }

  @objc private func toggleAgentSubagent(_ sender: NSButton) {
    guard let agentId = sender.identifier?.rawValue else { return }
    _ = try? preferencesStore.update { prefs in
      var entry = prefs.agents[agentId] ?? AgentSettings()
      entry.subagentPermissionsEnabled = sender.state == .on
      prefs.agents[agentId] = entry
    }
  }

  @objc private func toggleBubbles(_ sender: NSButton) {
    _ = try? preferencesStore.update { prefs in
      prefs.permissionBubblesEnabled = sender.state == .on
      prefs.hideBubbles = sender.state != .on
    }
  }

  @objc private func toggleTray(_ sender: NSButton) {
    _ = try? preferencesStore.update { prefs in
      prefs.showTray = sender.state == .on
    }
  }

  private func profile(id: String?) -> RemoteSSHProfile? {
    guard let id else { return nil }
    return preferencesStore.get().remoteSshProfiles.first { $0.id == id }
  }

  private func remoteKey(_ profileId: String, _ field: String) -> String {
    "remote.\(field).\(profileId)"
  }

  private func parseRemoteKey(_ value: String?) -> (field: String, profileId: String)? {
    guard let value else { return nil }
    let parts = value.split(separator: ".", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0] == "remote" else { return nil }
    return (parts[1], parts[2])
  }

  private func remoteValue(_ profileId: String, _ field: String) -> String {
    remoteFields[remoteKey(profileId, field)]?.stringValue ?? ""
  }

  private func remoteBool(_ profileId: String, _ field: String) -> Bool {
    remoteChecks[remoteKey(profileId, field)]?.state == .on
  }

  private func intValue(_ value: String) -> Int? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : Int(text)
  }

  private func sectionTitle(_ text: String) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = NSFont.systemFont(ofSize: 16, weight: .bold)
    return view
  }

  private func separator() -> NSBox {
    let view = NSBox()
    view.boxType = .separator
    return view
  }

  private func showAlert(_ message: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
  }

  @objc private func showDoctor() {
    let prefs = preferencesStore.get()
    let report = Diagnostics.localReport(
      serverPort: localPort(),
      preferencesURL: PreferencesStore.defaultURL(),
      projectRoot: projectRoot,
      preferences: prefs,
      remoteSSHStatuses: remoteSSHRuntime.listStatuses()
    )
    showAlert(report.map { "\($0.status): \($0.id)\n\($0.message)" }.joined(separator: "\n\n"))
  }

  @objc private func showAbout() {
    showAlert("Clawd Native\nSwift/AppKit runtime for Clawd on Desk.\nProject: \(projectRoot.path)")
  }

  private func localized(_ key: String, prefs: Preferences) -> String {
    let table = Self.localizedStrings[prefs.lang] ?? Self.localizedStrings["en"] ?? [:]
    return table[key] ?? Self.localizedStrings["en"]?[key] ?? key
  }

  private static let localizedStrings: [String: [String: String]] = [
    "en": [
      "general": "General",
      "appearance": "Appearance",
      "agents": "Agents",
      "integrations": "Integrations",
      "shortcuts": "Shortcuts",
      "remote": "Remote",
      "telegram": "Telegram",
      "about": "About",
      "doctor": "Doctor"
    ],
    "zh": [
      "general": "通用",
      "appearance": "外观",
      "agents": "Agent",
      "integrations": "集成",
      "shortcuts": "快捷键",
      "remote": "远程",
      "telegram": "Telegram",
      "about": "关于",
      "doctor": "诊断"
    ],
    "ko": [
      "general": "일반",
      "appearance": "모양",
      "agents": "에이전트",
      "integrations": "통합",
      "shortcuts": "단축키",
      "remote": "원격",
      "telegram": "Telegram",
      "about": "정보",
      "doctor": "진단"
    ],
    "ja": [
      "general": "一般",
      "appearance": "外観",
      "agents": "Agent",
      "integrations": "連携",
      "shortcuts": "ショートカット",
      "remote": "リモート",
      "telegram": "Telegram",
      "about": "情報",
      "doctor": "診断"
    ]
  ]

  private func escapeAppleScript(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
