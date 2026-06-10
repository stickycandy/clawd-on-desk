import AppKit
import ClawdNativeCore

@MainActor
final class PetWindowController: NSWindowController {
  private let petView: PetAssetView
  private let preferencesStore: PreferencesStore
  private var subscription: UUID?
  private var applyingPreferenceFrame = false

  init(engine: StateEngine, preferencesStore: PreferencesStore, projectRoot: URL) {
    self.preferencesStore = preferencesStore
    self.petView = PetAssetView(
      frame: NSRect(x: 0, y: 0, width: 180, height: 180),
      themeRuntime: ThemeRuntime(projectRoot: projectRoot),
      preferences: { preferencesStore.get() }
    )
    let prefs = preferencesStore.get()
    let origin = prefs.positionSaved ? NSPoint(x: prefs.x, y: prefs.y) : PetWindowController.defaultOrigin()
    let window = NSWindow(
      contentRect: NSRect(origin: origin, size: NSSize(width: 180, height: 180)),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    window.ignoresMouseEvents = false
    window.hasShadow = false
    window.isMovableByWindowBackground = true
    super.init(window: window)
    window.contentView = petView
    subscription = engine.subscribe { [weak self] snapshot in
      DispatchQueue.main.async {
        self?.petView.snapshot = snapshot
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(savePosition),
      name: NSWindow.didMoveNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesDidChange),
      name: .clawdNativePreferencesDidChange,
      object: nil
    )
    applyWindowPreferences(animated: false)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func savePosition() {
    if applyingPreferenceFrame { return }
    guard let frame = window?.frame else { return }
    let prefs = preferencesStore.get()
    if prefs.miniMode { return }
    _ = try? preferencesStore.update { prefs in
      prefs.x = frame.origin.x
      prefs.y = frame.origin.y
      prefs.positionSaved = true
    }
  }

  @objc private func preferencesDidChange() {
    applyWindowPreferences(animated: true)
  }

  private func applyWindowPreferences(animated: Bool) {
    guard let window else { return }
    let prefs = preferencesStore.get()
    let mini = prefs.miniMode && !prefs.disableMiniMode
    let targetSize = mini ? NSSize(width: 112, height: 112) : NSSize(width: 180, height: 180)
    let screen = window.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    var origin = window.frame.origin
    if mini {
      if prefs.preMiniX == nil || prefs.preMiniY == nil {
        _ = try? preferencesStore.update { next in
          next.preMiniX = window.frame.origin.x
          next.preMiniY = window.frame.origin.y
        }
      }
      let y = min(max(window.frame.midY - targetSize.height / 2, visible.minY + 20), visible.maxY - targetSize.height - 20)
      if prefs.miniEdge == "left" {
        origin = NSPoint(x: visible.minX - targetSize.width * 0.45, y: y)
      } else {
        origin = NSPoint(x: visible.maxX - targetSize.width * 0.55, y: y)
      }
    } else if let x = prefs.preMiniX, let y = prefs.preMiniY {
      origin = NSPoint(x: x, y: y)
    } else if prefs.positionSaved {
      origin = NSPoint(x: prefs.x, y: prefs.y)
    }
    let frame = NSRect(origin: origin, size: targetSize)
    applyingPreferenceFrame = true
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      } completionHandler: { [weak self] in
        Task { @MainActor in
          self?.applyingPreferenceFrame = false
        }
      }
    } else {
      window.setFrame(frame, display: true)
      applyingPreferenceFrame = false
    }
  }

  private static func defaultOrigin() -> NSPoint {
    guard let screen = NSScreen.main else { return NSPoint(x: 120, y: 120) }
    return NSPoint(
      x: screen.visibleFrame.maxX - 240,
      y: screen.visibleFrame.minY + 120
    )
  }
}

@MainActor
final class PetView: NSView {
  var eyeOffset = NSPoint.zero {
    didSet { needsDisplay = true }
  }

