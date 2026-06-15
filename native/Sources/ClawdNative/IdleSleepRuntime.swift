import AppKit
import ClawdNativeCore

@MainActor
final class IdleSleepRuntime {
  private let stateEngine: StateEngine
  private let preferencesStore: PreferencesStore
  private let themeRuntime: ThemeRuntime
  private let petWindow: () -> PetWindowController?
  private var timer: Timer?
  private var lastMouseLocation = NSEvent.mouseLocation
  private var mouseStillSince = Date()
  private var idleAnimationPlayed = false
  private var sleepTriggered = false

  init(
    stateEngine: StateEngine,
    preferencesStore: PreferencesStore,
    themeRuntime: ThemeRuntime,
    petWindow: @escaping () -> PetWindowController?
  ) {
    self.stateEngine = stateEngine
    self.preferencesStore = preferencesStore
    self.themeRuntime = themeRuntime
    self.petWindow = petWindow
  }

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tick()
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    let currentMouse = NSEvent.mouseLocation
    let moved = currentMouse != lastMouseLocation
    if moved {
      lastMouseLocation = currentMouse
      mouseStillSince = Date()
      idleAnimationPlayed = false
      sleepTriggered = false
      petWindow()?.clearIdleAnimation()
      if stateEngine.current().isSleepSequence {
        stateEngine.wakeFromSleepSequence()
      }
      return
    }

    let prefs = preferencesStore.get()
    guard !prefs.miniMode, !stateEngine.shouldDropForDnd() else { return }
    let timing = stateEngine.timingSnapshot()
    let currentState = stateEngine.current()
    let elapsedMs = Int(Date().timeIntervalSince(mouseStillSince) * 1000)

    if currentState == .dozing, elapsedMs >= timing.deepSleepTimeoutMs {
      stateEngine.deepenSleepIfDozing()
      return
    }

    guard currentState == .idle, stateEngine.resolveDisplayState() == .idle else {
      petWindow()?.clearIdleAnimation()
      return
    }

    if !sleepTriggered, elapsedMs >= timing.mouseSleepTimeoutMs {
      sleepTriggered = true
      petWindow()?.clearIdleAnimation()
      stateEngine.beginMouseSleepSequence()
      return
    }

    if !idleAnimationPlayed,
       elapsedMs >= timing.mouseIdleTimeoutMs,
       let pick = pickIdleAnimation(preferences: prefs) {
      idleAnimationPlayed = true
      petWindow()?.playIdleAnimation(fileName: pick.file, durationMs: pick.duration)
    }
  }

  private func pickIdleAnimation(preferences prefs: Preferences) -> (file: String, duration: Int)? {
    let variant = prefs.themeVariant[prefs.theme] ?? "default"
    guard let theme = try? themeRuntime.loadTheme(
      id: prefs.theme,
      variantId: variant,
      overrides: prefs.themeOverrides[prefs.theme]
    ) else { return nil }
    let candidates = (theme.manifest.idleAnimations ?? [])
      .filter { theme.assetExists($0.file) }
    guard let chosen = candidates.randomElement() else { return nil }
    return (chosen.file, max(chosen.duration ?? 0, 0))
  }
}
