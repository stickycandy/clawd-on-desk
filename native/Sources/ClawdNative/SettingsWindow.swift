import AppKit
import ClawdNativeCore

@MainActor
final class SettingsWindowController: NSWindowController {
  private let preferencesStore: PreferencesStore
  private let stack = NSStackView()

  init(preferencesStore: PreferencesStore) {
    self.preferencesStore = preferencesStore
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Clawd Settings"
    super.init(window: window)
    window.center()
    build()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

  private func reload() {
    stack.arrangedSubviews.forEach { view in
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    let prefs = preferencesStore.get()

    let appearance = NSTextField(labelWithString: "Appearance")
    appearance.font = NSFont.systemFont(ofSize: 16, weight: .bold)
    stack.addArrangedSubview(appearance)

    let themeRow = NSStackView()
    themeRow.orientation = .horizontal
    themeRow.spacing = 8
    themeRow.addArrangedSubview(NSTextField(labelWithString: "Theme"))
    let themePopup = NSPopUpButton()
    for theme in ["clawd", "calico", "cloudling"] {
      themePopup.addItem(withTitle: theme)
      themePopup.lastItem?.representedObject = theme
    }
    themePopup.selectItem(withTitle: prefs.theme)
    themePopup.target = self
    themePopup.action = #selector(changeTheme(_:))
    themeRow.addArrangedSubview(themePopup)
    stack.addArrangedSubview(themeRow)

    let mini = NSButton(checkboxWithTitle: "Mini mode", target: self, action: #selector(toggleMini(_:)))
    mini.state = prefs.miniMode ? .on : .off
    stack.addArrangedSubview(mini)

    let edgeRow = NSStackView()
    edgeRow.orientation = .horizontal
    edgeRow.spacing = 8
    edgeRow.addArrangedSubview(NSTextField(labelWithString: "Mini edge"))
    let edgePopup = NSPopUpButton()
    for edge in ["right", "left"] {
      edgePopup.addItem(withTitle: edge)
      edgePopup.lastItem?.representedObject = edge
    }
    edgePopup.selectItem(withTitle: prefs.miniEdge)
    edgePopup.target = self
    edgePopup.action = #selector(changeMiniEdge(_:))
    edgeRow.addArrangedSubview(edgePopup)
    stack.addArrangedSubview(edgeRow)

    let appearanceSeparator = NSBox()
    appearanceSeparator.boxType = .separator
    stack.addArrangedSubview(appearanceSeparator)

    let heading = NSTextField(labelWithString: "Agents")
    heading.font = NSFont.systemFont(ofSize: 16, weight: .bold)
    stack.addArrangedSubview(heading)

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
      stack.addArrangedSubview(row)
    }

    let separator = NSBox()
    separator.boxType = .separator
    stack.addArrangedSubview(separator)

    let bubbles = NSButton(checkboxWithTitle: "Enable permission bubbles", target: self, action: #selector(toggleBubbles(_:)))
    bubbles.state = prefs.permissionBubblesEnabled && !prefs.hideBubbles ? .on : .off
    stack.addArrangedSubview(bubbles)

    let tray = NSButton(checkboxWithTitle: "Show status menu", target: self, action: #selector(toggleTray(_:)))
    tray.state = prefs.showTray ? .on : .off
    stack.addArrangedSubview(tray)

    let runtimeHeading = NSTextField(labelWithString: "Runtime")
    runtimeHeading.font = NSFont.systemFont(ofSize: 16, weight: .bold)
    stack.addArrangedSubview(runtimeHeading)
    stack.addArrangedSubview(NSTextField(labelWithString: "Mobile preview: GET /mobile-preview on the local hook server"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Remote SSH profiles: \(prefs.remoteSshProfiles.count)"))
    stack.addArrangedSubview(NSTextField(labelWithString: "Updater: \(UpdaterRuntime.gitModePlan().check.joined(separator: " "))"))

    let telegramHeading = NSTextField(labelWithString: "Telegram Approval")
    telegramHeading.font = NSFont.systemFont(ofSize: 16, weight: .bold)
    stack.addArrangedSubview(telegramHeading)
    let tgEnabled = NSButton(checkboxWithTitle: "Enable Telegram approval", target: self, action: #selector(toggleTelegram(_:)))
    tgEnabled.state = prefs.telegramApproval.enabled ? .on : .off
    stack.addArrangedSubview(tgEnabled)
    stack.addArrangedSubview(textRow(label: "Token file", value: prefs.telegramApproval.botTokenFile, identifier: "telegram-token-file", action: #selector(updateTextPreference(_:))))
    stack.addArrangedSubview(textRow(label: "Chat ID", value: prefs.telegramApproval.chatId, identifier: "telegram-chat-id", action: #selector(updateTextPreference(_:))))
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
}
