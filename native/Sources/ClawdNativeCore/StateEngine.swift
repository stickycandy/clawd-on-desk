import Foundation

public struct StateTiming: Equatable, Sendable {
  public enum SleepMode: String, Equatable, Sendable {
    case full
    case direct
  }

  public var minDisplayMs: [ClawdState: Int]
  public var autoReturnMs: [ClawdState: Int]
  public var deepSleepTimeoutMs: Int
  public var mouseIdleTimeoutMs: Int
  public var mouseSleepTimeoutMs: Int
  public var yawnDurationMs: Int
  public var wakeDurationMs: Int
  public var collapseDurationMs: Int
  public var sleepMode: SleepMode

  public init(
    minDisplayMs: [ClawdState: Int] = [
      .attention: 4_000,
      .error: 5_000,
      .sweeping: 2_000,
      .notification: 4_000,
      .carrying: 3_000,
      .working: 1_000,
      .thinking: 1_000
    ],
    autoReturnMs: [ClawdState: Int] = [
      .attention: 4_000,
      .error: 5_000,
      .sweeping: 300_000,
      .notification: 5_000,
      .carrying: 3_000,
      .miniAlert: 5_000,
      .miniHappy: 4_000
    ],
    deepSleepTimeoutMs: Int = 600_000,
    mouseIdleTimeoutMs: Int = 20_000,
    mouseSleepTimeoutMs: Int = 60_000,
    yawnDurationMs: Int = 3_000,
    wakeDurationMs: Int = 1_500,
    collapseDurationMs: Int = 0,
    sleepMode: SleepMode = .full
  ) {
    self.minDisplayMs = minDisplayMs
    self.autoReturnMs = autoReturnMs
    self.deepSleepTimeoutMs = deepSleepTimeoutMs
    self.mouseIdleTimeoutMs = mouseIdleTimeoutMs
    self.mouseSleepTimeoutMs = mouseSleepTimeoutMs
    self.yawnDurationMs = yawnDurationMs
    self.wakeDurationMs = wakeDurationMs
    self.collapseDurationMs = collapseDurationMs
    self.sleepMode = sleepMode
  }
}

public final class StateEngine: @unchecked Sendable {
  public typealias Subscriber = @Sendable (StateSnapshot) -> Void

  private let lock = NSRecursiveLock()
  private var timings: StateTiming
  private var sessionsById: [String: AgentSession] = [:]
  private var currentState: ClawdState = .idle
  private var previousState: ClawdState = .idle
  private var stateChangedAt = Date()
  private var doNotDisturb = false
  private var subscribers: [UUID: Subscriber] = [:]
  private var autoReturnWorkItem: DispatchWorkItem?

  public init(timings: StateTiming = StateTiming()) {
    self.timings = timings
  }

  public func updateTimings(_ timings: StateTiming) {
    lock.lock()
    self.timings = timings
    lock.unlock()
  }

  public func timingSnapshot() -> StateTiming {
    lock.lock()
    defer { lock.unlock() }
    return timings
  }

