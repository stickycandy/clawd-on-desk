import AppKit
import ClawdNativeCore

@MainActor
final class DashboardWindowController: NSWindowController {
  private let engine: StateEngine
  private let scroll = NSScrollView()
  private let documentView = NSView()
  private let stack = NSStackView()
  private let focusManager: TerminalFocusManager
  private var subscription: UUID?

  init(engine: StateEngine, focusManager: TerminalFocusManager) {
    self.engine = engine
    self.focusManager = focusManager
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Clawd 会话面板"
    super.init(window: window)
    window.center()
    configureContent()
    render(engine.snapshot())
    subscription = engine.subscribe { [weak self] snapshot in
      DispatchQueue.main.async {
        self?.render(snapshot)
      }
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    render(engine.snapshot())
    super.showWindow(sender)
  }

  private func configureContent() {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    documentView.addSubview(stack)

    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    window?.contentView = scroll
    scroll.documentView = documentView
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: documentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
    ])
  }

  private func render(_ snapshot: StateSnapshot) {
    stack.arrangedSubviews.forEach { view in
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    if snapshot.sessions.isEmpty {
      stack.addArrangedSubview(emptyState())
      updateDocumentFrame()
      return
    }
    for session in snapshot.sessions {
      stack.addArrangedSubview(row(for: session))
    }
    updateDocumentFrame()
  }

  private func updateDocumentFrame() {
    let contentWidth = max(scroll.contentSize.width, window?.contentView?.bounds.width ?? 620)
    let fittingHeight = max(scroll.contentSize.height, stack.fittingSize.height)
    documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: fittingHeight)
    scroll.documentView = documentView
  }

  private func emptyState() -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.cornerRadius = 8
    container.layer?.borderWidth = 1
    container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.30).cgColor
    container.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
    container.heightAnchor.constraint(equalToConstant: 88).isActive = true

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)

    let title = NSTextField(labelWithString: "暂无会话")
    title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    title.textColor = .labelColor
    stack.addArrangedSubview(title)

    let detail = NSTextField(labelWithString: "开始一次 agent 任务后，这里会显示会话状态和终端入口。")
    detail.font = NSFont.systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    stack.addArrangedSubview(detail)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
    ])
    return container
  }

  private func row(for session: AgentSession) -> NSView {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.borderColor = NSColor.separatorColor.withAlphaComponent(0.55)
    box.borderWidth = 1
    box.cornerRadius = 8
    box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.34)
    box.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 9
    content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8
    header.widthAnchor.constraint(greaterThanOrEqualToConstant: 536).isActive = true
    header.addArrangedSubview(statusPill(session.badge))
    header.addArrangedSubview(titleLabel(displayName(session.metadata.agentId), size: 13, weight: .semibold, color: .labelColor, lines: 1))
    header.addArrangedSubview(subtleLabel(localizedState(session.state), lines: 1))
    header.addArrangedSubview(spacer())

    let focus = SessionButton()
    focus.title = "聚焦"
    focus.target = self
    focus.action = #selector(focusSession(_:))
    focus.session = session
    focus.controlSize = .small
    focus.isEnabled = session.metadata.sourcePid != nil || session.metadata.agentPid != nil
    header.addArrangedSubview(focus)
    content.addArrangedSubview(header)

    let title = titleLabel(displayTitle(for: session), size: 12.5, weight: .medium, color: .labelColor, lines: 2)
    title.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
    content.addArrangedSubview(title)

    if !session.metadata.cwd.isEmpty {
      let cwd = subtleLabel(session.metadata.cwd, lines: 1)
      cwd.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      cwd.lineBreakMode = .byTruncatingMiddle
      cwd.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
      content.addArrangedSubview(cwd)
    }

    let chips = metadataChips(for: session)
    if !chips.arrangedSubviews.isEmpty {
      content.addArrangedSubview(chips)
    }

    box.contentView = content
    return box
  }

  private func metadataChips(for session: AgentSession) -> NSStackView {
    let chips = NSStackView()
    chips.orientation = .horizontal
    chips.alignment = .centerY
    chips.spacing = 6
    addChip("会话 \(shortSessionId(session.id))", to: chips)
    if let tool = session.metadata.toolName?.trimmedNonEmpty {
      addChip("工具 \(tool)", to: chips)
    }
    if let model = session.metadata.model?.trimmedNonEmpty {
      addChip(model, to: chips)
    }
    if let percent = session.metadata.contextUsage?.percent {
      addChip("上下文 \(percent)%", to: chips)
    }
    if !session.metadata.host.isEmpty {
      addChip(session.metadata.host, to: chips)
    }
    if let platform = session.metadata.platform?.trimmedNonEmpty {
      addChip(platform, to: chips)
    }
    if session.metadata.backgroundTasksCount > 0 {
      addChip("后台 \(session.metadata.backgroundTasksCount)", to: chips)
    }
    if session.metadata.sessionCronsCount > 0 {
      addChip("定时 \(session.metadata.sessionCronsCount)", to: chips)
    }
    if session.metadata.stopHookActive {
      addChip("Stop hook", to: chips)
    }
    return chips
  }

  private func addChip(_ text: String, to stack: NSStackView) {
    let chip = NSTextField(labelWithString: text)
    chip.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    chip.textColor = .secondaryLabelColor
    chip.alignment = .center
    chip.wantsLayer = true
    chip.layer?.cornerRadius = 5
    chip.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
    chip.setContentHuggingPriority(.required, for: .horizontal)
    chip.heightAnchor.constraint(equalToConstant: 22).isActive = true
    chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    stack.addArrangedSubview(chip)
  }

  private func statusPill(_ badge: String) -> NSTextField {
    let label = NSTextField(labelWithString: localizedBadge(badge))
    label.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    label.textColor = .white
    label.alignment = .center
    label.wantsLayer = true
    label.layer?.cornerRadius = 5
    label.layer?.backgroundColor = badgeColor(badge).cgColor
    label.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
    label.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return label
  }

  private func titleLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, lines: Int) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.maximumNumberOfLines = lines
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  private func subtleLabel(_ text: String, lines: Int) -> NSTextField {
    titleLabel(text, size: 11.5, weight: .regular, color: .secondaryLabelColor, lines: lines)
  }

  private func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  private func displayTitle(for session: AgentSession) -> String {
    if let title = session.metadata.sessionTitle?.trimmedNonEmpty, title != session.id {
      return title
    }
    return "会话 \(shortSessionId(session.id))"
  }

  private func shortSessionId(_ id: String) -> String {
    let raw = id.split(separator: ":").last.map(String.init) ?? id
    guard raw.count > 18 else { return raw }
    return "\(raw.prefix(8))...\(raw.suffix(6))"
  }

  private func displayName(_ value: String) -> String {
    value
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { part in
        guard let first = part.first else { return "" }
        return first.uppercased() + part.dropFirst()
      }
      .joined(separator: " ")
  }

  private func localizedState(_ state: ClawdState) -> String {
    switch state {
    case .idle: return "空闲"
    case .working: return "工作中"
    case .thinking: return "思考中"
    case .juggling: return "子任务"
    case .carrying: return "搬运"
    case .sweeping: return "清理"
    case .attention: return "完成"
    case .notification: return "等待输入"
    case .error: return "错误"
    case .sleeping, .dozing, .yawning, .collapsing, .waking: return "休眠"
    case .miniEnter, .miniIdle, .miniWorking, .miniAlert, .miniHappy, .miniPeek, .miniSleep, .miniCrabwalk, .miniEnterSleep: return "迷你模式"
    }
  }

  private func localizedBadge(_ badge: String) -> String {
    switch badge {
    case "Live": return "进行中"
    case "Done": return "完成"
    case "Input": return "待处理"
    case "Error": return "错误"
    default: return badge
    }
  }

  private func badgeColor(_ badge: String) -> NSColor {
    switch badge {
    case "Live": return NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.82, alpha: 1)
    case "Done": return NSColor(calibratedRed: 0.22, green: 0.62, blue: 0.40, alpha: 1)
    case "Input": return NSColor(calibratedRed: 0.86, green: 0.48, blue: 0.14, alpha: 1)
    case "Error": return NSColor(calibratedRed: 0.82, green: 0.18, blue: 0.18, alpha: 1)
    default: return .secondaryLabelColor
    }
  }

  @objc private func focusSession(_ sender: NSButton) {
    guard let session = (sender as? SessionButton)?.session else { return }
    let result = focusManager.focus(session: session)
    if result.status == "error" {
      NSSound.beep()
    }
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
