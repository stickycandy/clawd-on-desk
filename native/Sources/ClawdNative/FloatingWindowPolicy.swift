import AppKit
import Darwin

@MainActor
enum FloatingWindowPolicy {
  // AppKit's cross-Space flags keep windows visible after a Space switch, but
  // they can still be animated with the source Space during trackpad swipes.
  // The private SkyLight stationary Space mirrors Electron's macOS workaround:
  // move tiny Clawd overlay windows into a system-level Space that is not part
  // of the user's left/right Space transition.
  static let persistentOverlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))

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
    window.canHide = false
    window.isMovable = false
    window.animationBehavior = .none
    moveIntoStationarySpace(window, retryWhenWindowNumberIsMissing: true)
  }

  private static var stationarySpace: SkyLightStationarySpace?
  private static var stationarySpaceUnavailable = false
  private static var warnedStationarySpaceFailure = false

  private static func moveIntoStationarySpace(_ window: NSWindow, retryWhenWindowNumberIsMissing: Bool) {
    let windowNumber = window.windowNumber
    guard windowNumber > 0 else {
      if retryWhenWindowNumberIsMissing {
        DispatchQueue.main.async { [weak window] in
          guard let window else { return }
          moveIntoStationarySpace(window, retryWhenWindowNumberIsMissing: false)
        }
      }
      return
    }
    guard let stationarySpace = loadStationarySpace() else { return }
    if !stationarySpace.addWindow(windowNumber: windowNumber) {
      warnStationarySpaceFailure("failed to add window \(windowNumber) to stationary SkyLight space")
    }
  }

  private static func loadStationarySpace() -> SkyLightStationarySpace? {
    if stationarySpaceUnavailable { return nil }
    if let stationarySpace { return stationarySpace }
    do {
      let space = try SkyLightStationarySpace()
      stationarySpace = space
      return space
    } catch {
      stationarySpaceUnavailable = true
      warnStationarySpaceFailure("failed to initialize stationary SkyLight space: \(error.localizedDescription)")
      return nil
    }
  }

  private static func warnStationarySpaceFailure(_ message: String) {
    guard !warnedStationarySpaceFailure else { return }
    warnedStationarySpaceFailure = true
    print("Clawd Native: \(message)")
  }
}

private final class SkyLightStationarySpace {
  private typealias SLSMainConnectionIDFunction = @convention(c) () -> Int32
  private typealias SLSSpaceCreateFunction = @convention(c) (Int32, Int32, Int32) -> Int32
  private typealias SLSSpaceSetAbsoluteLevelFunction = @convention(c) (Int32, Int32, Int32) -> Int32
  private typealias SLSShowSpacesFunction = @convention(c) (Int32, UnsafeRawPointer) -> Int32
  private typealias SLSSpaceAddWindowsAndRemoveFromSpacesFunction = @convention(c) (Int32, Int32, UnsafeRawPointer, Int32) -> Int32

  private let handle: UnsafeMutableRawPointer
  private let connection: Int32
  private let space: Int32
  private let addWindowsAndRemoveFromSpaces: SLSSpaceAddWindowsAndRemoveFromSpacesFunction

  init() throws {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW) else {
      throw SkyLightError.loadFailed(Self.lastDLError())
    }
    self.handle = handle

    let mainConnection: SLSMainConnectionIDFunction = try Self.resolve("SLSMainConnectionID", from: handle)
    let createSpace: SLSSpaceCreateFunction = try Self.resolve("SLSSpaceCreate", from: handle)
    let setAbsoluteLevel: SLSSpaceSetAbsoluteLevelFunction = try Self.resolve("SLSSpaceSetAbsoluteLevel", from: handle)
    let showSpaces: SLSShowSpacesFunction = try Self.resolve("SLSShowSpaces", from: handle)
    let addWindowsAndRemoveFromSpaces: SLSSpaceAddWindowsAndRemoveFromSpacesFunction = try Self.resolve(
      "SLSSpaceAddWindowsAndRemoveFromSpaces",
      from: handle
    )

    let connection = mainConnection()
    let space = createSpace(connection, 1, 0)
    guard connection != 0, space != 0 else {
      throw SkyLightError.invalidSpace(connection: connection, space: space)
    }
    self.connection = connection
    self.space = space
    self.addWindowsAndRemoveFromSpaces = addWindowsAndRemoveFromSpaces

    _ = setAbsoluteLevel(connection, space, 100)
    _ = Self.withNumberArrayPointer(space) { pointer in
      showSpaces(connection, pointer)
    }
  }

  deinit {
    dlclose(handle)
  }

  func addWindow(windowNumber: Int) -> Bool {
    Self.withNumberArrayPointer(Int32(windowNumber)) { pointer in
      addWindowsAndRemoveFromSpaces(connection, space, pointer, 7) == 0
    }
  }

  private static func resolve<T>(_ symbol: String, from handle: UnsafeMutableRawPointer) throws -> T {
    guard let pointer = dlsym(handle, symbol) else {
      throw SkyLightError.symbolMissing(symbol)
    }
    return unsafeBitCast(pointer, to: T.self)
  }

  private static func withNumberArrayPointer<T>(_ value: Int32, _ body: (UnsafeRawPointer) -> T) -> T {
    let array = NSArray(object: NSNumber(value: value))
    return body(UnsafeRawPointer(Unmanaged.passUnretained(array).toOpaque()))
  }

  private static func lastDLError() -> String {
    guard let message = dlerror() else { return "unknown dlopen error" }
    return String(cString: message)
  }
}

private enum SkyLightError: LocalizedError {
  case loadFailed(String)
  case symbolMissing(String)
  case invalidSpace(connection: Int32, space: Int32)

  var errorDescription: String? {
    switch self {
    case .loadFailed(let message):
      return message
    case .symbolMissing(let symbol):
      return "missing \(symbol)"
    case .invalidSpace(let connection, let space):
      return "invalid connection \(connection), space \(space)"
    }
  }
}
