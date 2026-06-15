import AppKit
import ClawdNativeCore
import WebKit

@MainActor
final class PetAssetView: NSView {
  private let themeRuntime: ThemeRuntime
  private let preferences: () -> Preferences
  private var webView: WKWebView
  private let fallbackView = PetView(frame: .zero)
  private let imageView = NSImageView(frame: .zero)
  private let badgeView = PetBadgeView(frame: .zero)
  private var lastAssetKey: String?
  private var activeFileName: String?
  private var activeImageFileName: String?
  private var pendingAssetKey: String?
  private var pendingAsset: ThemeAsset?
  private var pendingDocument: ThemeWebDocument?
  private var pendingWebView: WKWebView?
  private var pendingNavigationDelegate: PetAssetWebNavigationDelegate?
  private var pendingFadeInMs = 0
  private var pendingFadeOutMs = 0
  private var pendingSwapWorkItem: DispatchWorkItem?
  private var fallbackHideWorkItem: DispatchWorkItem?
  private var currentAsset: ThemeAsset?
  private var activeDocument: ThemeWebDocument?
  private var forcedAsset: ThemeAsset?
  private var idleOverrideAsset: ThemeAsset?
  private var reactionResetWorkItem: DispatchWorkItem?
  private var idleResetWorkItem: DispatchWorkItem?
  private var trackingArea: NSTrackingArea?
  private var dragStartMouse: NSPoint?
  private var dragStartFrame: NSRect?
  private var draggingWindow = false
  private var miniPeekActive = false
  private var miniClip: MiniModeLayout.Clip?
  private var appKitEyeOffset = CGSize.zero
  private var webCacheBustSeq = 0
  private var visualTrackingTimer: Timer?
  private var lastCursorScreenPoint: NSPoint?
  private var lastTrackingAssetKey: String?
  private var lastEyeOffset: ThemeAssetGeometry.EyeOffset?
  private var lastPointerPayload: ThemeAssetGeometry.PointerPayload?

  private static let loadingWebAlpha: CGFloat = 0.01

  var dragDidStart: (() -> Void)?
  var dragDidEnd: (() -> Void)?
  var miniHoverChanged: ((Bool) -> Void)?
  var petClicked: (() -> Void)?

