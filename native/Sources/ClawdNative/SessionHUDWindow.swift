import AppKit
import ClawdNativeCore

@MainActor
final class SessionHUDWindowController: NSWindowController {
  private let preferences: () -> Preferences
  private let petWindow: () -> NSWindow?
  private let petHitFrame: () -> NSRect?
  private let isMiniTransitioning: () -> Bool
  private let focusManager: TerminalFocusManager
  private let hideGraceSeconds: TimeInterval
  private let autoHidePollSeconds: TimeInterval
  private let stack = NSStackView()
  private var subscription: UUID?
  private var lastSnapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
  private var clickRevealed = false
  private var visibleHoldUntil: TimeInterval = 0
  private var autoHidePollTimer: Timer?
  var frameDidChange: (() -> Void)?
  var reservedOffset: CGFloat {
    guard let window, window.isVisible else { return 0 }
    return window.frame.height + 18
  }

  init(
    engine: StateEngine,
    preferences: @escaping () -> Preferences,
    petWindow: @escaping () -> NSWindow?,
    petHitFrame: @escaping () -> NSRect? = { nil },
    isMiniTransitioning: @escaping () -> Bool = { false },
    hideGraceSeconds: TimeInterval = SessionHUDEligibility.defaultHideGraceSeconds,
    autoHidePollSeconds: TimeInterval = SessionHUDEligibility.defaultAutoHidePollSeconds,
    focusManager: TerminalFocusManager
  ) {
    self.preferences = preferences
    self.petWindow = petWindow
    self.petHitFrame = petHitFrame
    self.isMiniTransitioning = isMiniTransitioning
    self.hideGraceSeconds = hideGraceSeconds
    self.autoHidePollSeconds = autoHidePollSeconds
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
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .fullScreenDisallowsTiling]
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesDidChange),
      name: .clawdNativePreferencesDidChange,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    stack.frame = window?.contentView?.bounds ?? .zero
  }

  func refresh() {
    render(lastSnapshot)
  }

  func revealFromPet() {
    let prefs = preferences()
    guard baseEligible(snapshot: lastSnapshot, preferences: prefs) else { return }
    guard !prefs.sessionHudPinned else { return }
    visibleHoldUntil = Date().timeIntervalSince1970 + hideGraceSeconds
    if clickRevealed {
      startAutoHidePoll(preferences: prefs)
      return
    }
    clickRevealed = true
    render(lastSnapshot)
    startAutoHidePoll(preferences: prefs)
  }

  @objc private func preferencesDidChange() {
    if preferences().sessionHudPinned {
      clearReveal()
    }
    refresh()
  }

  private func render(_ snapshot: StateSnapshot) {
    lastSnapshot = snapshot
    let prefs = preferences()
    if !baseEligible(snapshot: snapshot, preferences: prefs) {
      clearReveal()
      window?.orderOut(nil)
      frameDidChange?()
      return
    }
    if !prefs.sessionHudPinned && clickRevealed {
      _ = evaluateAutoHideCursorNow(preferences: prefs, syncOnChange: false)
    } else {
      syncAutoHidePollLifecycle(preferences: prefs)
    }
    guard SessionHUDEligibility.shouldShow(
      snapshot: snapshot,
      sessionHudEnabled: prefs.sessionHudEnabled,
      sessionHudPinned: prefs.sessionHudPinned,
      clickRevealed: clickRevealed,
      petHidden: petWindow()?.isVisible != true,
      miniMode: prefs.miniMode && !prefs.disableMiniMode,
      miniTransitioning: isMiniTransitioning()
    ) else {
      window?.orderOut(nil)
      frameDidChange?()
      return
    }
    let sessions = SessionHUDEligibility.visibleSessions(in: snapshot)
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
    syncAutoHidePollLifecycle(preferences: prefs, evaluateImmediately: true)
    frameDidChange?()
  }

  private func baseEligible(snapshot: StateSnapshot, preferences prefs: Preferences) -> Bool {
    SessionHUDEligibility.isBaseEligible(
      snapshot: snapshot,
      sessionHudEnabled: prefs.sessionHudEnabled,
      petHidden: petWindow()?.isVisible != true,
      miniMode: prefs.miniMode && !prefs.disableMiniMode,
      miniTransitioning: isMiniTransitioning()
    )
  }

  private func clearReveal() {
    stopAutoHidePoll()
    clickRevealed = false
    visibleHoldUntil = 0
  }

  private func isAutoHidePollingNeeded(preferences prefs: Preferences) -> Bool {
    guard baseEligible(snapshot: lastSnapshot, preferences: prefs) else { return false }
    guard !prefs.sessionHudPinned else { return false }
    return clickRevealed
  }

  private func syncAutoHidePollLifecycle(preferences prefs: Preferences, evaluateImmediately: Bool = false) {
    if isAutoHidePollingNeeded(preferences: prefs) {
      startAutoHidePoll(preferences: prefs, evaluateImmediately: evaluateImmediately)
    } else {
      stopAutoHidePoll()
    }
  }

  private func startAutoHidePoll(preferences prefs: Preferences, evaluateImmediately: Bool = false) {
    guard isAutoHidePollingNeeded(preferences: prefs) else {
      stopAutoHidePoll()
      return
    }
    if evaluateImmediately {
      _ = evaluateAutoHideCursorNow(preferences: prefs, syncOnChange: false)
      guard isAutoHidePollingNeeded(preferences: prefs) else { return }
    }
    guard autoHidePollTimer == nil else { return }
    let interval = autoHidePollSeconds.isFinite ? max(0.05, autoHidePollSeconds) : SessionHUDEligibility.defaultAutoHidePollSeconds
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        _ = self.evaluateAutoHideCursorNow(preferences: self.preferences(), syncOnChange: true)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    autoHidePollTimer = timer
  }

  private func stopAutoHidePoll() {
    autoHidePollTimer?.invalidate()
    autoHidePollTimer = nil
  }

  @discardableResult
  private func evaluateAutoHideCursorNow(preferences prefs: Preferences, syncOnChange: Bool) -> Bool {
    guard isAutoHidePollingNeeded(preferences: prefs) else {
      stopAutoHidePoll()
      return false
    }
    let hotZone = SessionHUDEligibility.makeAutoHideHotZone(
      petHitFrame: petHitFrame() ?? petWindow()?.frame,
      hudFrame: window?.frame,
      padding: SessionHUDEligibility.defaultHotZonePadding
    )
    let inHotZone = SessionHUDEligibility.pointInHotZone(NSEvent.mouseLocation, hotZone: hotZone)
    let result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: lastSnapshot,
      sessionHudEnabled: prefs.sessionHudEnabled,
      sessionHudPinned: prefs.sessionHudPinned,
      clickRevealed: clickRevealed,
      inHotZone: inHotZone,
      now: Date().timeIntervalSince1970,
      visibleHoldUntil: visibleHoldUntil,
      hideGraceSeconds: hideGraceSeconds,
      petHidden: petWindow()?.isVisible != true,
      miniMode: prefs.miniMode && !prefs.disableMiniMode,
      miniTransitioning: isMiniTransitioning()
    )
    visibleHoldUntil = result.nextHoldUntil
    if clickRevealed, !result.show, !prefs.sessionHudPinned {
      clickRevealed = false
      visibleHoldUntil = 0
      stopAutoHidePoll()
      if syncOnChange {
        render(lastSnapshot)
      }
      return true
    }
    return false
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
