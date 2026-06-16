import AppKit
import ClawdNativeCore

@MainActor
final class StatusMenuController: NSObject {
  private let stateEngine: StateEngine
  private weak var dashboard: DashboardWindowController?
  private weak var settings: SettingsWindowController?
  private let preferencesStore: PreferencesStore?
  private let projectRoot: URL
  private let syncHandler: () -> Void
  private let repairHandler: () -> Void
  private let cleanupHandler: () -> Void
  private let updateHandler: () -> Void
  private let miniToggleHandler: (() -> Bool)?
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let dashboardItem = NSMenuItem(title: "", action: #selector(showDashboard), keyEquivalent: "d")
  private let settingsItem = NSMenuItem(title: "", action: #selector(showSettings), keyEquivalent: ",")
  private let dndItem = NSMenuItem(title: "", action: #selector(toggleDND), keyEquivalent: "")
  private let miniItem = NSMenuItem(title: "", action: #selector(toggleMini), keyEquivalent: "")
  private let syncItem = NSMenuItem(title: "", action: #selector(syncIntegrations), keyEquivalent: "")
  private let repairItem = NSMenuItem(title: "", action: #selector(repairIntegrations), keyEquivalent: "")
  private let cleanupItem = NSMenuItem(title: "", action: #selector(cleanupIntegrations), keyEquivalent: "")
  private let updateItem = NSMenuItem(title: "", action: #selector(checkForUpdates), keyEquivalent: "")
  private let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
  private var dnd = false

  init(
    stateEngine: StateEngine,
    dashboard: DashboardWindowController?,
    settings: SettingsWindowController?,
    preferencesStore: PreferencesStore? = nil,
    projectRoot: URL,
    syncHandler: @escaping () -> Void,
    repairHandler: @escaping () -> Void = {},
    cleanupHandler: @escaping () -> Void = {},
    updateHandler: @escaping () -> Void = {},
    miniToggleHandler: (() -> Bool)? = nil
  ) {
    self.stateEngine = stateEngine
    self.dashboard = dashboard
    self.settings = settings
    self.preferencesStore = preferencesStore
    self.projectRoot = projectRoot
    self.syncHandler = syncHandler
    self.repairHandler = repairHandler
    self.cleanupHandler = cleanupHandler
    self.updateHandler = updateHandler
    self.miniToggleHandler = miniToggleHandler
    super.init()
    configure()
    if let preferencesStore {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(preferencesChanged),
        name: .clawdNativePreferencesDidChange,
        object: preferencesStore
      )
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func configure() {
    configureStatusButton()
    let menu = NSMenu()
    menu.addItem(dashboardItem)
    menu.addItem(settingsItem)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(dndItem)
    menu.addItem(miniItem)
    menu.addItem(syncItem)
    menu.addItem(repairItem)
    menu.addItem(cleanupItem)
    menu.addItem(updateItem)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(quitItem)
    for menuItem in menu.items where menuItem.target == nil {
      menuItem.target = self
    }
    item.menu = menu
    refreshMenuState()
  }

  private func configureStatusButton() {
    guard let button = item.button else { return }
    button.title = ""
    button.image = Self.statusIcon(projectRoot: projectRoot)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "Clawd"
    button.setAccessibilityLabel("Clawd")
  }

  private func refreshMenuState() {
    let prefs = preferencesStore?.get() ?? Preferences()
    dashboardItem.title = localized("dashboard", prefs: prefs)
    settingsItem.title = localized("settings", prefs: prefs)
    dndItem.title = localized("doNotDisturb", prefs: prefs)
    miniItem.title = localized("miniMode", prefs: prefs)
    syncItem.title = localized("syncIntegrations", prefs: prefs)
    repairItem.title = localized("repairEnabledIntegrations", prefs: prefs)
    cleanupItem.title = localized("cleanupManagedIntegrations", prefs: prefs)
    updateItem.title = localized("checkForUpdates", prefs: prefs)
    quitItem.title = localized("quit", prefs: prefs)
    dndItem.state = dnd ? .on : .off
    miniItem.state = prefs.miniMode ? .on : .off
    item.isVisible = prefs.showTray
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
    refreshMenuState()
    if dnd {
      stateEngine.enableDoNotDisturb()
    } else {
      stateEngine.disableDoNotDisturb()
    }
  }

  @objc private func toggleMini() {
    guard let preferencesStore else { return }
    if let miniToggleHandler {
      _ = miniToggleHandler()
      refreshMenuState()
      return
    }
    let next = !(preferencesStore.get().miniMode)
    _ = try? preferencesStore.update { prefs in
      prefs.miniMode = next
      if next {
        prefs.preMiniX = prefs.positionSaved ? prefs.x : prefs.preMiniX
        prefs.preMiniY = prefs.positionSaved ? prefs.y : prefs.preMiniY
      }
    }
    refreshMenuState()
  }

  @objc private func preferencesChanged() {
    refreshMenuState()
  }

  @objc private func syncIntegrations() {
    syncHandler()
  }

  @objc private func repairIntegrations() {
    repairHandler()
  }

  @objc private func cleanupIntegrations() {
    cleanupHandler()
  }

  @objc private func checkForUpdates() {
    updateHandler()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func localized(_ key: String, prefs: Preferences) -> String {
    let table = Self.localizedStrings[prefs.lang] ?? Self.localizedStrings["en"] ?? [:]
    return table[key] ?? Self.localizedStrings["en"]?[key] ?? key
  }

  private static func statusIcon(projectRoot: URL) -> NSImage {
    let assetsRoot = projectRoot.appendingPathComponent("assets", isDirectory: true)
    let candidates = [
      "tray-iconTemplate.png",
      "tray-iconTemplate@2x.png",
      "tray-icon.png",
      "icon.png"
    ]
    for candidate in candidates {
      let url = assetsRoot.appendingPathComponent(candidate)
      guard let image = NSImage(contentsOf: url) else { continue }
      image.size = NSSize(width: 18, height: 18)
      image.isTemplate = candidate.contains("Template")
      return image
    }
    return fallbackStatusIcon()
  }

  private static func fallbackStatusIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18))
    image.lockFocus()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: 5.0, y: 4.0, width: 8.0, height: 8.0)).fill()
    NSBezierPath(ovalIn: NSRect(x: 2.0, y: 10.0, width: 4.0, height: 4.0)).fill()
    NSBezierPath(ovalIn: NSRect(x: 7.0, y: 12.0, width: 4.0, height: 4.0)).fill()
    NSBezierPath(ovalIn: NSRect(x: 12.0, y: 10.0, width: 4.0, height: 4.0)).fill()
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  private static let localizedStrings: [String: [String: String]] = [
    "en": [
      "dashboard": "Dashboard",
      "settings": "Settings",
      "doNotDisturb": "Do Not Disturb",
      "miniMode": "Mini Mode",
      "syncIntegrations": "Sync Integrations",
      "repairEnabledIntegrations": "Repair Enabled Integrations",
      "cleanupManagedIntegrations": "Cleanup Managed Integrations",
      "checkForUpdates": "Check for Updates",
      "quit": "Quit"
    ],
    "zh": [
      "dashboard": "会话面板",
      "settings": "设置",
      "doNotDisturb": "免打扰",
      "miniMode": "迷你模式",
      "syncIntegrations": "同步集成",
      "repairEnabledIntegrations": "修复已启用集成",
      "cleanupManagedIntegrations": "清理托管集成",
      "checkForUpdates": "检查更新",
      "quit": "退出"
    ],
    "zh-TW": [
      "dashboard": "工作階段面板",
      "settings": "設定",
      "doNotDisturb": "勿擾模式",
      "miniMode": "迷你模式",
      "syncIntegrations": "同步整合",
      "repairEnabledIntegrations": "修復已啟用整合",
      "cleanupManagedIntegrations": "清理受管理整合",
      "checkForUpdates": "檢查更新",
      "quit": "結束"
    ],
    "ko": [
      "dashboard": "대시보드",
      "settings": "설정",
      "doNotDisturb": "방해 금지",
      "miniMode": "미니 모드",
      "syncIntegrations": "통합 동기화",
      "repairEnabledIntegrations": "활성화된 통합 복구",
      "cleanupManagedIntegrations": "관리 중인 통합 정리",
      "checkForUpdates": "업데이트 확인",
      "quit": "종료"
    ],
    "ja": [
      "dashboard": "ダッシュボード",
      "settings": "設定",
      "doNotDisturb": "おやすみモード",
      "miniMode": "ミニモード",
      "syncIntegrations": "連携を同期",
      "repairEnabledIntegrations": "有効な連携を修復",
      "cleanupManagedIntegrations": "管理中の連携をクリーンアップ",
      "checkForUpdates": "アップデートを確認",
      "quit": "終了"
    ]
  ]
}
