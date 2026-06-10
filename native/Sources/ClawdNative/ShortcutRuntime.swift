import AppKit
import ClawdNativeCore

@MainActor
final class ShortcutRuntime {
  private let preferencesStore: PreferencesStore
  private let permissionCoordinator: PermissionCoordinator
  private let petWindow: () -> NSWindow?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var observer: NSObjectProtocol?

  init(
    preferencesStore: PreferencesStore,
    permissionCoordinator: PermissionCoordinator,
    petWindow: @escaping () -> NSWindow?
  ) {
    self.preferencesStore = preferencesStore
    self.permissionCoordinator = permissionCoordinator
    self.petWindow = petWindow
  }

  func start() {
    stop()
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if self?.handle(event) == true { return nil }
      return event
    }
    observer = NotificationCenter.default.addObserver(
      forName: .clawdNativePreferencesDidChange,
      object: preferencesStore,
      queue: .main
    ) { [weak self] _ in
      _ = self?.preferencesStore.get()
    }
  }

  func stop() {
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
  }

  @discardableResult
  private func handle(_ event: NSEvent) -> Bool {
    let shortcuts = preferencesStore.get().shortcuts
    if matches(event, accelerator: shortcuts["togglePet"]) {
      togglePet()
      return true
    }
    if matches(event, accelerator: shortcuts["permissionAllow"]) {
      return permissionCoordinator.resolveLatest(.allow)
    }
    if matches(event, accelerator: shortcuts["permissionDeny"]) {
      return permissionCoordinator.resolveLatest(.deny(message: "Denied from shortcut"))
    }
    return false
  }

  private func togglePet() {
    guard let window = petWindow() else { return }
    if window.isVisible {
      window.orderOut(nil)
    } else {
      window.orderFrontRegardless()
    }
  }

  private func matches(_ event: NSEvent, accelerator: String?) -> Bool {
    guard let accelerator, let parsed = ParsedShortcut(accelerator) else { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
    if parsed.commandOrControl && !flags.contains(.command) && !flags.contains(.control) { return false }
    if parsed.shift && !flags.contains(.shift) { return false }
    if parsed.alt && !flags.contains(.option) { return false }
    if !parsed.shift && flags.contains(.shift) { return false }
    if !parsed.alt && flags.contains(.option) { return false }
    if !parsed.commandOrControl && (flags.contains(.command) || flags.contains(.control)) { return false }
    return parsed.key == Self.keyString(for: event)
  }

  private static func keyString(for event: NSEvent) -> String {
    switch event.keyCode {
    case 122: return "F1"
    case 120: return "F2"
    case 99: return "F3"
    case 118: return "F4"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    default: break
    }
    return (event.charactersIgnoringModifiers ?? "").uppercased()
  }

  private struct ParsedShortcut {
    var commandOrControl = false
    var shift = false
    var alt = false
    var key = ""

    init?(_ value: String?) {
      guard let value else { return nil }
      let parts = value.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      guard !parts.isEmpty else { return nil }
      for part in parts {
        switch part.lowercased() {
        case "commandorcontrol", "cmdorctrl", "cmdorcontrol", "command", "cmd", "control", "ctrl":
          commandOrControl = true
        case "shift":
          shift = true
        case "alt", "option":
          alt = true
        default:
          key = part.uppercased()
        }
      }
      if key.isEmpty { return nil }
    }
  }
}
