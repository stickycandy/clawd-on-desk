import AppKit
import ClawdNativeCore

@MainActor
final class PassiveNotificationBubbleWindowController: NSWindowController, NSWindowDelegate {
  private var request: PassiveNotificationRequest
  private var autoCloseTimer: Timer?
  private weak var petWindow: NSWindow?
  private static var visible: [PassiveNotificationBubbleWindowController] = []
  private static var lastPreferences: Preferences?
  private static weak var lastPetWindow: NSWindow?

  static func show(_ request: PassiveNotificationRequest, preferences: Preferences, petWindow: NSWindow?) {
    guard preferences.notificationBubbleAutoCloseSeconds > 0, !preferences.hideBubbles else { return }
    if let existing = visible.first(where: { $0.matches(request) }) {
      existing.refresh(request, preferences: preferences, petWindow: petWindow)
      reposition(preferences: preferences, petWindow: petWindow)
      return
    }
    let controller = PassiveNotificationBubbleWindowController(request: request)
    visible.append(controller)
    controller.refresh(request, preferences: preferences, petWindow: petWindow)
    controller.showWindow(nil)
    controller.window?.orderFrontRegardless()
    reposition(preferences: preferences, petWindow: petWindow)
  }

  static func applyPreferences(_ preferences: Preferences, petWindow: NSWindow?) {
    if preferences.hideBubbles || preferences.notificationBubbleAutoCloseSeconds <= 0 {
      clear(agentId: nil, sessionId: nil, reason: "settings-policy-disabled")
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

  static func clear(agentId: String?, sessionId: String?, reason: String) {
    let matches = visible.filter { controller in
      if let agentId, controller.request.agentId != agentId { return false }
      if let sessionId, controller.request.sessionId != sessionId { return false }
      return true
    }
    guard !matches.isEmpty else { return }
    for controller in matches {
      controller.close()
    }
    if let preferences = lastPreferences {
      reposition(preferences: preferences, petWindow: lastPetWindow)
    }
  }

  static func stackEntries() -> [FloatingBubbleStackEntry] {
    visible.map { controller in
      FloatingBubbleStackEntry(
        createdAt: controller.request.createdAt,
        height: controller.window?.frame.height ?? controller.estimatedHeight,
        setFrame: { frame in
          controller.window?.setFrame(frame, display: true)
        }
      )
    }
  }

  init(request: PassiveNotificationRequest) {
    self.request = request
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    FloatingWindowPolicy.applyPersistentOverlay(to: window)
    window.title = "Clawd Notification"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func windowWillClose(_ notification: Notification) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    Self.visible.removeAll { $0 === self }
    if let preferences = Self.lastPreferences {
      Self.reposition(preferences: preferences, petWindow: Self.lastPetWindow)
    }
  }

  private func matches(_ other: PassiveNotificationRequest) -> Bool {
    request.kind == other.kind && request.agentId == other.agentId && request.sessionId == other.sessionId
  }

  private func refresh(_ request: PassiveNotificationRequest, preferences: Preferences, petWindow: NSWindow?) {
    self.request = request
    self.petWindow = petWindow
    window?.contentView = buildView(request)
    resize(preferences: preferences)
    armAutoClose(preferences: preferences)
  }

  private func armAutoClose(preferences: Preferences) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    let seconds = preferences.notificationBubbleAutoCloseSeconds
    guard seconds > 0 else {
      close()
      return
    }
    let elapsed = Date().timeIntervalSince(request.createdAt)
    let remaining = TimeInterval(seconds) - max(elapsed, 0)
    guard remaining > 0 else {
      close()
      return
    }
    autoCloseTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.close()
      }
    }
  }

  private func resize(preferences: Preferences) {
    guard let window else { return }
    let targetSize = window.contentView?.fittingSize ?? NSSize(width: 420, height: estimatedHeight)
    let height = min(max(targetSize.height, 140), 260)
    window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 420, height: height), display: true)
    Self.reposition(preferences: preferences, petWindow: petWindow)
  }

  private var estimatedHeight: CGFloat {
    request.detail == nil ? 170 : 210
  }

  private func buildView(_ request: PassiveNotificationRequest) -> NSView {
    let root = NSStackView()
    root.orientation = .vertical
    root.spacing = 10
    root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
    root.widthAnchor.constraint(equalToConstant: 420).isActive = true

    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8

    let pill = NSTextField(labelWithString: pillText(for: request))
    pill.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    pill.textColor = .white
    pill.alignment = .center
    pill.wantsLayer = true
    pill.layer?.backgroundColor = pillColor(for: request).cgColor
    pill.layer?.cornerRadius = 5
    pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
    pill.heightAnchor.constraint(equalToConstant: 22).isActive = true
    header.addArrangedSubview(pill)

    let title = NSTextField(labelWithString: request.title)
    title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    title.lineBreakMode = .byWordWrapping
    title.maximumNumberOfLines = 2
    header.addArrangedSubview(title)
    root.addArrangedSubview(header)

    let message = NSTextField(labelWithString: request.message)
    message.font = NSFont.systemFont(ofSize: 12)
    message.textColor = .secondaryLabelColor
    message.lineBreakMode = .byWordWrapping
    message.maximumNumberOfLines = 4
    root.addArrangedSubview(message)

    if let detail = request.detail, !detail.isEmpty {
      let detailField = NSTextField(labelWithString: detail)
      detailField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      detailField.textColor = .tertiaryLabelColor
      detailField.lineBreakMode = .byTruncatingTail
      detailField.maximumNumberOfLines = 3
      root.addArrangedSubview(detailField)
    }

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.addArrangedSubview(NSView())
    buttons.addArrangedSubview(NSButton(title: "Got It", target: self, action: #selector(dismissAction)))
    root.addArrangedSubview(buttons)

    return root
  }

  private func pillText(for request: PassiveNotificationRequest) -> String {
    switch request.kind {
    case .codexPermission:
      return "CODEX"
    case .kimiPermission:
      return "KIMI"
    case .terminalAttention:
      return request.agentId.uppercased().prefix(8).description
    }
  }

  private func pillColor(for request: PassiveNotificationRequest) -> NSColor {
    switch request.kind {
    case .codexPermission:
      return NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.92, alpha: 1)
    case .kimiPermission:
      return NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    case .terminalAttention:
      return .systemGray
    }
  }

  @objc private func dismissAction() {
    close()
  }
}
