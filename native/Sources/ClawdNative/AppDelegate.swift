import AppKit
import ClawdNativeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let projectRoot = ProjectLocator.findProjectRoot()
  private let preferencesStore = PreferencesStore()
  private let stateEngine = StateEngine()
  private let permissionCoordinator = PermissionCoordinator()
  private let terminalFocusManager = TerminalFocusManager()
  private let remoteSSHRuntime = RemoteSSHRuntime()
  private lazy var themeRuntime = ThemeRuntime(projectRoot: projectRoot)
  private lazy var telegramSidecar = TelegramApprovalSidecar(configProvider: { [preferencesStore] in
    preferencesStore.get().telegramApproval
  })
  private var server: LocalHTTPServer?
  private var petWindow: PetWindowController?
  private var dashboard: DashboardWindowController?
  private var sessionHUD: SessionHUDWindowController?
  private var settings: SettingsWindowController?
  private var statusMenu: StatusMenuController?
  private var integrationManager: IntegrationManager?
  private var updaterService: UpdaterService?
  private var shortcutRuntime: ShortcutRuntime?
  private var systemBehaviorRuntime: SystemBehaviorRuntime?
  private var idleSleepRuntime: IdleSleepRuntime?
  private var soundRuntime: SoundRuntime?
  private var updateBubble: UpdateBubbleWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let prefs = preferencesStore.get()
    if prefs.showDock {
      NSApp.setActivationPolicy(.regular)
    }

    integrationManager = IntegrationManager(projectRoot: projectRoot)
    updaterService = UpdaterService(projectRoot: projectRoot)
    updateBubble = UpdateBubbleWindowController()
    refreshStateTiming()
    systemBehaviorRuntime = SystemBehaviorRuntime(preferencesStore: preferencesStore, stateEngine: stateEngine)
    soundRuntime = SoundRuntime(
      stateEngine: stateEngine,
      preferencesStore: preferencesStore,
      themeRuntime: themeRuntime
    )
    petWindow = PetWindowController(engine: stateEngine, preferencesStore: preferencesStore, projectRoot: projectRoot)
    petWindow?.frameDidChange = { [weak self] in
      guard let self else { return }
      self.sessionHUD?.refresh()
      self.repositionFloatingBubbles()
    }
    petWindow?.petClicked = { [weak self] in
      self?.sessionHUD?.revealFromPet()
    }
    idleSleepRuntime = IdleSleepRuntime(
      stateEngine: stateEngine,
      preferencesStore: preferencesStore,
      themeRuntime: themeRuntime,
      petWindow: { [weak self] in self?.petWindow }
    )
    shortcutRuntime = ShortcutRuntime(
      preferencesStore: preferencesStore,
      permissionCoordinator: permissionCoordinator,
      petWindow: { [weak self] in self?.petWindow?.window }
    )
    dashboard = DashboardWindowController(engine: stateEngine, focusManager: terminalFocusManager)
    sessionHUD = SessionHUDWindowController(
      engine: stateEngine,
      preferences: { [preferencesStore] in preferencesStore.get() },
      petWindow: { [weak self] in self?.petWindow?.window },
      petHitFrame: { [weak self] in self?.petWindow?.currentHitFrameOnScreen },
      isMiniTransitioning: { [weak self] in self?.petWindow?.isMiniTransitioning == true },
      focusManager: terminalFocusManager
    )
    sessionHUD?.frameDidChange = { [weak self] in
      guard let self else { return }
      self.repositionUpdateBubble(preferences: self.preferencesStore.get())
    }
    settings = SettingsWindowController(
      preferencesStore: preferencesStore,
      remoteSSHRuntime: remoteSSHRuntime,
      projectRoot: projectRoot,
      localPort: { [weak self] in self?.server?.port },
      agentCleanupHandler: { [weak self] agentId in
        self?.clearAgentRuntime(agentId: agentId)
      }
    )
    statusMenu = StatusMenuController(
      stateEngine: stateEngine,
      dashboard: dashboard,
      settings: settings,
      preferencesStore: preferencesStore,
      syncHandler: { [weak self] in self?.syncIntegrations() },
      repairHandler: { [weak self] in self?.repairIntegrations() },
      cleanupHandler: { [weak self] in self?.cleanupIntegrations() },
      updateHandler: { [weak self] in self?.checkAndApplyUpdate() },
      miniToggleHandler: { [weak self] in self?.petWindow?.toggleMiniFromMenu() ?? false }
    )
    FloatingBubbleStackCoordinator.onStackChanged = { [weak self] in
      guard let self else { return }
      self.repositionUpdateBubble(preferences: self.preferencesStore.get())
    }

    permissionCoordinator.presenter = { [weak self] permission in
      DispatchQueue.main.async {
        self?.showPermission(permission)
      }
    }

    do {
      let httpServer = LocalHTTPServer(engine: stateEngine, preferences: { [preferencesStore] in
        preferencesStore.get()
      }, permissions: permissionCoordinator, projectRoot: projectRoot, remoteSSHStatuses: { [remoteSSHRuntime] in
        remoteSSHRuntime.listStatuses()
      }, passiveNotifications: { [weak self] event in
        DispatchQueue.main.async {
          self?.handlePassiveNotification(event)
        }
      })
      let port = try httpServer.start()
      server = httpServer
      print("Clawd Native hook server listening on 127.0.0.1:\(port)")
      connectRemoteSSHProfilesOnLaunch(localPort: port)
    } catch {
      NSAlert(error: error).runModal()
    }

    petWindow?.showWindow(nil)
    shortcutRuntime?.start()
    systemBehaviorRuntime?.start()
    idleSleepRuntime?.start()
    soundRuntime?.start()
    if !Self.shouldSkipStartupIntegrationSync {
      syncIntegrations()
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(preferencesDidChange),
      name: .clawdNativePreferencesDidChange,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateEventDidChange(_:)),
      name: .clawdNativeUpdateEvent,
      object: nil
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopRemoteSSHProfiles()
    permissionCoordinator.cancelAll(with: .noDecision)
    updateBubble?.hide()
    soundRuntime?.stop()
    idleSleepRuntime?.stop()
    systemBehaviorRuntime?.stop()
    shortcutRuntime?.stop()
    remoteSSHRuntime.stopAll()
    server?.stop()
    FloatingBubbleStackCoordinator.onStackChanged = nil
  }

  @objc private func preferencesDidChange() {
    refreshStateTiming()
    repositionFloatingBubbles()
    PermissionBubbleWindowController.applyPreferences(preferencesStore.get(), petWindow: petWindow?.window)
    PassiveNotificationBubbleWindowController.applyPreferences(preferencesStore.get(), petWindow: petWindow?.window)
  }

  @objc private func updateEventDidChange(_ notification: Notification) {
    guard let kind = notification.userInfo?["kind"] as? String,
          let status = notification.userInfo?["status"] as? UpdateStatus
    else { return }
    switch kind {
    case "check":
      if status.status == "available" {
        presentUpdateAvailable(status)
      } else {
        presentUpdateStatus(status, title: status.status == "ok" ? "Clawd Is Up to Date" : "Update Check Failed")
      }
    case "apply":
      if status.status == "ok" {
        showUpdateBubble(
          UpdateBubblePayload(
            title: "Relaunching Clawd",
            message: "The update was applied. Clawd Native will restart now.",
            detail: nil,
            primaryTitle: nil,
            secondaryTitle: nil,
            mode: .success
          ),
          actionHandler: { _ in }
        )
      } else {
        presentUpdateStatus(status, title: "Update Install Failed")
      }
    case "relaunch":
      if status.status == "ok" {
        NSApp.terminate(nil)
      } else {
        presentUpdateStatus(status, title: "Relaunch Failed")
      }
    default:
      break
    }
  }

  private func refreshStateTiming() {
    let prefs = preferencesStore.get()
    let variant = prefs.themeVariant[prefs.theme] ?? "default"
    if let theme = try? themeRuntime.loadTheme(
      id: prefs.theme,
      variantId: variant,
      overrides: prefs.themeOverrides[prefs.theme]
    ) {
      stateEngine.updateTimings(theme.manifest.timing())
    }
  }

  private func showPermission(_ permission: PendingPermission) {
    telegramSidecar.sendApproval(permission)
    PermissionBubbleWindowController.show(permission, preferences: preferencesStore.get(), petWindow: petWindow?.window)
  }

  private func repositionFloatingBubbles() {
    let prefs = preferencesStore.get()
    FloatingBubbleStackCoordinator.reposition(preferences: prefs, petWindow: petWindow?.window)
  }

  private func repositionUpdateBubble(preferences prefs: Preferences) {
    updateBubble?.reposition(
      preferences: prefs,
      reservedHeight: FloatingBubbleStackCoordinator.reservedHeight(),
      hudReservedOffset: sessionHUD?.reservedOffset ?? 0
    )
  }

  private func handlePassiveNotification(_ event: PassiveNotificationEvent) {
    let prefs = preferencesStore.get()
    switch event {
    case .show(let request):
      PassiveNotificationBubbleWindowController.show(request, preferences: prefs, petWindow: petWindow?.window)
    case .clear(let agentId, let sessionId, let reason):
      PassiveNotificationBubbleWindowController.clear(agentId: agentId, sessionId: sessionId, reason: reason)
    }
  }

  private func clearAgentRuntime(agentId: String) {
    stateEngine.clearSessions(agentId: agentId)
    permissionCoordinator.cancelAll(agentId: agentId, with: .noDecision)
    PermissionBubbleWindowController.dismiss(agentId: agentId)
    PassiveNotificationBubbleWindowController.clear(agentId: agentId, sessionId: nil, reason: "agent-disabled")
  }

  private func syncIntegrations() {
    guard let integrationManager else { return }
    let prefs = preferencesStore.get()
    DispatchQueue.global(qos: .utility).async {
      let results = integrationManager.syncEnabledStartupIntegrations(preferences: prefs)
      let summary = results.map { "\($0.agentId): \($0.status)" }.joined(separator: ", ")
      if !summary.isEmpty {
        print("Integration sync: \(summary)")
      }
    }
  }

  private func repairIntegrations() {
    guard let integrationManager else { return }
    let prefs = preferencesStore.get()
    DispatchQueue.global(qos: .utility).async {
      let results = integrationManager.repairAll(preferences: prefs)
      let summary = results.map { "\($0.agentId): \($0.status)" }.joined(separator: ", ")
      print("Integration repair: \(summary)")
    }
  }

  private func cleanupIntegrations() {
    guard let integrationManager else { return }
    DispatchQueue.global(qos: .utility).async {
      let result = integrationManager.cleanupAll()
      print("Integration cleanup: \(result.status) \(result.output)")
    }
  }

  private func checkAndApplyUpdate() {
    guard let updaterService else { return }
    showUpdateBubble(
      UpdateBubblePayload(
        title: "Checking for Updates",
        message: "Looking for upstream changes.",
        detail: nil,
        primaryTitle: nil,
        secondaryTitle: nil,
        mode: .info
      ),
      actionHandler: { _ in }
    )
    Task.detached(priority: .utility) { [updaterService] in
      let status = updaterService.checkForUpdates()
      postUpdateEvent(kind: "check", status: status)
    }
  }

  private func presentUpdateAvailable(_ status: UpdateStatus) {
    let payload = UpdateBubblePayload(
      title: "Update Available",
      message: status.message,
      detail: "Clawd can pull the latest changes and relaunch.",
      primaryTitle: "Install & Relaunch",
      secondaryTitle: "Later",
      mode: .info
    )
    let shown = showUpdateBubble(payload) { [weak self] action in
      guard action == .primary else { return }
      self?.applyAvailableUpdate()
    }
    if !shown {
      let alert = NSAlert()
      alert.messageText = "Update Available"
      alert.informativeText = "\(status.message)\n\nInstall the update and relaunch Clawd Native?"
      alert.addButton(withTitle: "Install & Relaunch")
      alert.addButton(withTitle: "Later")
      if alert.runModal() == .alertFirstButtonReturn {
        applyAvailableUpdate()
      }
    }
  }

  private func applyAvailableUpdate() {
    guard let updaterService else { return }
    showUpdateBubble(
      UpdateBubblePayload(
        title: "Installing Update",
        message: "Pulling latest changes and refreshing dependencies.",
        detail: nil,
        primaryTitle: nil,
        secondaryTitle: nil,
        mode: .info
      ),
      actionHandler: { _ in }
    )
    Task.detached(priority: .utility) { [updaterService] in
      let applied = updaterService.applyUpdate()
      postUpdateEvent(kind: "apply", status: applied)
      guard applied.status == "ok" else { return }
      let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
      let relaunch = updaterService.relaunch(executableURL: executable, arguments: Array(CommandLine.arguments.dropFirst()))
      postUpdateEvent(kind: "relaunch", status: relaunch)
    }
  }

  private func presentUpdateStatus(_ status: UpdateStatus, title: String) {
    let mode: UpdateBubblePayload.Mode = status.status == "ok" ? .success : .error
    let shown = showUpdateBubble(
      UpdateBubblePayload(
        title: title,
        message: status.message.isEmpty ? status.status : status.message,
        detail: nil,
        primaryTitle: nil,
        secondaryTitle: nil,
        mode: mode
      ),
      actionHandler: { _ in }
    )
    if !shown {
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = status.message
      alert.runModal()
    }
  }

  @discardableResult
  private func showUpdateBubble(_ payload: UpdateBubblePayload, actionHandler: @escaping (UpdateBubbleAction) -> Void) -> Bool {
    guard let updateBubble else { return false }
    return updateBubble.show(
      payload,
      preferences: preferencesStore.get(),
      petWindow: petWindow?.window,
      reservedHeight: FloatingBubbleStackCoordinator.reservedHeight(),
      hudReservedOffset: sessionHUD?.reservedOffset ?? 0,
      actionHandler: actionHandler
    )
  }

  private func connectRemoteSSHProfilesOnLaunch(localPort: Int) {
    let profiles = preferencesStore.get().remoteSshProfiles
      .filter { $0.enabled && $0.connectOnLaunch }
    guard !profiles.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async { [remoteSSHRuntime] in
      for profile in profiles {
        let status = remoteSSHRuntime.connect(profile: profile, localPort: localPort)
        if status.state == "running", profile.autoStartCodexMonitor {
          _ = remoteSSHRuntime.startCodexMonitor(profile: profile)
        }
      }
    }
  }

  private func stopRemoteSSHProfiles() {
    let profiles = preferencesStore.get().remoteSshProfiles
      .filter { $0.autoStartCodexMonitor }
    for profile in profiles {
      _ = remoteSSHRuntime.stopCodexMonitor(profile: profile)
    }
  }
}

