import AppKit
import ClawdNativeCore

@MainActor
final class PetWindowController: NSWindowController {
  private let themeRuntime: ThemeRuntime
  private let petView: PetAssetView
  private let preferencesStore: PreferencesStore
  private var subscription: UUID?
  private var currentSnapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
  private var applyingPreferenceFrame = false
  private var forceImmediatePreferenceFrame = false
  private var petDragInProgress = false
  private var miniPeekActive = false
  private var windowAnimationTask: Task<Void, Never>?
  var frameDidChange: (() -> Void)?
  var petClicked: (() -> Void)?
  var isMiniTransitioning: Bool {
    windowAnimationTask != nil
  }
  var currentHitFrameOnScreen: NSRect? {
    guard let window,
          let hitRect = petView.currentHitRect()
    else { return nil }
    return window.convertToScreen(petView.convert(hitRect, to: nil))
  }

  init(engine: StateEngine, preferencesStore: PreferencesStore, projectRoot: URL) {
    self.preferencesStore = preferencesStore
    let runtime = ThemeRuntime(projectRoot: projectRoot)
    self.themeRuntime = runtime
    self.petView = PetAssetView(
      frame: NSRect(x: 0, y: 0, width: 180, height: 180),
      themeRuntime: runtime,
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
    FloatingWindowPolicy.applyPersistentOverlay(to: window)
    window.ignoresMouseEvents = false
    window.hasShadow = false
    window.isMovableByWindowBackground = false
    super.init(window: window)
    petView.dragDidStart = { [weak self] in
      self?.petDragInProgress = true
    }
    petView.dragDidEnd = { [weak self] in
      self?.petDragInProgress = false
      self?.frameDidChange?()
      guard self?.snapToMiniModeIfNeeded() != true else { return }
      self?.savePosition()
    }
    petView.miniHoverChanged = { [weak self] hovering in
      self?.setMiniPeek(hovering)
    }
    petView.petClicked = { [weak self] in
      self?.petClicked?()
    }
    window.contentView = petView
    subscription = engine.subscribe { [weak self] snapshot in
      DispatchQueue.main.async {
        self?.currentSnapshot = snapshot
        self?.petView.snapshot = snapshot
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidMove),
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

  @objc private func windowDidMove() {
    syncMiniClip()
    frameDidChange?()
    savePosition()
  }

  private func savePosition() {
    if applyingPreferenceFrame { return }
    if petDragInProgress { return }
    guard let frame = window?.frame else { return }
    let prefs = preferencesStore.get()
    if prefs.miniMode { return }
    _ = try? preferencesStore.update { prefs in
      prefs.x = frame.origin.x
      prefs.y = frame.origin.y
      prefs.positionSaved = true
      prefs.savedPixelWidth = frame.width
      prefs.savedPixelHeight = frame.height
      prefs.positionThemeId = prefs.theme
      prefs.positionVariantId = prefs.themeVariant[prefs.theme] ?? "default"
      prefs.positionDisplay = Self.displaySnapshot(window?.screen)
    }
  }

  @objc private func preferencesDidChange() {
    let animated = !forceImmediatePreferenceFrame
    forceImmediatePreferenceFrame = false
    applyWindowPreferences(animated: animated)
  }

  func playIdleAnimation(fileName: String, durationMs: Int) {
    petView.playIdleAnimation(fileName: fileName, durationMs: durationMs)
  }

  func clearIdleAnimation() {
    petView.clearIdleAnimation()
  }

  @discardableResult
  func toggleMiniFromMenu() -> Bool {
    let prefs = preferencesStore.get()
    guard !prefs.disableMiniMode else { return prefs.miniMode }
    if prefs.miniMode {
      exitMiniModeViaMenu(preferences: prefs)
      return false
    }
    guard themeSupportsMini(preferences: prefs) else { return false }
    enterMiniModeViaMenu(preferences: prefs)
    return true
  }

  private func applyWindowPreferences(animated: Bool) {
    guard let window else { return }
    let prefs = preferencesStore.get()
    let mini = prefs.miniMode && !prefs.disableMiniMode
    let targetSize = mini ? NSSize(width: 112, height: 112) : NSSize(width: 180, height: 180)
    if !mini {
      miniPeekActive = false
      petView.setMiniPeekActive(false)
      petView.setMiniClip(nil)
    }
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
      let offsetRatio = miniOffsetRatio(preferences: prefs)
      if prefs.miniEdge == "left" {
        origin = NSPoint(x: visible.minX - targetSize.width * offsetRatio, y: y)
      } else {
        origin = NSPoint(x: visible.maxX - targetSize.width * (1 - offsetRatio), y: y)
      }
    } else if let x = prefs.preMiniX, let y = prefs.preMiniY {
      origin = NSPoint(x: x, y: y)
    } else if prefs.positionSaved {
      origin = NSPoint(x: prefs.x, y: prefs.y)
    }
    var frame = clamp(NSRect(origin: origin, size: targetSize), visible: visible, allowEdgePinning: prefs.allowEdgePinning || mini)
    if miniPeekActive,
       mini,
       let edge = MiniModeLayout.Edge(rawValue: prefs.miniEdge) {
      frame = MiniModeLayout.peekFrame(miniFrame: frame, edge: edge, peeking: true)
    }
    applyingPreferenceFrame = true
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(frame, display: true)
      } completionHandler: { [weak self] in
        Task { @MainActor in
          self?.applyingPreferenceFrame = false
          self?.syncMiniClip()
          self?.frameDidChange?()
        }
      }
    } else {
      window.setFrame(frame, display: true)
      syncMiniClip()
      applyingPreferenceFrame = false
      frameDidChange?()
    }
  }

