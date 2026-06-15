import CoreGraphics
import Foundation

public enum SessionHUDEligibility {
  public struct AutoHideHotZone: Equatable, Sendable {
    public var rects: [CGRect]
    public var padding: CGFloat

    public init(rects: [CGRect], padding: CGFloat) {
      self.rects = rects
      self.padding = padding
    }
  }

  public struct AutoHideVisibility: Equatable, Sendable {
    public var show: Bool
    public var nextHoldUntil: TimeInterval

    public init(show: Bool, nextHoldUntil: TimeInterval) {
      self.show = show
      self.nextHoldUntil = nextHoldUntil
    }
  }

  public static let defaultHotZonePadding: CGFloat = 24
  public static let defaultAutoHidePollSeconds: TimeInterval = 0.2
  public static let defaultHideGraceSeconds: TimeInterval = 0.5

  public static func visibleSessions(in snapshot: StateSnapshot) -> [AgentSession] {
    snapshot.sessions.filter(\.visibleInHUD)
  }

  public static func isBaseEligible(
    snapshot: StateSnapshot?,
    sessionHudEnabled: Bool,
    petHidden: Bool = false,
    miniMode: Bool = false,
    miniTransitioning: Bool = false
  ) -> Bool {
    guard let snapshot else { return false }
    guard sessionHudEnabled else { return false }
    guard !petHidden else { return false }
    guard !miniMode, !miniTransitioning else { return false }
    return visibleSessions(in: snapshot).isEmpty == false
  }

  public static func shouldShow(
    snapshot: StateSnapshot?,
    sessionHudEnabled: Bool,
    sessionHudPinned: Bool,
    clickRevealed: Bool,
    petHidden: Bool = false,
    miniMode: Bool = false,
    miniTransitioning: Bool = false
  ) -> Bool {
    guard isBaseEligible(
      snapshot: snapshot,
      sessionHudEnabled: sessionHudEnabled,
      petHidden: petHidden,
      miniMode: miniMode,
      miniTransitioning: miniTransitioning
    ) else { return false }
    return sessionHudPinned || clickRevealed
  }

  public static func pointInExpandedRect(_ point: CGPoint, rect: CGRect, padding rawPadding: CGFloat) -> Bool {
    guard isFinite(rect), point.x.isFinite, point.y.isFinite else { return false }
    let padding = rawPadding.isFinite ? rawPadding : 0
    return point.x >= rect.minX - padding
      && point.x <= rect.maxX + padding
      && point.y >= rect.minY - padding
      && point.y <= rect.maxY + padding
  }

  public static func makeAutoHideHotZone(
    petHitFrame: CGRect?,
    hudFrame: CGRect?,
    padding: CGFloat = defaultHotZonePadding
  ) -> AutoHideHotZone {
    var rects: [CGRect] = []
    if let petHitFrame, isFinite(petHitFrame), petHitFrame.width > 0, petHitFrame.height > 0 {
      rects.append(petHitFrame)
    }
    if let hudFrame, isFinite(hudFrame), hudFrame.width > 0, hudFrame.height > 0 {
      rects.append(hudFrame)
    }
    return AutoHideHotZone(rects: rects, padding: padding.isFinite ? padding : 0)
  }

  public static func pointInHotZone(_ point: CGPoint, hotZone: AutoHideHotZone) -> Bool {
    hotZone.rects.contains { rect in
      pointInExpandedRect(point, rect: rect, padding: hotZone.padding)
    }
  }

  public static func evaluateAutoHideVisibility(
    snapshot: StateSnapshot?,
    sessionHudEnabled: Bool,
    sessionHudPinned: Bool,
    clickRevealed: Bool,
    inHotZone: Bool,
    now: TimeInterval,
    visibleHoldUntil: TimeInterval,
    hideGraceSeconds: TimeInterval = defaultHideGraceSeconds,
    petHidden: Bool = false,
    miniMode: Bool = false,
    miniTransitioning: Bool = false
  ) -> AutoHideVisibility {
    guard isBaseEligible(
      snapshot: snapshot,
      sessionHudEnabled: sessionHudEnabled,
      petHidden: petHidden,
      miniMode: miniMode,
      miniTransitioning: miniTransitioning
    ) else {
      return AutoHideVisibility(show: false, nextHoldUntil: 0)
    }
    if sessionHudPinned {
      return AutoHideVisibility(show: true, nextHoldUntil: 0)
    }
    guard clickRevealed else {
      return AutoHideVisibility(show: false, nextHoldUntil: 0)
    }

    let safeNow = now.isFinite ? now : 0
    let grace = hideGraceSeconds.isFinite ? max(0, hideGraceSeconds) : 0
    var nextHoldUntil = visibleHoldUntil.isFinite ? visibleHoldUntil : 0
    if inHotZone {
      nextHoldUntil = safeNow + grace
    }
    let show = inHotZone || safeNow < nextHoldUntil
    return AutoHideVisibility(show: show, nextHoldUntil: nextHoldUntil)
  }

  private static func isFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.size.width.isFinite
      && rect.size.height.isFinite
  }
}
