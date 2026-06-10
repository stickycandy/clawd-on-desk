import AppKit
import ClawdNativeCore
import ServiceManagement

@MainActor
final class SystemBehaviorRuntime {
  private let preferencesStore: PreferencesStore
  private let stateEngine: StateEngine
  private var preferencesObserver: NSObjectProtocol?
  private var stateSubscription: UUID?
  private var lastOpenAtLogin: Bool?
  private var lastShowDock: Bool?
  private var caffeinateProcess: Process?
  private var flashTimer: Timer?
  private var flashStartedAt: Date?
  private var previousActive = false

  init(preferencesStore: PreferencesStore, stateEngine: StateEngine) {
    self.preferencesStore = preferencesStore
    self.stateEngine = stateEngine
  }

  func start() {
    stop()
    applyPreferences(preferencesStore.get(), hydrateLoginItem: true)
    preferencesObserver = NotificationCenter.default.addObserver(
      forName: .clawdNativePreferencesDidChange,
      object: preferencesStore,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.applyPreferences(self.preferencesStore.get(), hydrateLoginItem: false)
        self.updateKeepAwake(snapshot: self.stateEngine.snapshot())
      }
    }
    stateSubscription = stateEngine.subscribe { [weak self] snapshot in
      Task { @MainActor in
        self?.handle(snapshot)
      }
    }
  }

  func stop() {
    if let preferencesObserver {
      NotificationCenter.default.removeObserver(preferencesObserver)
      self.preferencesObserver = nil
    }
    if let stateSubscription {
      stateEngine.unsubscribe(stateSubscription)
      self.stateSubscription = nil
    }
    stopCaffeinate()
    stopDockFlash()
  }

  private func applyPreferences(_ prefs: Preferences, hydrateLoginItem: Bool) {
    if lastShowDock != prefs.showDock {
      NSApp.setActivationPolicy(prefs.showDock ? .regular : .accessory)
      lastShowDock = prefs.showDock
    }

    if hydrateLoginItem || lastOpenAtLogin != prefs.openAtLogin {
      setOpenAtLogin(prefs.openAtLogin)
      lastOpenAtLogin = prefs.openAtLogin
      if !prefs.openAtLoginHydrated {
        _ = try? preferencesStore.update { next in
          next.openAtLoginHydrated = true
        }
      }
    }
  }

  private func handle(_ snapshot: StateSnapshot) {
    let active = snapshot.hasWorkingSession
    updateKeepAwake(snapshot: snapshot)
    if previousActive && !active && preferencesStore.get().flashTaskbarOnComplete {
      startDockFlash()
    }
    previousActive = active
  }

  private func updateKeepAwake(snapshot: StateSnapshot) {
    let prefs = preferencesStore.get()
    if prefs.keepAwakeWhileWorking && snapshot.hasWorkingSession {
      startCaffeinate()
    } else {
      stopCaffeinate()
    }
  }

  private func startCaffeinate() {
    if caffeinateProcess?.isRunning == true { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    process.arguments = ["-dimsu"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      caffeinateProcess = process
    } catch {
      print("Could not start caffeinate: \(error.localizedDescription)")
    }
  }

  private func stopCaffeinate() {
    guard let process = caffeinateProcess else { return }
    if process.isRunning {
      process.terminate()
    }
    caffeinateProcess = nil
  }

  private func startDockFlash() {
    stopDockFlash()
    let prefs = preferencesStore.get()
    guard prefs.flashDurationMs > 0 else { return }
    flashStartedAt = Date()
    NSApp.requestUserAttention(.informationalRequest)
    flashTimer = Timer.scheduledTimer(withTimeInterval: Double(prefs.flashIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let startedAt = self.flashStartedAt else { return }
        let prefs = self.preferencesStore.get()
        if Date().timeIntervalSince(startedAt) * 1000 >= Double(prefs.flashDurationMs) {
          self.stopDockFlash()
          return
        }
        NSApp.requestUserAttention(.informationalRequest)
      }
    }
  }

  private func stopDockFlash() {
    flashTimer?.invalidate()
    flashTimer = nil
    flashStartedAt = nil
  }

  private func setOpenAtLogin(_ enabled: Bool) {
    guard #available(macOS 13.0, *) else { return }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      print("Could not update login item: \(error.localizedDescription)")
    }
  }
}

private extension StateSnapshot {
  var hasWorkingSession: Bool {
    sessions.contains { session in
      !session.metadata.headless && session.state.isWorkLike
    } || currentState.isWorkLike
  }
}

private extension ClawdState {
  var isWorkLike: Bool {
    switch self {
    case .thinking, .working, .juggling, .sweeping, .carrying, .miniWorking:
      return true
    default:
      return false
    }
  }
}
