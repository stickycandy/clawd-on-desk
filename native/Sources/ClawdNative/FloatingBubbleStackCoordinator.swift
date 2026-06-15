import AppKit
import ClawdNativeCore

@MainActor
struct FloatingBubbleStackEntry {
  var createdAt: Date
  var height: CGFloat
  var setFrame: (NSRect) -> Void
}

@MainActor
enum FloatingBubbleStackCoordinator {
  static let stackGap: CGFloat = 10
  static var onStackChanged: (() -> Void)?

  static func reposition(preferences: Preferences, petWindow: NSWindow?) {
    defer { onStackChanged?() }
    guard let screen = petWindow?.screen ?? NSScreen.main else { return }
    let entries = stackEntries()
    guard !entries.isEmpty else { return }
    let frames = BubbleStackLayout.computeBounds(
      followPet: preferences.bubbleFollowPet,
      bubbleHeights: entries.map(\.height),
      bubbleWidth: 420,
      margin: 8,
      gap: stackGap,
      workArea: screen.visibleFrame,
      petFrame: petWindow?.frame
    )
    for (entry, frame) in zip(entries, frames) {
      entry.setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height))
    }
  }

  static func reservedHeight(separatorGap: CGFloat = UpdateBubbleLayout.defaultGap) -> CGFloat {
    let entries = stackEntries()
    guard !entries.isEmpty else { return 0 }
    return entries.map(\.height).reduce(0, +)
      + stackGap * CGFloat(max(entries.count - 1, 0))
      + max(0, separatorGap)
  }

  private static func stackEntries() -> [FloatingBubbleStackEntry] {
    (
      PermissionBubbleWindowController.stackEntries() +
      PassiveNotificationBubbleWindowController.stackEntries()
    ).sorted { lhs, rhs in
      lhs.createdAt < rhs.createdAt
    }
  }
}