  var snapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date()) {
    didSet { needsDisplay = true }
  }

  override var mouseDownCanMoveWindow: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.clear.setFill()
    dirtyRect.fill()

    let rect = bounds.insetBy(dx: 20, dy: 20)
    drawShadow(in: rect)
    drawBody(in: rect, state: snapshot.currentState)
    drawFace(in: rect, state: snapshot.currentState)
    drawBadge(in: rect)
  }

  private func drawShadow(in rect: NSRect) {
    let shadow = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * 0.18, y: rect.minY + 4, width: rect.width * 0.64, height: 16))
    NSColor.black.withAlphaComponent(0.18).setFill()
    shadow.fill()
  }

  private func drawBody(in rect: NSRect, state: ClawdState) {
    let body = NSBezierPath(roundedRect: NSRect(x: rect.minX + 20, y: rect.minY + 30, width: rect.width - 40, height: rect.height - 56), xRadius: 16, yRadius: 16)
    bodyColor(for: state).setFill()
    body.fill()

    NSColor.black.withAlphaComponent(0.18).setStroke()
    body.lineWidth = 4
    body.stroke()

    drawClaw(x: rect.minX + 12, y: rect.midY - 8, flipped: false, state: state)
    drawClaw(x: rect.maxX - 36, y: rect.midY - 8, flipped: true, state: state)
    drawLegs(in: rect)
  }

  private func drawClaw(x: CGFloat, y: CGFloat, flipped: Bool, state: ClawdState) {
    let claw = NSBezierPath()
    let direction: CGFloat = flipped ? -1 : 1
    claw.move(to: NSPoint(x: x + (flipped ? 24 : 0), y: y))
    claw.curve(to: NSPoint(x: x + 12, y: y + 42), controlPoint1: NSPoint(x: x + direction * 22, y: y + 4), controlPoint2: NSPoint(x: x + 12, y: y + 34))
    claw.curve(to: NSPoint(x: x + (flipped ? 4 : 20), y: y + 20), controlPoint1: NSPoint(x: x + (flipped ? -8 : 32), y: y + 42), controlPoint2: NSPoint(x: x + (flipped ? 0 : 24), y: y + 20))
    bodyColor(for: state).setStroke()
    claw.lineWidth = 8
    claw.lineCapStyle = .round
    claw.stroke()
  }

  private func drawLegs(in rect: NSRect) {
    NSColor(calibratedRed: 0.40, green: 0.19, blue: 0.16, alpha: 1).setStroke()
    for index in 0..<3 {
      let y = rect.minY + 34 + CGFloat(index) * 18
      let left = NSBezierPath()
      left.move(to: NSPoint(x: rect.minX + 44, y: y))
      left.line(to: NSPoint(x: rect.minX + 18, y: y - 10))
      left.lineWidth = 5
      left.lineCapStyle = .round
      left.stroke()
      let right = NSBezierPath()
      right.move(to: NSPoint(x: rect.maxX - 44, y: y))
      right.line(to: NSPoint(x: rect.maxX - 18, y: y - 10))
      right.lineWidth = 5
      right.lineCapStyle = .round
      right.stroke()
    }
  }

  private func drawFace(in rect: NSRect, state: ClawdState) {
    NSColor.white.setFill()
    let leftEye = NSBezierPath(ovalIn: NSRect(x: rect.midX - 34, y: rect.midY + 12, width: 22, height: 26))
    let rightEye = NSBezierPath(ovalIn: NSRect(x: rect.midX + 12, y: rect.midY + 12, width: 22, height: 26))
    leftEye.fill()
    rightEye.fill()

    NSColor.black.setFill()
    let pupilOffset: CGFloat = state == .thinking || state == .working ? 4 : 0
    NSBezierPath(ovalIn: NSRect(x: rect.midX - 25 + pupilOffset + eyeOffset.x, y: rect.midY + 20 - eyeOffset.y, width: 8, height: 10)).fill()
    NSBezierPath(ovalIn: NSRect(x: rect.midX + 21 + pupilOffset + eyeOffset.x, y: rect.midY + 20 - eyeOffset.y, width: 8, height: 10)).fill()

    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: rect.midX - 14, y: rect.midY - 8))
    if state == .error {
      mouth.line(to: NSPoint(x: rect.midX + 14, y: rect.midY - 4))
    } else if state == .attention || state == .miniHappy {
      mouth.curve(to: NSPoint(x: rect.midX + 14, y: rect.midY - 8), controlPoint1: NSPoint(x: rect.midX - 8, y: rect.midY - 22), controlPoint2: NSPoint(x: rect.midX + 8, y: rect.midY - 22))
    } else {
      mouth.curve(to: NSPoint(x: rect.midX + 14, y: rect.midY - 8), controlPoint1: NSPoint(x: rect.midX - 8, y: rect.midY - 14), controlPoint2: NSPoint(x: rect.midX + 8, y: rect.midY - 14))
    }
    mouth.lineWidth = 4
    mouth.lineCapStyle = .round
    NSColor.black.withAlphaComponent(0.70).setStroke()
    mouth.stroke()
  }

  private func drawBadge(in rect: NSRect) {
    guard let top = snapshot.sessions.first(where: { $0.visibleInHUD }) else { return }
    let label = "\(top.metadata.agentId) \(top.badge)"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: NSColor.white
    ]
    let size = label.size(withAttributes: attributes)
    let badgeRect = NSRect(x: bounds.midX - size.width / 2 - 10, y: bounds.maxY - 34, width: size.width + 20, height: 22)
    NSColor.black.withAlphaComponent(0.64).setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
    label.draw(at: NSPoint(x: badgeRect.minX + 10, y: badgeRect.minY + 4), withAttributes: attributes)
  }

  private func bodyColor(for state: ClawdState) -> NSColor {
    switch state {
    case .error:
      return NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.16, alpha: 1)
    case .notification, .miniAlert:
      return NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.12, alpha: 1)
    case .attention, .miniHappy:
      return NSColor(calibratedRed: 0.20, green: 0.68, blue: 0.42, alpha: 1)
    case .working, .thinking, .juggling, .carrying, .sweeping, .miniWorking:
      return NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.78, alpha: 1)
    case .sleeping, .dozing, .collapsing, .yawning, .miniSleep:
      return NSColor(calibratedRed: 0.34, green: 0.38, blue: 0.48, alpha: 1)
    default:
      return NSColor(calibratedRed: 0.70, green: 0.28, blue: 0.20, alpha: 1)
    }
  }
}
