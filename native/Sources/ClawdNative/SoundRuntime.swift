import AppKit
import ClawdNativeCore

@MainActor
final class SoundRuntime {
  private let stateEngine: StateEngine
  private let preferencesStore: PreferencesStore
  private let themeRuntime: ThemeRuntime
  private var stateSubscription: UUID?
  private var hasSeenInitialSnapshot = false
  private var lastObservedState: ClawdState?
  private var lastSoundPlayedAt: Date?
  private var currentSound: NSSound?

  private let cooldown: TimeInterval = 10

  init(
    stateEngine: StateEngine,
    preferencesStore: PreferencesStore,
    themeRuntime: ThemeRuntime
  ) {
    self.stateEngine = stateEngine
    self.preferencesStore = preferencesStore
    self.themeRuntime = themeRuntime
  }

  func start() {
    stop()
    stateSubscription = stateEngine.subscribe { [weak self] snapshot in
      Task { @MainActor in
        self?.handle(snapshot)
      }
    }
  }

  func stop() {
    if let stateSubscription {
      stateEngine.unsubscribe(stateSubscription)
      self.stateSubscription = nil
    }
    currentSound?.stop()
    currentSound = nil
    hasSeenInitialSnapshot = false
    lastObservedState = nil
  }

  private func handle(_ snapshot: StateSnapshot) {
    let state = snapshot.currentState
    defer {
      hasSeenInitialSnapshot = true
      lastObservedState = state
    }

    guard hasSeenInitialSnapshot, state != lastObservedState else { return }
    switch state {
    case .attention, .miniHappy:
      playSound(named: "complete")
    case .notification, .miniAlert:
      playSound(named: "confirm")
    default:
      break
    }
  }

  private func playSound(named name: String) {
    let prefs = preferencesStore.get()
    guard !prefs.soundMuted, !stateEngine.shouldDropForDnd() else { return }

    let now = Date()
    if let lastSoundPlayedAt, now.timeIntervalSince(lastSoundPlayedAt) < cooldown {
      return
    }

    let variant = prefs.themeVariant[prefs.theme] ?? "default"
    guard let sound = themeRuntime.resolveSound(
      themeId: prefs.theme,
      name: name,
      variantId: variant,
      overrides: prefs.themeOverrides[prefs.theme]
    ) else { return }

    guard let nsSound = NSSound(contentsOf: sound.url, byReference: true) else { return }
    nsSound.volume = Float(min(max(prefs.soundVolume, 0), 1))
    currentSound?.stop()
    currentSound = nsSound
    if nsSound.play() {
      lastSoundPlayedAt = now
    } else {
      currentSound = nil
    }
  }
}
