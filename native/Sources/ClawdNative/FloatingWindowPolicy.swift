import AppKit

@MainActor
enum FloatingWindowPolicy {
  // `.floating` windows can still be re-composited during macOS Space
  // transitions, which shows up as a one-frame blink on transparent overlays.
  // The screen-saver level keeps Clawd's small desktop surfaces outside that
  // transition path while `stationary` keeps their physical screen position.
  static let persistentOverlayLevel = NSWindow.Level.screenSaver

  static let persistentCollectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces,
    .stationary,
    .fullScreenAuxiliary,
    .ignoresCycle,
    .fullScreenDisallowsTiling
  ]

  static func applyPersistentOverlay(to window: NSWindow) {
    window.level = persistentOverlayLevel
    window.collectionBehavior = persistentCollectionBehavior
    window.hidesOnDeactivate = false
  }
}
