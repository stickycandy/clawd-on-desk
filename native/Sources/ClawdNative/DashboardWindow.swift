import AppKit
import ClawdNativeCore

@MainActor
final class DashboardWindowController: NSWindowController {
  private let stack = NSStackView()
  private let focusManager: TerminalFocusManager
  private var subscription: UUID?

  init(engine: StateEngine, focusManager: TerminalFocusManager) {
    self.focusManager = focusManager
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Clawd Sessions"
    super.init(window: window)
    window.center()
    stack.orientation = .vertical
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = stack
    window.contentView = scroll
    subscription = engine.subscribe { [weak self] snapshot in
      DispatchQueue.main.async {
        self?.render(snapshot)
      }
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func render(_ snapshot: StateSnapshot) {
    stack.arrangedSubviews.forEach { view in
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    if snapshot.sessions.isEmpty {
      stack.addArrangedSubview(NSTextField(labelWithString: "No live sessions."))
      return
    }
    for session in snapshot.sessions {
      stack.addArrangedSubview(row(for: session))
    }
  }

  private func row(for session: AgentSession) -> NSView {
    let box = NSBox()
    box.boxType = .custom
    box.borderColor = .separatorColor
    box.borderWidth = 1
    box.cornerRadius = 6
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 12
    row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    let title = session.metadata.sessionTitle ?? session.id
    let cwd = session.metadata.cwd.isEmpty ? "-" : session.metadata.cwd
    let label = NSTextField(labelWithString: """
    [\(session.badge)] \(session.metadata.agentId) / \(session.state.rawValue)
    \(title)
    \(cwd)
    """)
    label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 4
    row.addArrangedSubview(label)
    let focus = SessionButton()
    focus.title = "Focus"
    focus.target = self
    focus.action = #selector(focusSession(_:))
    focus.session = session
    focus.isEnabled = session.metadata.sourcePid != nil || session.metadata.agentPid != nil
    row.addArrangedSubview(focus)
    box.contentView = row
    return box
  }

  @objc private func focusSession(_ sender: NSButton) {
    guard let session = (sender as? SessionButton)?.session else { return }
    let result = focusManager.focus(session: session)
    if result.status == "error" {
      NSSound.beep()
    }
  }
}
