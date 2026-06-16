import AppKit
import ClawdNativeCore

@MainActor
enum UpdateBubbleAction {
  case primary
  case secondary
  case dismissed
}

struct UpdateBubblePayload {
  var title: String
  var message: String
  var detail: String?
  var primaryTitle: String?
  var secondaryTitle: String?
  var mode: Mode

  enum Mode {
    case info
    case success
    case error
  }
}

@MainActor
final class UpdateBubbleWindowController: NSWindowController, NSWindowDelegate {
  private var actionHandler: ((UpdateBubbleAction) -> Void)?
  private var autoCloseTimer: Timer?
  private weak var petWindow: NSWindow?

  init() {
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: UpdateBubbleLayout.defaultWidth, height: 180),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Clawd Update"
    FloatingWindowPolicy.applyPersistentOverlay(to: window)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @discardableResult
  func show(
    _ payload: UpdateBubblePayload,
    preferences: Preferences,
    petWindow: NSWindow?,
    reservedHeight: CGFloat = 0,
    hudReservedOffset: CGFloat = 0,
    actionHandler: @escaping (UpdateBubbleAction) -> Void
  ) -> Bool {
    guard !preferences.hideBubbles else { return false }
    self.petWindow = petWindow
    self.actionHandler = actionHandler
    autoCloseTimer?.invalidate()
    window?.contentView = buildView(payload)
    resizeAndPosition(preferences: preferences, reservedHeight: reservedHeight, hudReservedOffset: hudReservedOffset)
    showWindow(nil)
    window?.orderFrontRegardless()
    if let window {
      FloatingWindowPolicy.applyPersistentOverlay(to: window)
    }

    let seconds = preferences.updateBubbleAutoCloseSeconds
    if seconds > 0 {
      autoCloseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
        Task { @MainActor in
          self?.dismissFromTimer()
        }
      }
    }
    return true
  }

  func hide() {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    window?.orderOut(nil)
  }

  func reposition(preferences: Preferences, reservedHeight: CGFloat = 0, hudReservedOffset: CGFloat = 0) {
    guard window?.isVisible == true else { return }
    resizeAndPosition(preferences: preferences, reservedHeight: reservedHeight, hudReservedOffset: hudReservedOffset)
  }

  func windowWillClose(_ notification: Notification) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    resolve(.dismissed)
  }

  @objc private func primary() {
    resolve(.primary)
    hide()
  }

  @objc private func secondary() {
    resolve(.secondary)
    hide()
  }

  @objc private func dismissAction() {
    resolve(.dismissed)
    hide()
  }

  private func dismissFromTimer() {
    resolve(.dismissed)
    hide()
  }

  private func resolve(_ action: UpdateBubbleAction) {
    guard let handler = actionHandler else { return }
    actionHandler = nil
    handler(action)
  }

  private func resizeAndPosition(preferences: Preferences, reservedHeight: CGFloat, hudReservedOffset: CGFloat) {
    guard let window else { return }
    let targetSize = window.contentView?.fittingSize ?? NSSize(width: UpdateBubbleLayout.defaultWidth, height: 180)
    let height = min(max(targetSize.height, 150), 360)
    let workArea = (petWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let frame = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: preferences.bubbleFollowPet,
      bubbleSize: CGSize(width: UpdateBubbleLayout.defaultWidth, height: height),
      workArea: workArea,
      petFrame: petWindow?.frame,
      reservedHeight: reservedHeight,
      hudReservedOffset: hudReservedOffset
    )
    window.setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height), display: true)
  }

  private func buildView(_ payload: UpdateBubblePayload) -> NSView {
    let root = NSStackView()
    root.orientation = .vertical
    root.spacing = 10
    root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
    root.widthAnchor.constraint(equalToConstant: UpdateBubbleLayout.defaultWidth).isActive = true

    let titleRow = NSStackView()
    titleRow.orientation = .horizontal
    titleRow.spacing = 8
    titleRow.alignment = .centerY
    let icon = NSTextField(labelWithString: iconText(for: payload.mode))
    icon.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
    titleRow.addArrangedSubview(icon)
    let title = NSTextField(labelWithString: payload.title)
    title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    title.lineBreakMode = .byWordWrapping
    title.maximumNumberOfLines = 2
    titleRow.addArrangedSubview(title)
    root.addArrangedSubview(titleRow)

    let message = NSTextField(labelWithString: payload.message)
    message.font = NSFont.systemFont(ofSize: 12)
    message.textColor = .secondaryLabelColor
    message.lineBreakMode = .byWordWrapping
    message.maximumNumberOfLines = 4
    root.addArrangedSubview(message)

    if let detail = payload.detail, !detail.isEmpty {
      let detailField = NSTextField(labelWithString: detail)
      detailField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
      detailField.textColor = .tertiaryLabelColor
      detailField.lineBreakMode = .byTruncatingTail
      detailField.maximumNumberOfLines = 4
      root.addArrangedSubview(detailField)
    }

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.alignment = .centerY
    buttons.addArrangedSubview(NSView())
    let dismiss = NSButton(title: payload.secondaryTitle ?? "Dismiss", target: self, action: payload.secondaryTitle == nil ? #selector(dismissAction) : #selector(secondary))
    buttons.addArrangedSubview(dismiss)
    if let primaryTitle = payload.primaryTitle {
      let primary = NSButton(title: primaryTitle, target: self, action: #selector(primary))
      primary.keyEquivalent = "\r"
      buttons.addArrangedSubview(primary)
    }
    root.addArrangedSubview(buttons)

    return root
  }

  private func iconText(for mode: UpdateBubblePayload.Mode) -> String {
    switch mode {
    case .info:
      return "i"
    case .success:
      return "OK"
    case .error:
      return "!"
    }
  }
}