  @discardableResult
  private func snapToMiniModeIfNeeded() -> Bool {
    guard let window else { return false }
    let prefs = preferencesStore.get()
    guard !prefs.miniMode,
          !prefs.disableMiniMode,
          themeSupportsMini(preferences: prefs)
    else { return false }
    let ratio = miniOffsetRatio(preferences: prefs)
    guard let snap = MiniModeLayout.snapResult(
      windowFrame: window.frame,
      workAreas: NSScreen.screens.map(\.visibleFrame),
      miniSize: NSSize(width: 112, height: 112),
      offsetRatio: ratio
    ) else { return false }
    _ = try? preferencesStore.update { next in
      next.miniMode = true
      next.miniEdge = snap.edge.rawValue
      next.preMiniX = Double(snap.preMiniOrigin.x)
      next.preMiniY = Double(snap.preMiniOrigin.y)
    }
    return true
  }

  private func setMiniPeek(_ active: Bool) {
    guard let window else { return }
    let prefs = preferencesStore.get()
    guard prefs.miniMode,
          !prefs.disableMiniMode,
          !petDragInProgress,
          let edge = MiniModeLayout.Edge(rawValue: prefs.miniEdge),
          miniPeekActive != active
    else { return }

    miniPeekActive = active
    petView.setMiniPeekActive(active)
    let frame = MiniModeLayout.peekFrame(miniFrame: window.frame, edge: edge, peeking: active)
    applyingPreferenceFrame = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.20
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().setFrame(frame, display: true)
    } completionHandler: { [weak self] in
      Task { @MainActor in
        self?.applyingPreferenceFrame = false
        self?.syncMiniClip()
        self?.frameDidChange?()
      }
    }
  }

  private func enterMiniModeViaMenu(preferences prefs: Preferences) {
    guard let window else { return }
    windowAnimationTask?.cancel()
    windowAnimationTask = nil
    miniPeekActive = false
    petView.setMiniPeekActive(false)

    let sourceFrame = window.frame
    let screen = screenForMiniFrame(sourceFrame) ?? window.screen ?? NSScreen.main
    guard let screen else { return }
    let workArea = screen.visibleFrame
    let edge = MiniModeLayout.menuEntryEdge(windowFrame: sourceFrame, workArea: workArea)
    let displays = NSScreen.screens.map {
      MiniModeLayout.DisplayGeometry(bounds: $0.frame, workArea: $0.visibleFrame)
    }
    let adjacent = MiniModeLayout.seamBoundary(
      workArea: workArea,
      yMid: sourceFrame.midY,
      edge: edge,
      displays: displays
    ) != nil
    let crabwalkFrame = MiniModeLayout.crabwalkFrame(
      windowFrame: sourceFrame,
      workArea: workArea,
      edge: edge,
      adjacentSeam: adjacent
    )
    let ratio = miniOffsetRatio(preferences: prefs)
    let miniFrame = MiniModeLayout.miniFrame(
      edge: edge,
      workArea: workArea,
      sourceFrame: crabwalkFrame,
      miniSize: NSSize(width: 112, height: 112),
      offsetRatio: ratio
    )
    let jumpFrame = MiniModeLayout.menuJumpFrame(
      crabwalkFrame: crabwalkFrame,
      miniFrame: miniFrame,
      edge: edge,
      displays: displays,
      adjacentSeam: adjacent
    )
    let durationMs = MiniModeLayout.crabwalkDurationMs(from: sourceFrame, to: crabwalkFrame)
    applyingPreferenceFrame = true
    petView.playTemporaryState(.miniCrabwalk, durationMs: durationMs + MiniModeLayout.defaultJumpDurationMs + 250)
    animateWindowX(to: crabwalkFrame.minX, durationMs: durationMs) { [weak self] in
      guard let self else { return }
      self.animateWindowParabola(to: jumpFrame, durationMs: MiniModeLayout.defaultJumpDurationMs) { [weak self] in
        guard let self else { return }
        self.forceImmediatePreferenceFrame = true
        let enterState: ClawdState = self.currentSnapshot.currentState.isSleepSequence ? .miniEnterSleep : .miniEnter
        self.petView.playTemporaryState(enterState, durationMs: 1400)
        _ = try? self.preferencesStore.update { next in
          next.miniMode = true
          next.miniEdge = edge.rawValue
          next.preMiniX = Double(sourceFrame.minX)
          next.preMiniY = Double(sourceFrame.minY)
        }
      }
    }
  }

  private func exitMiniModeViaMenu(preferences prefs: Preferences) {
    guard let window else { return }
    windowAnimationTask?.cancel()
    windowAnimationTask = nil
    miniPeekActive = false
    petView.setMiniPeekActive(false)

    let normalSize = NSSize(width: 180, height: 180)
    let preMiniOrigin = NSPoint(
      x: prefs.preMiniX ?? prefs.x,
      y: prefs.preMiniY ?? prefs.y
    )
    let preMiniFrame = NSRect(origin: preMiniOrigin, size: normalSize)
    let screen = screenForMiniFrame(preMiniFrame) ?? window.screen ?? NSScreen.main
    let workArea = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let targetFrame = MiniModeLayout.exitFrame(
      preMiniOrigin: preMiniOrigin,
      workArea: workArea,
      normalSize: normalSize
    )
    applyingPreferenceFrame = true
    animateWindowParabola(to: targetFrame, durationMs: MiniModeLayout.defaultJumpDurationMs) { [weak self] in
      guard let self else { return }
      self.forceImmediatePreferenceFrame = true
      _ = try? self.preferencesStore.update { next in
        next.miniMode = false
        next.preMiniX = Double(targetFrame.minX)
        next.preMiniY = Double(targetFrame.minY)
        next.x = targetFrame.minX
        next.y = targetFrame.minY
        next.positionSaved = true
        next.savedPixelWidth = targetFrame.width
        next.savedPixelHeight = targetFrame.height
        next.positionThemeId = next.theme
        next.positionVariantId = next.themeVariant[next.theme] ?? "default"
        next.positionDisplay = Self.displaySnapshot(screen)
      }
    }
  }

  private func animateWindowX(to targetX: CGFloat, durationMs: Int, completion: @escaping @MainActor @Sendable () -> Void) {
    guard let window else {
      completion()
      return
    }
    windowAnimationTask?.cancel()
    windowAnimationTask = nil
    let startFrame = window.frame
    let duration = max(Double(durationMs) / 1000, 0)
    guard duration > 0, startFrame.minX != targetX else {
      var frame = startFrame
      frame.origin.x = targetX
      window.setFrame(frame, display: true)
      syncMiniClip()
      frameDidChange?()
      completion()
      return
    }
    let startTime = Date()
    windowAnimationTask = Task { @MainActor [weak self] in
      while true {
        guard let self, let window = self.window, !Task.isCancelled else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let t = min(1, max(0, elapsed / duration))
        let eased = t * (2 - t)
        var frame = startFrame
        frame.origin.x = startFrame.minX + (targetX - startFrame.minX) * eased
        window.setFrame(frame, display: true)
        self.syncMiniClip()
        self.frameDidChange?()
        if t >= 1 {
          self.windowAnimationTask = nil
          completion()
          return
        }
        try? await Task.sleep(nanoseconds: 16_666_667)
      }
    }
  }

  private func animateWindowParabola(to targetFrame: NSRect, durationMs: Int, completion: @escaping @MainActor @Sendable () -> Void) {
    guard let window else {
      completion()
      return
    }
    windowAnimationTask?.cancel()
    windowAnimationTask = nil
    let startFrame = window.frame
    let duration = max(Double(durationMs) / 1000, 0)
    guard duration > 0 else {
      window.setFrame(targetFrame, display: true)
      syncMiniClip()
      frameDidChange?()
      completion()
      return
    }
    let startTime = Date()
    windowAnimationTask = Task { @MainActor [weak self] in
      while true {
        guard let self, let window = self.window, !Task.isCancelled else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let t = min(1, max(0, elapsed / duration))
        let eased = t * (2 - t)
        let arc = -4 * MiniModeLayout.defaultJumpPeakHeight * CGFloat(t) * CGFloat(t - 1)
        var frame = startFrame
        frame.origin.x = startFrame.minX + (targetFrame.minX - startFrame.minX) * eased
        frame.origin.y = startFrame.minY + (targetFrame.minY - startFrame.minY) * eased + arc
        frame.size = NSSize(
          width: startFrame.width + (targetFrame.width - startFrame.width) * eased,
          height: startFrame.height + (targetFrame.height - startFrame.height) * eased
        )
        window.setFrame(frame, display: true)
        self.syncMiniClip()
        self.frameDidChange?()
        if t >= 1 {
          self.windowAnimationTask = nil
          window.setFrame(targetFrame, display: true)
          self.syncMiniClip()
          self.frameDidChange?()
          completion()
          return
        }
        try? await Task.sleep(nanoseconds: 16_666_667)
      }
    }
  }

  private func syncMiniClip() {
    guard let window else {
      petView.setMiniClip(nil)
      return
    }
    let prefs = preferencesStore.get()
    guard prefs.miniMode,
          !prefs.disableMiniMode,
          let edge = MiniModeLayout.Edge(rawValue: prefs.miniEdge)
    else {
      petView.setMiniClip(nil)
      return
    }
    let screen = screenForMiniFrame(window.frame) ?? window.screen ?? NSScreen.main
    guard let screen else {
      petView.setMiniClip(nil)
      return
    }
    let displays = NSScreen.screens.map {
      MiniModeLayout.DisplayGeometry(bounds: $0.frame, workArea: $0.visibleFrame)
    }
    guard let boundary = MiniModeLayout.seamBoundary(
      workArea: screen.visibleFrame,
      yMid: window.frame.midY,
      edge: edge,
      displays: displays
    ) else {
      petView.setMiniClip(nil)
      return
    }
    petView.setMiniClip(MiniModeLayout.clip(
      miniFrame: window.frame,
      edge: edge,
      seamBoundary: boundary
    ))
  }

  private func screenForMiniFrame(_ frame: NSRect) -> NSScreen? {
    let center = NSPoint(x: frame.midX, y: frame.midY)
    if let containing = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
      return containing
    }
    return NSScreen.screens.min { lhs, rhs in
      distanceSquared(from: center, to: lhs.visibleFrame) < distanceSquared(from: center, to: rhs.visibleFrame)
    }
  }

  private func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
    let clampedX = min(max(point.x, rect.minX), rect.maxX)
    let clampedY = min(max(point.y, rect.minY), rect.maxY)
    let dx = point.x - clampedX
    let dy = point.y - clampedY
    return dx * dx + dy * dy
  }

  private func themeSupportsMini(preferences prefs: Preferences) -> Bool {
    let variant = prefs.themeVariant[prefs.theme] ?? "default"
    let miniMode = (try? themeRuntime.loadTheme(
      id: prefs.theme,
      variantId: variant,
      overrides: prefs.themeOverrides[prefs.theme]
    ))?.manifest.miniMode
    return miniMode?.supported != false
  }

  private func miniOffsetRatio(preferences prefs: Preferences) -> CGFloat {
    let variant = prefs.themeVariant[prefs.theme] ?? "default"
    let ratio = (try? themeRuntime.loadTheme(
      id: prefs.theme,
      variantId: variant,
      overrides: prefs.themeOverrides[prefs.theme]
    ))?.manifest.miniMode?.offsetRatio ?? 0.486
    guard ratio.isFinite else { return 0.486 }
    return CGFloat(min(max(ratio, 0), 1))
  }

  private static func defaultOrigin() -> NSPoint {
    guard let screen = NSScreen.main else { return NSPoint(x: 120, y: 120) }
    return NSPoint(
      x: screen.visibleFrame.maxX - 240,
      y: screen.visibleFrame.minY + 120
    )
  }

  private func clamp(_ frame: NSRect, visible: NSRect, allowEdgePinning: Bool) -> NSRect {
    let margin: CGFloat = allowEdgePinning ? min(frame.width, frame.height) * 0.45 : 8
    let minX = visible.minX + (allowEdgePinning ? -frame.width + margin : 8)
    let maxX = visible.maxX - (allowEdgePinning ? margin : frame.width + 8)
    let minY = visible.minY + (allowEdgePinning ? -frame.height + margin : 8)
    let maxY = visible.maxY - (allowEdgePinning ? margin : frame.height + 8)
    return NSRect(
      x: min(max(frame.origin.x, minX), maxX),
      y: min(max(frame.origin.y, minY), maxY),
      width: frame.width,
      height: frame.height
    )
  }

  private static func displaySnapshot(_ screen: NSScreen?) -> JSONValue? {
    guard let screen else { return nil }
    let frame = screen.frame
    let visible = screen.visibleFrame
    return .object([
      "id": .number(Double(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0)),
      "scaleFactor": .number(Double(screen.backingScaleFactor)),
      "bounds": .object([
        "x": .number(Double(frame.origin.x)),
        "y": .number(Double(frame.origin.y)),
        "width": .number(Double(frame.width)),
        "height": .number(Double(frame.height))
      ]),
      "workArea": .object([
        "x": .number(Double(visible.origin.x)),
        "y": .number(Double(visible.origin.y)),
        "width": .number(Double(visible.width)),
        "height": .number(Double(visible.height))
      ])
    ])
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