  var snapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date()) {
    didSet {
      fallbackView.snapshot = snapshot
      badgeView.snapshot = snapshot
      render()
    }
  }

  init(frame frameRect: NSRect, themeRuntime: ThemeRuntime, preferences: @escaping () -> Preferences) {
    self.themeRuntime = themeRuntime
    self.preferences = preferences
    self.webView = Self.makeWebView(frame: frameRect)
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.wantsLayer = true
    imageView.layer?.backgroundColor = NSColor.clear.cgColor
    imageView.isHidden = true
    addSubview(fallbackView)
    addSubview(imageView)
    addSubview(badgeView)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesDidChange),
      name: .clawdNativePreferencesDidChange,
      object: nil
    )
    startVisualTracking()
    render()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point) else { return nil }
    if let clipRect = miniClipRect(), !clipRect.contains(point) {
      return nil
    }
    guard let asset = currentAsset, let hitRect = hitRect(for: asset) else {
      return self
    }
    return hitRect.contains(point) ? self : nil
  }

  func currentHitRect() -> NSRect? {
    var rect: NSRect
    if let asset = currentAsset, let hitRect = hitRect(for: asset) {
      rect = hitRect
    } else {
      rect = bounds
    }
    if let clipRect = miniClipRect() {
      rect = rect.intersection(clipRect)
    }
    return rect.isNull || rect.isEmpty ? nil : rect
  }

  override func layout() {
    super.layout()
    fallbackView.frame = bounds
    webView.frame = bounds
    if let currentAsset {
      applyImageFrame(for: currentAsset)
    } else {
      imageView.frame = bounds
    }
    pendingWebView?.frame = bounds
    badgeView.frame = bounds
    applyMiniClip()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    trackingArea = area
    addTrackingArea(area)
  }

  @objc private func preferencesDidChange() {
    lastAssetKey = nil
    render()
  }

  private func render() {
    let prefs = preferences()
    let displaySnapshot = miniMappedSnapshot(snapshot, preferences: prefs)
    let variant = prefs.themeVariant[prefs.theme] ?? "default"
    let overrides = prefs.themeOverrides[prefs.theme]
    if displaySnapshot.currentState != .idle, idleOverrideAsset != nil {
      idleResetWorkItem?.cancel()
      idleResetWorkItem = nil
      idleOverrideAsset = nil
    }
    let idleOverride = displaySnapshot.currentState == .idle ? idleOverrideAsset : nil
    guard let asset = forcedAsset ?? idleOverride ?? themeRuntime.resolveAsset(themeId: prefs.theme, snapshot: displaySnapshot, variantId: variant, overrides: overrides),
          FileManager.default.fileExists(atPath: asset.url.path)
    else {
      pendingSwapWorkItem?.cancel()
      pendingSwapWorkItem = nil
      fallbackHideWorkItem?.cancel()
      fallbackHideWorkItem = nil
      removePendingWebView()
      pendingWebView = nil
      pendingAsset = nil
      pendingDocument = nil
      pendingAssetKey = nil
      detachActiveWebView()
      imageView.image = nil
      activeImageFileName = nil
      imageView.isHidden = true
      fallbackView.isHidden = false
      lastAssetKey = nil
      activeFileName = nil
      currentAsset = nil
      activeDocument = nil
      idleOverrideAsset = nil
      appKitEyeOffset = .zero
      resetVisualTrackingDedup()
      return
    }

    currentAsset = asset
    let key = "\(asset.themeId)|\(asset.fileName)|\(asset.state.rawValue)|\(displaySnapshot.sessions.count)|\(forcedAsset?.fileName ?? "")|\(idleOverride?.fileName ?? "")|\(prefs.miniMode)"
    if key == pendingAssetKey {
      return
    }
    if key == lastAssetKey {
      prepareImageFallback(asset, document: activeDocument, fadeInMs: 0)
      if let activeDocument {
        revealWebLayerIfReady(document: activeDocument, fadeInMs: 0)
      }
      updateEyeTracking()
      return
    }
    transition(to: asset, key: key)
  }

  private static func makeWebView(frame: NSRect) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: frame, configuration: config)
    view.setValue(false, forKey: "drawsBackground")
    view.underPageBackgroundColor = .clear
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.isHidden = true
    return view
  }

  private func transition(to asset: ThemeAsset, key: String) {
    pendingSwapWorkItem?.cancel()
    fallbackHideWorkItem?.cancel()
    fallbackHideWorkItem = nil
    removePendingWebView()
    let document = ThemeWebDocumentBuilder.document(for: asset, cacheBust: nextCacheBust())
    if document.usesLayeredTracking {
      fallbackHideWorkItem?.cancel()
      fallbackHideWorkItem = nil
      pendingAsset = nil
      pendingDocument = nil
      pendingAssetKey = nil
      pendingWebView = nil
      currentAsset = asset
      activeDocument = nil
      lastAssetKey = key
      activeFileName = asset.fileName
      detachActiveWebView()
      prepareImageFallback(asset, document: nil, fadeInMs: transitionFadeInMs(for: asset))
      resetVisualTrackingDedup()
      updateEyeTracking()
      return
    }

    let next = Self.makeWebView(frame: bounds)
    next.alphaValue = Self.loadingWebAlpha
    next.isHidden = false
    addSubview(next, positioned: .below, relativeTo: badgeView)

    pendingAsset = asset
    pendingAssetKey = key
    pendingDocument = document
    pendingWebView = next
    pendingFadeInMs = transitionFadeInMs(for: asset)
    pendingFadeOutMs = transitionFadeOutMs(for: activeFileName, manifest: asset.manifest)
    let navigationDelegate = PetAssetWebNavigationDelegate { [weak self, weak next] in
      guard let next else { return }
      self?.completePendingSwap(next)
    }
    pendingNavigationDelegate = navigationDelegate
    next.navigationDelegate = navigationDelegate
    loadWebDocument(document, into: next)

    let work = DispatchWorkItem { [weak self, weak next] in
      guard let next else { return }
      self?.completePendingSwap(next)
    }
    pendingSwapWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
  }

  private func completePendingSwap(_ next: WKWebView) {
    guard pendingWebView === next,
          let asset = pendingAsset,
          let document = pendingDocument,
          let key = pendingAssetKey
    else { return }

    pendingSwapWorkItem?.cancel()
    pendingSwapWorkItem = nil
    pendingWebView = nil
    pendingNavigationDelegate = nil
    next.navigationDelegate = nil
    pendingAsset = nil
    pendingDocument = nil
    pendingAssetKey = nil

    let previous = webView
    webView = next
    currentAsset = asset
    activeDocument = document
    lastAssetKey = key
    resetVisualTrackingDedup()
    activeFileName = asset.fileName
    showRenderedAsset(asset, document: document, fadeInMs: pendingFadeInMs)

    removePreviousWebView(previous, durationMs: pendingFadeOutMs)
    pendingFadeInMs = 0
    pendingFadeOutMs = 0

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
      self?.updateEyeTracking()
    }
  }

  private func animateFadeIn(_ view: NSView, durationMs: Int) {
    guard durationMs > 0 else {
      view.alphaValue = 1
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Double(durationMs) / 1000
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      view.animator().alphaValue = 1
    }
  }

  private func showRenderedAsset(_ asset: ThemeAsset, document: ThemeWebDocument, fadeInMs: Int) {
    prepareImageFallback(asset, document: document, fadeInMs: fadeInMs)
    revealWebLayerIfReady(document: document, fadeInMs: fadeInMs)
  }

  private func prepareImageFallback(_ asset: ThemeAsset, document: ThemeWebDocument?, fadeInMs: Int) {
    let previousFile = activeImageFileName
    if imageView.image == nil || activeImageFileName != asset.fileName {
      if let fallbackSVG = document?.fallbackSVG {
        imageView.image = NSImage(data: Data(fallbackSVG.utf8))
      } else {
        imageView.image = NSImage(contentsOf: asset.url)
      }
      activeImageFileName = asset.fileName
    }
    let changedImage = previousFile != activeImageFileName
    imageView.isHidden = imageView.image == nil
    applyImageFrame(for: asset)
    fallbackView.isHidden = imageView.image != nil
    if changedImage, fadeInMs > 0, imageView.image != nil {
      imageView.alphaValue = 0
      animateFadeIn(imageView, durationMs: fadeInMs)
    } else {
      imageView.alphaValue = 1
    }
  }

  private func revealWebLayerIfReady(document: ThemeWebDocument, fadeInMs: Int, attempt: Int = 0) {
    let candidate = webView
    if document.usesLayeredTracking {
      detachActiveWebView()
      imageView.isHidden = imageView.image == nil
      fallbackView.isHidden = imageView.image != nil
      updateEyeTracking()
      return
    }
    candidate.evaluateJavaScript("window.__clawdNativeReady === true") { [weak self, weak candidate] result, _ in
      DispatchQueue.main.async {
        guard let self,
              let candidate,
              self.webView === candidate,
              self.activeDocument == document
        else { return }
        guard (result as? Bool) == true else {
          if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
              self?.revealWebLayerIfReady(document: document, fadeInMs: fadeInMs, attempt: attempt + 1)
            }
            return
          }
          if document.channel == .inlineSVG {
            candidate.isHidden = true
            candidate.alphaValue = 1
            return
          }
          candidate.isHidden = true
          return
        }
        self.revealCandidateWebLayer(candidate, document: document, fadeInMs: fadeInMs)
      }
    }
  }

  private func revealCandidateWebLayer(_ candidate: WKWebView, document: ThemeWebDocument, fadeInMs: Int) {
    candidate.isHidden = false
    if fadeInMs > 0 && candidate.alphaValue < 1 {
      animateFadeIn(candidate, durationMs: fadeInMs)
    } else {
      candidate.alphaValue = 1
    }
    scheduleFallbackHideAfterWebReveal(candidate, document: document)
    updateEyeTracking()
  }

  private func scheduleFallbackHideAfterWebReveal(_ candidate: WKWebView, document: ThemeWebDocument) {
    fallbackHideWorkItem?.cancel()
    let delayMs = webRevealFallbackGraceMs(for: document)
    let hide = DispatchWorkItem { [weak self, weak candidate] in
      guard let self,
            let candidate,
            self.webView === candidate,
            self.activeDocument == document
      else { return }
      self.imageView.isHidden = true
      self.fallbackView.isHidden = true
    }
    fallbackHideWorkItem = hide
    guard delayMs > 0 else {
      hide.perform()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: hide)
  }

  private func webRevealFallbackGraceMs(for document: ThemeWebDocument) -> Int {
    switch document.channel {
    case .inlineSVG, .objectSVG:
      return 1_800
    case .image:
      return 250
    }
  }

  private func nextCacheBust() -> String {
    webCacheBustSeq += 1
    let millis = Int(Date().timeIntervalSince1970 * 1000)
    return "\(millis)-\(webCacheBustSeq)"
  }

  private func applyImageFrame(for asset: ThemeAsset) {
    let base = ThemeAssetGeometry.mediaFrame(for: asset, in: bounds, imageSize: imageView.image?.size)
    imageView.frame = base.offsetBy(dx: appKitEyeOffset.width, dy: appKitEyeOffset.height)
  }

  private func removePreviousWebView(_ previous: WKWebView, durationMs: Int) {
    guard previous !== webView else { return }
    guard previous.superview != nil else { return }
    if durationMs <= 0 {
      previous.removeFromSuperview()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Double(durationMs) / 1000
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      previous.animator().alphaValue = 0
    } completionHandler: {
      DispatchQueue.main.async {
        previous.removeFromSuperview()
      }
    }
  }

  private func loadWebDocument(_ document: ThemeWebDocument, into view: WKWebView) {
    // A file baseURL leaves WKWebView on about:blank when the native app runs
    // as a SwiftPM executable; generated asset URLs are already absolute.
    view.loadHTMLString(document.html, baseURL: nil)
  }

  private func removePendingWebView() {
    if let pendingWebView {
      pendingWebView.navigationDelegate = nil
      pendingWebView.removeFromSuperview()
    }
    pendingNavigationDelegate = nil
  }

  private func transitionFadeInMs(for asset: ThemeAsset) -> Int {
    max(0, asset.manifest.transitions?[Self.baseName(asset.fileName)]?.fadeIn ?? 0)
  }

  private func transitionFadeOutMs(for fileName: String?, manifest: ThemeManifest) -> Int {
    guard let fileName else { return 0 }
    return max(0, manifest.transitions?[Self.baseName(fileName)]?.fadeOut ?? 0)
  }

  private static func baseName(_ value: String) -> String {
    (value as NSString).lastPathComponent
  }

  override func mouseMoved(with event: NSEvent) {
    updateVisualTracking(force: true)
  }

  override func mouseEntered(with event: NSEvent) {
    updateVisualTracking(force: true)
    miniHoverChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    updateVisualTracking(force: true)
    miniHoverChanged?(false)
  }

  override func mouseDown(with event: NSEvent) {
    dragStartMouse = NSEvent.mouseLocation
    dragStartFrame = window?.frame
    draggingWindow = false
    if event.clickCount >= 4 {
      playReaction("annoyed", side: nil)
    } else if event.clickCount == 2 {
      let side = convert(event.locationInWindow, from: nil).x < bounds.midX ? "left" : "right"
      playReaction(side == "left" ? "clickLeft" : "clickRight", side: side)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    if !draggingWindow {
      draggingWindow = true
      dragDidStart?()
    }
    if forcedAsset == nil {
      playReaction("drag", side: nil, autoReset: false)
    }
    guard let dragStartMouse, let dragStartFrame, let window else { return }
    let current = NSEvent.mouseLocation
    let dx = current.x - dragStartMouse.x
    let dy = current.y - dragStartMouse.y
    window.setFrameOrigin(NSPoint(x: dragStartFrame.minX + dx, y: dragStartFrame.minY + dy))
  }

  override func mouseUp(with event: NSEvent) {
    let completedDrag = draggingWindow
    dragStartMouse = nil
    dragStartFrame = nil
    draggingWindow = false
    if forcedAsset?.fileName.contains("drag") == true {
      clearReaction()
    }
    if completedDrag {
      dragDidEnd?()
    } else {
      petClicked?()
    }
  }

  private func playReaction(_ reaction: String, side: String?, autoReset: Bool = true) {
    let prefs = preferences()
    let theme = prefs.theme
    guard let resolved = themeRuntime.resolveReactionAsset(themeId: theme, reaction: reaction, side: side, variantId: prefs.themeVariant[theme] ?? "default", overrides: prefs.themeOverrides[theme]) else { return }
    reactionResetWorkItem?.cancel()
    forcedAsset = resolved.asset
    lastAssetKey = nil
    render()
    if autoReset {
      let delay = resolved.durationMs ?? 2500
      let work = DispatchWorkItem { [weak self] in
        self?.clearReaction()
      }
      reactionResetWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }
  }

  private func clearReaction() {
    reactionResetWorkItem?.cancel()
    reactionResetWorkItem = nil
    forcedAsset = nil
    lastAssetKey = nil
    render()
  }

  func playIdleAnimation(fileName: String, durationMs: Int) {
    let prefs = preferences()
    let theme = prefs.theme
    guard let asset = themeRuntime.resolveAsset(
      themeId: theme,
      fileName: fileName,
      state: .idle,
      variantId: prefs.themeVariant[theme] ?? "default",
      overrides: prefs.themeOverrides[theme]
    ) else { return }
    idleResetWorkItem?.cancel()
    idleOverrideAsset = asset
    lastAssetKey = nil
    render()
    let work = DispatchWorkItem { [weak self] in
      guard self?.idleOverrideAsset?.fileName == asset.fileName else { return }
      self?.clearIdleAnimation()
    }
    idleResetWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(durationMs, 0)), execute: work)
  }

  func playTemporaryState(_ state: ClawdState, durationMs: Int) {
    let prefs = preferences()
    let theme = prefs.theme
    let snapshot = StateSnapshot(currentState: state, sessions: [], updatedAt: Date())
    guard let asset = themeRuntime.resolveAsset(
      themeId: theme,
      snapshot: snapshot,
      variantId: prefs.themeVariant[theme] ?? "default",
      overrides: prefs.themeOverrides[theme]
    ) else { return }
    reactionResetWorkItem?.cancel()
    forcedAsset = asset
    lastAssetKey = nil
    render()
    let work = DispatchWorkItem { [weak self] in
      guard self?.forcedAsset?.state == state else { return }
      self?.clearReaction()
    }
    reactionResetWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(durationMs, 0)), execute: work)
  }

  func clearIdleAnimation() {
    idleResetWorkItem?.cancel()
    idleResetWorkItem = nil
    guard idleOverrideAsset != nil else { return }
    idleOverrideAsset = nil
    lastAssetKey = nil
    render()
  }

  func setMiniPeekActive(_ active: Bool) {
    guard miniPeekActive != active else { return }
    miniPeekActive = active
    lastAssetKey = nil
    render()
  }

  func setMiniClip(_ clip: MiniModeLayout.Clip?) {
    if miniClip == clip { return }
    miniClip = clip
    applyMiniClip()
  }

  private func startVisualTracking() {
    guard visualTrackingTimer == nil else { return }
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.updateVisualTracking()
      }
    }
    visualTrackingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func resetVisualTrackingDedup() {
    lastCursorScreenPoint = nil
    lastTrackingAssetKey = nil
    lastEyeOffset = nil
    lastPointerPayload = nil
  }

  private func updateVisualTracking(force: Bool = false) {
    guard let asset = currentAsset else { return }
    let cursor = NSEvent.mouseLocation
    let trackingKey = "\(asset.themeId)|\(asset.fileName)|\(asset.state.rawValue)"
    let cursorMoved = lastCursorScreenPoint != cursor
    let assetChanged = lastTrackingAssetKey != trackingKey
    guard force || cursorMoved || assetChanged else { return }
    lastCursorScreenPoint = cursor
    lastTrackingAssetKey = trackingKey

    updateCloudlingPointerBridge(asset: asset, cursor: cursor, force: force || assetChanged)

    guard let windowFrame = window?.frame,
          let eye = ThemeAssetGeometry.eyeOffset(
            for: asset,
            windowFrame: windowFrame,
            viewBounds: bounds,
            cursorScreenPoint: cursor,
            imageSize: imageView.image?.size
          )
    else {
      if force || lastEyeOffset != nil || assetChanged {
        lastEyeOffset = nil
        applyEyeOffset(dx: 0, dy: 0)
      }
      return
    }

    if !force, lastEyeOffset == eye { return }
    lastEyeOffset = eye
    applyEyeOffset(dx: eye.dx, dy: eye.dy)
  }

  private func updateCloudlingPointerBridge(asset: ThemeAsset, cursor: NSPoint, force: Bool) {
    guard usesCloudlingPointerBridge(asset),
          let windowFrame = window?.frame,
          let payload = ThemeAssetGeometry.pointerPayload(
            for: asset,
            windowFrame: windowFrame,
            viewBounds: bounds,
            cursorScreenPoint: cursor,
            imageSize: imageView.image?.size
          )
    else {
      if force || lastPointerPayload != nil {
        lastPointerPayload = nil
        clearCloudlingPointerBridge()
      }
      return
    }
    let displayed = ThemeAssetGeometry.PointerPayload(x: payload.x, y: payload.y, inside: true)
    guard force || pointerPayloadChanged(displayed, lastPointerPayload) else { return }
    lastPointerPayload = displayed
    applyCloudlingPointerBridge(displayed)
  }

  private func usesCloudlingPointerBridge(_ asset: ThemeAsset) -> Bool {
    guard asset.fileName.lowercased().hasSuffix(".svg"),
          asset.manifest.trustedRuntime?.scriptedSvgFiles?.contains(Self.baseName(asset.fileName)) == true
    else { return false }
    return asset.state == .idle || asset.state == .miniIdle || asset.state == .miniPeek
  }

  private func pointerPayloadChanged(_ lhs: ThemeAssetGeometry.PointerPayload, _ rhs: ThemeAssetGeometry.PointerPayload?) -> Bool {
    guard let rhs else { return true }
    return lhs.inside != rhs.inside
      || abs(lhs.x - rhs.x) > 0.01
      || abs(lhs.y - rhs.y) > 0.01
  }

  private func updateEyeTracking() {
    updateVisualTracking(force: true)
  }

  private func miniMappedSnapshot(_ snapshot: StateSnapshot, preferences: Preferences) -> StateSnapshot {
    guard preferences.miniMode, !preferences.disableMiniMode else { return snapshot }
    let mapped: ClawdState
    switch snapshot.currentState {
    case .notification, .error:
      mapped = .miniAlert
    case .attention:
      mapped = .miniHappy
    case .working, .thinking, .juggling, .carrying, .sweeping:
      mapped = .miniWorking
    case .sleeping, .dozing, .collapsing, .yawning:
      mapped = .miniSleep
    default:
      mapped = .miniIdle
    }
    if miniPeekActive, mapped == .miniIdle {
      return StateSnapshot(currentState: .miniPeek, sessions: snapshot.sessions, updatedAt: snapshot.updatedAt)
    }
    return StateSnapshot(currentState: mapped, sessions: snapshot.sessions, updatedAt: snapshot.updatedAt)
  }

  private func applyEyeOffset(dx: CGFloat, dy: CGFloat) {
    fallbackView.eyeOffset = NSPoint(x: dx, y: dy)
    appKitEyeOffset = ThemeAssetGeometry.appKitFallbackEyeOffset(dx: dx, dy: dy)
    if let currentAsset {
      applyImageFrame(for: currentAsset)
    }
    if webView.superview != nil {
      let script = "window.clawdSetEye && window.clawdSetEye(\(Double(dx)), \(Double(dy)), \(Double(dx * 0.25)), \(Double(dy * 0.25)), \(Double(dx * -0.15)), \(Double(dy * -0.05)))"
      webView.evaluateJavaScript(script, completionHandler: nil)
    }
  }

  private func applyCloudlingPointerBridge(_ payload: ThemeAssetGeometry.PointerPayload) {
    guard webView.superview != nil else { return }
    let script = """
    window.__cloudlingSetPointer && window.__cloudlingSetPointer({
      x: \(Double(payload.x)),
      y: \(Double(payload.y)),
      inside: \(payload.inside ? "true" : "false")
    })
    """
    webView.evaluateJavaScript(script, completionHandler: nil)
  }

  private func clearCloudlingPointerBridge() {
    guard webView.superview != nil else { return }
    webView.evaluateJavaScript(
      "window.__cloudlingSetPointer && window.__cloudlingSetPointer({ x: 0, y: 0, inside: false })",
      completionHandler: nil
    )
  }

  private func detachActiveWebView() {
    webView.stopLoading()
    webView.isHidden = true
    webView.alphaValue = 1
    webView.removeFromSuperview()
  }

  private func applyMiniClip() {
    guard let layer else { return }
    guard let clipRect = miniClipRect() else {
      layer.mask = nil
      return
    }
    let mask = CALayer()
    mask.backgroundColor = NSColor.black.cgColor
    mask.frame = clipRect
    layer.mask = mask
  }

  private func miniClipRect() -> NSRect? {
    guard let miniClip else { return nil }
    let fraction = min(max(miniClip.fraction, 0), 1)
    switch miniClip.edge {
    case .left:
      let x = bounds.width * fraction
      return NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height)
    case .right:
      return NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }
  }

  private func hitRect(for asset: ThemeAsset) -> NSRect? {
    let prefs = preferences()
    guard let loaded = try? themeRuntime.loadTheme(id: asset.themeId, variantId: prefs.themeVariant[asset.themeId] ?? "default", overrides: prefs.themeOverrides[asset.themeId]),
          let hitBox = loaded.hitBox(for: asset)
    else { return nil }
    return ThemeAssetGeometry.hitRect(for: asset, hitBox: hitBox, in: bounds, imageSize: imageView.image?.size)
  }
}

@MainActor
private final class PetAssetWebNavigationDelegate: NSObject, WKNavigationDelegate {
  private let completion: () -> Void

  init(completion: @escaping () -> Void) {
    self.completion = completion
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    completion()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    completion()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    completion()
  }
}

@MainActor
final class PetBadgeView: NSView {
  var snapshot = StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date()) {
    didSet { needsDisplay = true }
  }

  override var mouseDownCanMoveWindow: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
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
}
