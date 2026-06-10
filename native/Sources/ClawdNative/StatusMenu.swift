import AppKit
import ClawdNativeCore

@MainActor
final class StatusMenuController: NSObject {
  private let stateEngine: StateEngine
  private weak var dashboard: DashboardWindowController?
  private weak var settings: SettingsWindowController?
  private let preferencesStore: PreferencesStore?
  private let syncHandler: () -> Void
  private let updateHandler: () -> Void
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let dndItem = NSMenuItem(title: "Do Not Disturb", action: #selector(toggleDND), keyEquivalent: "")
  private let miniItem = NSMenuItem(title: "Mini Mode", action: #selector(toggleMini), keyEquivalent: "")
  private var dnd = false

  init(
    stateEngine: StateEngine,
    dashboard: DashboardWindowController?,
    settings: SettingsWindowController?,
    preferencesStore: PreferencesStore? = nil,
    syncHandler: @escaping () -> Void,
    updateHandler: @escaping () -> Void = {}
  ) {
    self.stateEngine = stateEngine
    self.dashboard = dashboard
    self.settings = settings
    self.preferencesStore = preferencesStore
    self.syncHandler = syncHandler
    self.updateHandler = updateHandler
    super.init()
    configure()
  }

  private func configure() {
    item.button?.title = "Clawd"
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Dashboard", action: #selector(showDashboard), keyEquivalent: "d"))
    menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
    menu.addItem(NSMenuItem.separator())
    dndItem.target = self
    menu.addItem(dndItem)
    miniItem.target = self
    miniItem.state = preferencesStore?.get().miniMode == true ? .on : .off
    menu.addItem(miniItem)
    menu.addItem(NSMenuItem(title: "Sync Integrations", action: #selector(syncIntegrations), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    for menuItem in menu.items where menuItem.target == nil {
      menuItem.target = self
    }
    item.menu = menu
  }

  @objc private func showDashboard() {
    dashboard?.showWindow(nil)
    dashboard?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showSettings() {
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func toggleDND() {
    dnd.toggle()
    dndItem.state = dnd ? .on : .off
    if dnd {
      stateEngine.enableDoNotDisturb()
    } else {
      stateEngine.disableDoNotDisturb()
    }
  }

  @objc private func toggleMini() {
    guard let preferencesStore else { return }
    let next = !(preferencesStore.get().miniMode)
    _ = try? preferencesStore.update { prefs in
      prefs.miniMode = next
      if next {
        prefs.preMiniX = prefs.positionSaved ? prefs.x : prefs.preMiniX
        prefs.preMiniY = prefs.positionSaved ? prefs.y : prefs.preMiniY
      }
    }
    miniItem.state = next ? .on : .off
  }

  @objc private func syncIntegrations() {
    syncHandler()
  }

  @objc private func checkForUpdates() {
    updateHandler()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