  public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
    let id = UUID()
    let snapshot = self.snapshot()
    lock.lock()
    subscribers[id] = subscriber
    lock.unlock()
    subscriber(snapshot)
    return id
  }

  public func unsubscribe(_ id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }

  public func enableDoNotDisturb() {
    lock.lock()
    doNotDisturb = true
    setStateLocked(.sleeping, force: true)
    let snapshot = snapshotLocked()
    let callbacks = Array(subscribers.values)
    lock.unlock()
    callbacks.forEach { $0(snapshot) }
  }

  public func disableDoNotDisturb() {
    lock.lock()
    doNotDisturb = false
    recomputeLocked(force: true)
    let snapshot = snapshotLocked()
    let callbacks = Array(subscribers.values)
    lock.unlock()
    callbacks.forEach { $0(snapshot) }
  }

  public func shouldDropForDnd() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return doNotDisturb
  }

  public func setState(_ state: ClawdState, force: Bool = false) {
    publish {
      setStateLocked(state, force: force)
    }
  }

  public func beginMouseSleepSequence() {
    publish {
      guard !doNotDisturb, currentState == .idle, resolveDisplayStateLocked() == .idle else { return }
      if timings.sleepMode == .direct {
        setStateLocked(.sleeping, force: true)
      } else {
        setStateLocked(.yawning, force: true)
      }
    }
  }

  public func deepenSleepIfDozing() {
    publish {
      guard !doNotDisturb, currentState == .dozing else { return }
      setStateLocked(.collapsing, force: true)
    }
  }

  public func wakeFromSleepSequence() {
    publish {
      guard !doNotDisturb else { return }
      switch currentState {
      case .sleeping, .collapsing:
        setStateLocked(.waking, force: true)
      case .dozing, .yawning:
        setStateLocked(.idle, force: true)
      default:
        break
      }
    }
  }

  public func updateSession(
    _ sessionId: String,
    state: ClawdState,
    event: String?,
    metadata: SessionMetadata = SessionMetadata(),
    suppressOneShotVisual: Bool = false
  ) {
    let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    let sid = trimmed.isEmpty ? "default" : trimmed
    publish {
      let now = Date()
      let existing = sessionsById[sid]
      var recent = existing?.recentEvents ?? []
      if let event, !event.isEmpty {
        recent.append(event)
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
      }
      let startedAt = existing?.startedAt ?? now
      let storedState = storedSessionStateLocked(incoming: state, existing: existing, metadata: metadata)
      if event == "SessionEnd" {
        let shouldPlaySweeping = state == .sweeping && existing?.metadata.headless != true
        sessionsById.removeValue(forKey: sid)
        if shouldPlaySweeping && !doNotDisturb {
          setStateLocked(.sweeping, force: false)
        } else {
          recomputeLocked(force: false)
        }
        return
      }
      sessionsById[sid] = AgentSession(
        id: sid,
        state: storedState,
        event: event,
        updatedAt: now,
        startedAt: startedAt,
        metadata: metadata,
        recentEvents: recent
      )
      if state == .sleeping || state == .miniSleep {
        sessionsById[sid]?.state = state
      }
      if metadata.transientPermissionEvent {
        if doNotDisturb {
          recomputeLocked(force: false)
        } else {
          setStateLocked(.notification, force: false)
        }
      } else if state.storesAsIdleOneShot {
        if doNotDisturb || suppressOneShotVisual {
          recomputeLocked(force: false)
        } else {
          setStateLocked(state, force: false)
        }
      } else {
        recomputeLocked(force: false)
      }
    }
  }

  public func dismissSession(_ sessionId: String) {
    publish {
      sessionsById.removeValue(forKey: sessionId)
      recomputeLocked(force: true)
    }
  }

  public func clearSessions(agentId: String? = nil) {
    publish {
      if let agentId {
        sessionsById = sessionsById.filter { $0.value.metadata.agentId != agentId }
      } else {
        sessionsById.removeAll()
      }
      recomputeLocked(force: true)
    }
  }

  public func cleanStaleSessions(now: Date = Date(), sessionStaleMs: Int = 600_000, workingStaleMs: Int = 300_000, detachedIdleStaleMs: Int = 30_000) {
    publish {
      sessionsById = sessionsById.filter { _, session in
        let ageMs = Int(now.timeIntervalSince(session.updatedAt) * 1000)
        if session.state == .working || session.state == .thinking || session.state == .juggling {
          return ageMs <= workingStaleMs
        }
        if session.event == "SessionEnd" || session.state == .sleeping {
          return ageMs <= detachedIdleStaleMs
        }
        return sessionStaleMs == 0 || ageMs <= sessionStaleMs
      }
      recomputeLocked(force: true)
    }
  }

  public func snapshot() -> StateSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotLocked()
  }

  public func current() -> ClawdState {
    lock.lock()
    defer { lock.unlock() }
    return currentState
  }

  public func resolveDisplayState() -> ClawdState {
    lock.lock()
    defer { lock.unlock() }
    return resolveDisplayStateLocked()
  }

  private func publish(_ mutation: () -> Void) {
    lock.lock()
    mutation()
    let snapshot = snapshotLocked()
    let callbacks = Array(subscribers.values)
    lock.unlock()
    callbacks.forEach { $0(snapshot) }
  }

  private func recomputeLocked(force: Bool) {
    if doNotDisturb {
      setStateLocked(.sleeping, force: true)
      return
    }
    setStateLocked(resolveDisplayStateLocked(), force: force)
  }

  private func resolveDisplayStateLocked() -> ClawdState {
    var best = ClawdState.idle
    var hasVisibleSession = false
    for session in sessionsById.values where !session.metadata.headless {
      hasVisibleSession = true
      if session.state.priority > best.priority {
        best = session.state
      }
    }
    return hasVisibleSession ? best : .idle
  }

  private func storedSessionStateLocked(incoming state: ClawdState, existing: AgentSession?, metadata: SessionMetadata) -> ClawdState {
    if metadata.preserveState || metadata.transientPermissionEvent {
      return existing?.state ?? .idle
    }
    return state.storesAsIdleOneShot ? .idle : state
  }

  private func setStateLocked(_ state: ClawdState, force: Bool) {
    guard force || state != currentState else { return }
    let elapsedMs = Int(Date().timeIntervalSince(stateChangedAt) * 1000)
    let requiredMs = timings.minDisplayMs[currentState] ?? 0
    if !force && currentState.priority > state.priority && elapsedMs < requiredMs {
      let delay = requiredMs - elapsedMs
      autoReturnWorkItem?.cancel()
      let work = DispatchWorkItem { [weak self] in
        self?.setState(state, force: true)
      }
      autoReturnWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
      return
    }

    previousState = currentState
    currentState = state
    stateChangedAt = Date()
    autoReturnWorkItem?.cancel()
    if state == .yawning {
      scheduleStateReturnLocked(afterMs: timings.yawnDurationMs, expected: .yawning) { [weak self] in
        self?.setStateLocked(.dozing, force: true)
      }
    } else if state == .collapsing, timings.collapseDurationMs > 0 {
      scheduleStateReturnLocked(afterMs: timings.collapseDurationMs, expected: .collapsing) { [weak self] in
        self?.setStateLocked(.sleeping, force: true)
      }
    } else if state == .waking {
      scheduleStateReturnLocked(afterMs: timings.wakeDurationMs, expected: .waking) { [weak self] in
        guard let self else { return }
        self.recomputeLocked(force: true)
        if self.currentState == .waking {
          self.setStateLocked(.idle, force: true)
        }
      }
    } else if state.isOneShot, let delay = timings.autoReturnMs[state], delay > 0 {
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.publish {
          self.recomputeLocked(force: true)
          if self.currentState == state {
            self.setStateLocked(.idle, force: true)
          }
        }
      }
      autoReturnWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }
  }

  private func scheduleStateReturnLocked(afterMs delay: Int, expected: ClawdState, action: @escaping () -> Void) {
    guard delay > 0 else {
      action()
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.publish {
        guard self.currentState == expected else { return }
        action()
      }
    }
    autoReturnWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
  }

  private func snapshotLocked() -> StateSnapshot {
    StateSnapshot(
      currentState: currentState,
      sessions: sessionsById.values.sorted { $0.updatedAt > $1.updatedAt },
      updatedAt: Date()
    )
  }
}
