import AppKit
import ClawdNativeCore

@MainActor
final class SessionHUDWindowController: NSWindowController {
  private let preferences: () -> Preferences
  private let petWindow: () -> NSWindow?
  private let focusManager: TerminalFocusManager
  private let stack = NSStackView()
  private var subscription: UUID?

  init(
    engine: StateEngine,
    preferences: @escaping () -> Preferences,
    petWindow: @escaping () -> NSWindow?,
    focusManager: TerminalFocusManager
  ) {
    self.preferences = preferences
    self.petWindow = petWindow
    self.focusManager = focusManager
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    super.init(window: panel)
    let visual = NSVisualEffectView()
    visual.material = .hudWindow
    visual.blendingMode = .behindWindow
    visual.state = .active
    visual.wantsLayer = true
    visual.layer?.cornerRadius = 8
    visual.layer?.masksToBounds = true
    stack.orientation = .vertical
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    visual.addSubview(stack)
    panel.contentView = visual
    subscription = engine.subscribe { [weak self] snapshot in
      DispatchQueue.main.async {
        self?.render(snapshot)
      }
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    stack.frame = window?.contentView?.bounds ?? .zero
  }

  private func render(_ snapshot: StateSnapshot) {
    guard preferences().sessionHudEnabled else {
      window?.orderOut(nil)
      return
    }
    let sessions = snapshot.sessions.filter(\.visibleInHUD)
    guard !sessions.isEmpty else {
      window?.orderOut(nil)
      return
    }
    stack.arrangedSubviews.forEach { view in
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for session in sessions.prefix(4) {
      stack.addArrangedSubview(row(for: session))
    }
    let height = CGFloat(20 + sessions.prefix(4).count * 30)
    window?.setContentSize(NSSize(width: 320, height: height))
    if let bounds = window?.contentView?.bounds {
      stack.frame = bounds
    }
    reposition()
    window?.orderFrontRegardless()
  }

  private func row(for session: AgentSession) -> NSView {
    let button = SessionButton()
    let prefs = preferences()
    var parts = [session.badge, session.metadata.agentId]
    if prefs.sessionHudShowStateLabels {
      parts.append(session.state.rawValue)
    }
    if prefs.sessionHudShowElapsed {
      let seconds = max(0, Int(Date().timeIntervalSince(session.startedAt)))
      parts.append(seconds >= 60 ? "\(seconds / 60)m" : "\(seconds)s")
    }
    if prefs.sessionHudShowContextUsage, let percent = session.metadata.contextUsage?.percent {
      parts.append("\(percent)%")
    }
    parts.append(session.metadata.sessionTitle ?? session.id)
    button.title = parts.joined(separator: "  ")
    button.target = self
    button.action = #selector(focus(_:))
    button.bezelStyle = .inline
    button.alignment = .left
    button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    button.contentTintColor = .labelColor
    button.session = session
    button.isEnabled = session.metadata.sourcePid != nil || session.metadata.agentPid != nil
    return button
  }

  @objc private func focus(_ sender: NSButton) {
    guard let session = (sender as? SessionButton)?.session else { return }
    _ = focusManager.focus(session: session)
  }

  private func reposition() {
    guard let window, let pet = petWindow() else { return }
    let petFrame = pet.frame
    var origin = NSPoint(x: petFrame.maxX + 8, y: petFrame.midY - window.frame.height / 2)
    if let screen = pet.screen ?? NSScreen.main {
      origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - window.frame.width - 8)
      origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - window.frame.height - 8)
    }
    window.setFrameOrigin(origin)
  }
}
