import AppKit
import ClawdNativeCore

@MainActor
final class PermissionBubbleWindowController: NSWindowController, NSWindowDelegate {
  private var permission: PendingPermission?
  private var resolved = false
  private var autoCloseTimer: Timer?
  private static var visible: [PermissionBubbleWindowController] = []
  private static var lastPreferences: Preferences?
  private static weak var lastPetWindow: NSWindow?

  static func show(_ permission: PendingPermission, preferences: Preferences, petWindow: NSWindow?) {
    guard preferences.permissionBubblesEnabled, !preferences.hideBubbles else {
      permission.resolve(.noDecision)
      return
    }
    let controller = PermissionBubbleWindowController(permission: permission)
    visible.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    controller.armAutoClose(preferences: preferences)
    reposition(preferences: preferences, petWindow: petWindow)
  }

  static func applyPreferences(_ preferences: Preferences, petWindow: NSWindow?) {
    if !preferences.permissionBubblesEnabled || preferences.hideBubbles {
      dismissAllWithoutDecision()
      return
    }
    for controller in visible {
      controller.armAutoClose(preferences: preferences)
    }
    reposition(preferences: preferences, petWindow: petWindow)
  }

  static func reposition(preferences: Preferences, petWindow: NSWindow?) {
    lastPreferences = preferences
    lastPetWindow = petWindow
    FloatingBubbleStackCoordinator.reposition(preferences: preferences, petWindow: petWindow)
  }

  static func stackEntries() -> [FloatingBubbleStackEntry] {
    visible.map { controller in
      FloatingBubbleStackEntry(
        createdAt: controller.permission?.createdAt ?? Date.distantPast,
        height: controller.window?.frame.height ?? controller.estimatedHeight,
        setFrame: { frame in
          controller.window?.setFrame(frame, display: true)
        }
      )
    }
  }

  static func dismissAllWithoutDecision() {
    let controllers = visible
    for controller in controllers {
      controller.resolved = true
      controller.permission?.resolve(.noDecision)
      controller.close()
    }
  }

  init(permission: PendingPermission) {
    self.permission = permission
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.level = .floating
    window.title = "Clawd Permission"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentView = buildView(permission)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func windowWillClose(_ notification: Notification) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    if !resolved {
      permission?.resolve(.noDecision)
    }
    Self.visible.removeAll { $0 === self }
    if let preferences = Self.lastPreferences {
      Self.reposition(preferences: preferences, petWindow: Self.lastPetWindow)
    }
  }

  @objc private func allow() {
    resolved = true
    permission?.resolve(.allow)
    close()
  }

  @objc private func deny() {
    resolved = true
    permission?.resolve(.deny(message: "Denied in Clawd Native"))
    close()
  }

  @objc private func noDecision() {
    resolved = true
    permission?.resolve(.noDecision)
    close()
  }

  private func buildView(_ permission: PendingPermission) -> NSView {
    let root = NSStackView()
    root.orientation = .vertical
    root.spacing = 12
    root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

    let title = NSTextField(labelWithString: "\(permission.request.agentId) wants to run \(permission.request.toolName)")
    title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    title.lineBreakMode = .byWordWrapping
    title.maximumNumberOfLines = 2
    root.addArrangedSubview(title)

    if let description = permission.request.toolInputDescription, !description.isEmpty {
      let label = NSTextField(labelWithString: description)
      label.font = NSFont.systemFont(ofSize: 12)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byWordWrapping
      label.maximumNumberOfLines = 3
      root.addArrangedSubview(label)
    }

    let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 384, height: 110))
    input.string = permission.request.toolInput.shortDescription
    input.isEditable = false
    input.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    input.textColor = .labelColor
    input.backgroundColor = .textBackgroundColor
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 384, height: 110))
    scroll.hasVerticalScroller = true
    scroll.documentView = input
    root.addArrangedSubview(scroll)

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8
    buttons.addArrangedSubview(NSView())
    let terminal = NSButton(title: "Use Terminal", target: self, action: #selector(noDecision))
    let deny = NSButton(title: "Deny", target: self, action: #selector(deny))
    let allow = NSButton(title: "Allow", target: self, action: #selector(allow))
    allow.keyEquivalent = "\r"
    buttons.addArrangedSubview(terminal)
    buttons.addArrangedSubview(deny)
    buttons.addArrangedSubview(allow)
    root.addArrangedSubview(buttons)

    if !permission.request.suggestions.isEmpty {
      let suggestions = NSStackView()
      suggestions.orientation = .vertical
      suggestions.spacing = 6
      for suggestion in permission.request.suggestions {
        let button = SuggestionButton()
        button.title = PermissionSuggestionFormatter.label(for: suggestion)
        button.bezelStyle = .rounded
        button.alignment = .left
        button.suggestion = suggestion
        button.target = self
        button.action = #selector(applySuggestion(_:))
        suggestions.addArrangedSubview(button)
      }
      root.addArrangedSubview(suggestions)
    }
    return root
  }

  private var estimatedHeight: CGFloat {
    260 + CGFloat(permission?.request.suggestions.count ?? 0) * 37
  }

  private func armAutoClose(preferences: Preferences) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    let seconds = preferences.permissionBubbleAutoCloseSeconds
    guard seconds > 0, let permission else { return }
    let elapsed = Date().timeIntervalSince(permission.createdAt)
    let remaining = TimeInterval(seconds) - max(elapsed, 0)
    guard remaining > 0 else {
      noDecision()
      return
    }
    autoCloseTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.noDecision()
      }
    }
  }

  @objc private func applySuggestion(_ sender: NSButton) {
    guard let suggestion = (sender as? SuggestionButton)?.suggestion else { return }
    resolved = true
    let updated = PermissionSuggestionFormatter.updatedPermission(from: suggestion)
    permission?.resolve(.allowWithUpdatedPermissions([updated]))
    close()
  }

}

@MainActor
private final class SuggestionButton: NSButton {
  var suggestion: JSONValue?
}
