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

  func applicationDidFinishLaunching(_ notification: Notification) {
    let prefs = preferencesStore.get()
    if prefs.showDock {
      NSApp.setActivationPolicy(.regular)
    }

    integrationManager = IntegrationManager(projectRoot: projectRoot)
    updaterService = UpdaterService(projectRoot: projectRoot)
    petWindow = PetWindowController(engine: stateEngine, preferencesStore: preferencesStore, projectRoot: projectRoot)
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
      focusManager: terminalFocusManager
    )
    settings = SettingsWindowController(
      preferencesStore: preferencesStore,
      remoteSSHRuntime: remoteSSHRuntime,
      projectRoot: projectRoot,
      localPort: { [weak self] in self?.server?.port }
    )
    statusMenu = StatusMenuController(
      stateEngine: stateEngine,
      dashboard: dashboard,
      settings: settings,
      preferencesStore: preferencesStore,
      syncHandler: { [weak self] in self?.syncIntegrations() },
      repairHandler: { [weak self] in self?.repairIntegrations() },
      cleanupHandler: { [weak self] in self?.cleanupIntegrations() },
      updateHandler: { [weak self] in self?.checkAndApplyUpdate() }
    )

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
    syncIntegrations()
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopRemoteSSHProfiles()
    permissionCoordinator.cancelAll(with: .noDecision)
    shortcutRuntime?.stop()
    remoteSSHRuntime.stopAll()
    server?.stop()
  }

  private func showPermission(_ permission: PendingPermission) {
    telegramSidecar.sendApproval(permission)
    PermissionBubbleWindowController.show(permission)
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
    DispatchQueue.global(qos: .utility).async {
      let status = updaterService.checkForUpdates()
      guard status.status == "available" else {
        print("Update check: \(status.status) \(status.message)")
        return
      }
      let applied = updaterService.applyUpdate()
      print("Update apply: \(applied.status) \(applied.message)")
      guard applied.status == "ok" else { return }
      let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
      let relaunch = updaterService.relaunch(executableURL: executable, arguments: Array(CommandLine.arguments.dropFirst()))
      print("Update relaunch: \(relaunch.status) \(relaunch.message)")
      if relaunch.status == "ok" {
        DispatchQueue.main.async {
          NSApp.terminate(nil)
        }
      }
    }
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

enum ProjectLocator {
  static func findProjectRoot() -> URL {
    if let explicit = ProcessInfo.processInfo.environment["CLAWD_PROJECT_ROOT"], !explicit.isEmpty {
      return URL(fileURLWithPath: explicit)
    }
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("package.json").path),
         FileManager.default.fileExists(atPath: url.appendingPathComponent("src/server.js").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
  }
}