private extension AppDelegate {
  static var shouldSkipStartupIntegrationSync: Bool {
    ProcessInfo.processInfo.environment["CLAWD_NATIVE_SKIP_INTEGRATION_SYNC"] == "1"
  }
}

private func postUpdateEvent(kind: String, status: UpdateStatus) {
  DispatchQueue.main.async {
    NotificationCenter.default.post(
      name: .clawdNativeUpdateEvent,
      object: nil,
      userInfo: [
        "kind": kind,
        "status": status
      ]
    )
  }
}

private extension Notification.Name {
  static let clawdNativeUpdateEvent = Notification.Name("ClawdNativeUpdateEvent")
}

enum ProjectLocator {
  static func findProjectRoot() -> URL {
    let fileManager = FileManager.default
    if let explicit = ProcessInfo.processInfo.environment["CLAWD_PROJECT_ROOT"], !explicit.isEmpty {
      return URL(fileURLWithPath: explicit)
    }

    if let bundledRoot = findBundledProjectRoot(fileManager: fileManager) {
      return bundledRoot
    }

    let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    if let checkoutRoot = findSourceCheckoutRoot(startingAt: currentDirectory, fileManager: fileManager) {
      return checkoutRoot
    }
    return currentDirectory.deletingLastPathComponent()
  }

  private static func findBundledProjectRoot(fileManager: FileManager) -> URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let candidates = [
      resources.appendingPathComponent("Project", isDirectory: true),
      resources
    ]
    return candidates.first { isBundledProjectRoot($0, fileManager: fileManager) }
  }

  private static func findSourceCheckoutRoot(startingAt startURL: URL, fileManager: FileManager) -> URL? {
    var url = startURL
    for _ in 0..<6 {
      if isSourceCheckoutRoot(url, fileManager: fileManager) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return nil
  }

  private static func isSourceCheckoutRoot(_ url: URL, fileManager: FileManager) -> Bool {
    fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path)
      && fileManager.fileExists(atPath: url.appendingPathComponent("src/server.js").path)
  }

  private static func isBundledProjectRoot(_ url: URL, fileManager: FileManager) -> Bool {
    fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path)
      && fileManager.fileExists(atPath: url.appendingPathComponent("themes", isDirectory: true).path)
      && fileManager.fileExists(atPath: url.appendingPathComponent("assets", isDirectory: true).path)
      && fileManager.fileExists(atPath: url.appendingPathComponent("agents", isDirectory: true).path)
      && fileManager.fileExists(atPath: url.appendingPathComponent("hooks", isDirectory: true).path)
  }
}
