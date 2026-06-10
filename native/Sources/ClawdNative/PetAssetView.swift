import AppKit
import ClawdNativeCore
import WebKit

@MainActor
final class PetAssetView: NSView {
  private let themeRuntime: ThemeRuntime
  private let preferences: () -> Preferences
  private let webView: WKWebView
  private let fallbackView = PetView(frame: .zero)
  private let badgeView = PetBadgeView(frame: .zero)
  private var lastAssetKey: String?
  private var currentAsset: ThemeAsset?
  private var forcedAsset: ThemeAsset?
  private var reactionResetWorkItem: DispatchWorkItem?
  private var trackingArea: NSTrackingArea?
  private var dragStartMouse: NSPoint?
  private var dragStartFrame: NSRect?

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
    let config = WKWebViewConfiguration()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    self.webView = WKWebView(frame: frameRect, configuration: config)
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    webView.setValue(false, forKey: "drawsBackground")
    webView.wantsLayer = true
    webView.layer?.backgroundColor = NSColor.clear.cgColor
    webView.isHidden = true
    addSubview(fallbackView)
    addSubview(webView)
    addSubview(badgeView)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesDidChange),
      name: .clawdNativePreferencesDidChange,
      object: nil
    )
    render()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var mouseDownCanMoveWindow: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let asset = currentAsset, let hitRect = hitRect(for: asset) else {
      return super.hitTest(point)
    }
    return hitRect.contains(point) ? super.hitTest(point) : nil
  }

  override func layout() {
    super.layout()
    fallbackView.frame = bounds
    webView.frame = bounds
    badgeView.frame = bounds
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
    guard let asset = forcedAsset ?? themeRuntime.resolveAsset(themeId: prefs.theme, snapshot: displaySnapshot),
          FileManager.default.fileExists(atPath: asset.url.path)
    else {
      webView.isHidden = true
      fallbackView.isHidden = false
      lastAssetKey = nil
      currentAsset = nil
      return
    }

    currentAsset = asset
    let key = "\(asset.themeId)|\(asset.fileName)|\(asset.state.rawValue)|\(displaySnapshot.sessions.count)|\(forcedAsset?.fileName ?? "")|\(prefs.miniMode)"
    if key == lastAssetKey {
      webView.isHidden = false
      fallbackView.isHidden = true
      updateEyeTracking()
      return
    }
    lastAssetKey = key
    webView.isHidden = false
    fallbackView.isHidden = true
    webView.loadHTMLString(Self.html(for: asset), baseURL: asset.readAccessURL)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
      self?.updateEyeTracking()
    }
  }

  private static func html(for asset: ThemeAsset) -> String {
    let url = asset.url.absoluteString
    let bustedURL = "\(url)?_t=\(Int(Date().timeIntervalSince1970 * 1000))"
    let escaped = bustedURL
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
    let tag: String
    if asset.fileName.lowercased().hasSuffix(".svg") {
      tag = #"<object id="asset" data="\#(escaped)" type="image/svg+xml"></object>"#
    } else {
      tag = #"<img id="asset" src="\#(escaped)" />"#
    }
    return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        html, body {
          width: 100%;
          height: 100%;
          margin: 0;
          overflow: hidden;
          background: transparent;
        }
        #asset {
          display: block;
          width: 100vw;
          height: 100vh;
          border: 0;
          object-fit: contain;
          image-rendering: auto;
          transform-origin: center center;
        }
      </style>
      <script>
        window.clawdSetEye = function(dx, dy, bodyDx, bodyDy, shadowDx, shadowDy) {
          const asset = document.getElementById('asset');
          function setTransform(el, x, y) {
            if (!el) return false;
            el.style.transformBox = 'fill-box';
            el.style.transformOrigin = 'center center';
            el.style.transform = 'translate(' + x + 'px,' + y + 'px)';
            return true;
          }
          let applied = false;
          try {
            const doc = asset && asset.contentDocument;
            if (doc) {
              applied = setTransform(doc.getElementById('eyes-js'), dx, dy) || applied;
              applied = setTransform(doc.getElementById('eyes-doze'), dx, dy) || applied;
              applied = setTransform(doc.getElementById('body-js'), bodyDx, bodyDy) || applied;
              applied = setTransform(doc.getElementById('shadow-js'), shadowDx, shadowDy) || applied;
            }
          } catch (_) {}
          if (!applied && asset) {
            asset.style.transform = 'translate(' + (dx * 0.25) + 'px,' + (dy * 0.25) + 'px)';
          }
        };
      </script>
    </head>
    <body>
      \(tag)
    </body>
    </html>
    """
  }

  override func mouseMoved(with event: NSEvent) {
    updateEyeTracking()
  }

  override func mouseEntered(with event: NSEvent) {
    updateEyeTracking()
  }

  override func mouseExited(with event: NSEvent) {
    applyEyeOffset(dx: 0, dy: 0)
  }

  override func mouseDown(with event: NSEvent) {
    dragStartMouse = NSEvent.mouseLocation
    dragStartFrame = window?.frame
    if event.clickCount >= 4 {
      playReaction("annoyed", side: nil)
    } else if event.clickCount == 2 {
      let side = convert(event.locationInWindow, from: nil).x < bounds.midX ? "left" : "right"
      playReaction(side == "left" ? "clickLeft" : "clickRight", side: side)
    }
  }

  override func mouseDragged(with event: NSEvent) {
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
    dragStartMouse = nil
    dragStartFrame = nil
    if forcedAsset?.fileName.contains("drag") == true {
      clearReaction()
    }
  }

  private func playReaction(_ reaction: String, side: String?, autoReset: Bool = true) {
    let theme = preferences().theme
    guard let resolved = themeRuntime.resolveReactionAsset(themeId: theme, reaction: reaction, side: side) else { return }
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

  private func updateEyeTracking() {
    guard let asset = currentAsset else { return }
    guard asset.manifest.eyeTracking?.enabled == true else {
      applyEyeOffset(dx: 0, dy: 0)
      return
    }
    let allowed = Set(asset.manifest.eyeTracking?.states ?? [])
    if !allowed.isEmpty && !allowed.contains(asset.state.rawValue) {
      applyEyeOffset(dx: 0, dy: 0)
      return
    }
    let location = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
    let center = NSPoint(x: bounds.midX, y: bounds.midY)
    let maxOffset = CGFloat(asset.manifest.eyeTracking?.maxOffset ?? 3)
    let dx = max(-maxOffset, min(maxOffset, (location.x - center.x) / max(bounds.width, 1) * maxOffset * 2))
    let dy = max(-maxOffset, min(maxOffset, (center.y - location.y) / max(bounds.height, 1) * maxOffset * 2))
    applyEyeOffset(dx: dx, dy: dy)
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
    return StateSnapshot(currentState: mapped, sessions: snapshot.sessions, updatedAt: snapshot.updatedAt)
  }

  private func applyEyeOffset(dx: CGFloat, dy: CGFloat) {
    fallbackView.eyeOffset = NSPoint(x: dx, y: dy)
    let script = "window.clawdSetEye && window.clawdSetEye(\(Double(dx)), \(Double(dy)), \(Double(dx * 0.25)), \(Double(dy * 0.25)), \(Double(dx * -0.15)), \(Double(dy * -0.05)))"
    webView.evaluateJavaScript(script, completionHandler: nil)
  }

  private func hitRect(for asset: ThemeAsset) -> NSRect? {
    guard let loaded = try? themeRuntime.loadTheme(id: asset.themeId),
          let hitBox = loaded.hitBox(for: asset),
          let viewBox = asset.manifest.viewBox
    else { return nil }
    let fit = aspectFitRect(content: NSSize(width: viewBox.width, height: viewBox.height), in: bounds)
    let scaleX = fit.width / max(viewBox.width, 1)
    let scaleY = fit.height / max(viewBox.height, 1)
    let x = fit.minX + CGFloat(hitBox.x - viewBox.x) * scaleX
    let yFromTop = CGFloat(hitBox.y - viewBox.y + hitBox.h) * scaleY
    let y = fit.maxY - yFromTop
    return NSRect(x: x, y: y, width: CGFloat(hitBox.w) * scaleX, height: CGFloat(hitBox.h) * scaleY).insetBy(dx: -6, dy: -6)
  }

  private func aspectFitRect(content: NSSize, in outer: NSRect) -> NSRect {
    let scale = min(outer.width / max(content.width, 1), outer.height / max(content.height, 1))
    let size = NSSize(width: content.width * scale, height: content.height * scale)
    return NSRect(x: outer.midX - size.width / 2, y: outer.midY - size.height / 2, width: size.width, height: size.height)
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
