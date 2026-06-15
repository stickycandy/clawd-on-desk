import Darwin
import XCTest
@testable import ClawdNativeCore

final class RuntimeSurfaceTests: XCTestCase {
  func testLocalHTTPServerParsesSplitStatePostOverTCP() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-split-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let engine = StateEngine()
    let server = LocalHTTPServer(
      engine: engine,
      preferences: { Preferences() },
      permissions: PermissionCoordinator(),
      runtimeConfigURL: root.appendingPathComponent("runtime.json")
    )
    defer { server.stop() }
    let port = try startServer(server, ports: Array(26100..<26200))

    let body = #"{"state":"working","session_id":"split-s1","event":"PreToolUse","agent_id":"codex","cwd":"/tmp/clawd split"}"#
    let header = [
      "POST /state HTTP/1.1",
      "Host: 127.0.0.1:\(port)",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "Connection: close",
      "",
      ""
    ].joined(separator: "\r\n")
    let postResponse = try tcpHTTPExchange(port: port, parts: [Data(header.utf8), Data(body.utf8)])
    let postText = String(decoding: postResponse, as: UTF8.self)
    XCTAssertTrue(postText.contains("HTTP/1.1 200 OK"), postText)
    XCTAssertEqual(httpBody(postResponse), Data("ok".utf8), postText)

    let sessionsRequest = Data("GET /sessions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
    let sessionsResponse = try tcpHTTPExchange(port: port, parts: [sessionsRequest])
    let sessionsText = String(decoding: sessionsResponse, as: UTF8.self)
    XCTAssertTrue(sessionsText.contains("HTTP/1.1 200 OK"), sessionsText)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(StateSnapshot.self, from: httpBody(sessionsResponse))
    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "split-s1" })
    XCTAssertEqual(snapshot.currentState, .working)
    XCTAssertEqual(session.state, .working)
    XCTAssertEqual(session.event, "PreToolUse")
    XCTAssertEqual(session.metadata.agentId, "codex")
    XCTAssertEqual(session.metadata.cwd, "/tmp/clawd split")
  }

  func testCodexOfficialSubagentStateMarksSessionHeadless() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-codex-subagent-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let engine = StateEngine()
    let server = LocalHTTPServer(
      engine: engine,
      preferences: { Preferences() },
      permissions: PermissionCoordinator(),
      runtimeConfigURL: root.appendingPathComponent("runtime.json")
    )
    defer { server.stop() }
    let port = try startServer(server, ports: Array(26400..<26500))

    let body = #"{"state":"working","session_id":"codex:sub","event":"PreToolUse","agent_id":"codex","hook_source":"codex-official","codex_session_role":"subagent"}"#
    let response = try tcpHTTPExchange(port: port, parts: [httpRequest(method: "POST", path: "/state", port: port, body: body)])
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("HTTP/1.1 200 OK"), text)

    let sessionsResponse = try tcpHTTPExchange(
      port: port,
      parts: [Data("GET /sessions HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)]
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(StateSnapshot.self, from: httpBody(sessionsResponse))
    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "codex:sub" })
    XCTAssertTrue(session.metadata.headless)
  }

  func testCodexOfficialSubagentPermissionReturnsNoDecisionBeforeAutoApprove() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-codex-subagent-permission-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let server = LocalHTTPServer(
      engine: StateEngine(),
      preferences: { Preferences(autoApproveAllPermissions: true) },
      permissions: PermissionCoordinator(),
      runtimeConfigURL: root.appendingPathComponent("runtime.json")
    )
    defer { server.stop() }
    let port = try startServer(server, ports: Array(26500..<26600))

    let body = #"{"agent_id":"codex","hook_source":"codex-official","codex_session_role":"subagent","session_id":"codex:sub","tool_name":"Bash","tool_input":{"command":"npm test"}}"#
    let response = try tcpHTTPExchange(port: port, parts: [httpRequest(method: "POST", path: "/permission", port: port, body: body)])
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("HTTP/1.1 204 No Content"), text)
    XCTAssertEqual(httpBody(response), Data(), text)
  }

  func testMobilePreviewRouteRequiresEnabledPreference() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-mobile-preview-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let disabledServer = LocalHTTPServer(
      engine: StateEngine(),
      preferences: { Preferences(mobilePreviewEnabled: false) },
      permissions: PermissionCoordinator(),
      runtimeConfigURL: root.appendingPathComponent("disabled-runtime.json")
    )
    let disabledPort = try startServer(disabledServer, ports: Array(26200..<26300))
    defer { disabledServer.stop() }
    let disabledResponse = try tcpHTTPExchange(
      port: disabledPort,
      parts: [Data("GET /mobile-preview HTTP/1.1\r\nHost: 127.0.0.1:\(disabledPort)\r\nConnection: close\r\n\r\n".utf8)]
    )
    let disabledText = String(decoding: disabledResponse, as: UTF8.self)
    XCTAssertTrue(disabledText.contains("HTTP/1.1 404 Not Found"), disabledText)
    XCTAssertEqual(httpBody(disabledResponse), Data("mobile preview disabled".utf8), disabledText)

    let enabledEngine = StateEngine()
    enabledEngine.updateSession(
      "mobile-s1",
      state: .working,
      event: "PreToolUse",
      metadata: SessionMetadata(agentId: "codex", sessionTitle: "<mobile>")
    )
    let enabledServer = LocalHTTPServer(
      engine: enabledEngine,
      preferences: { Preferences(mobilePreviewEnabled: true) },
      permissions: PermissionCoordinator(),
      runtimeConfigURL: root.appendingPathComponent("enabled-runtime.json")
    )
    let enabledPort = try startServer(enabledServer, ports: Array(26300..<26400))
    defer { enabledServer.stop() }
    let enabledResponse = try tcpHTTPExchange(
      port: enabledPort,
      parts: [Data("GET /mobile-preview HTTP/1.1\r\nHost: 127.0.0.1:\(enabledPort)\r\nConnection: close\r\n\r\n".utf8)]
    )
    let enabledText = String(decoding: enabledResponse, as: UTF8.self)
    XCTAssertTrue(enabledText.contains("HTTP/1.1 200 OK"), enabledText)
    let body = String(decoding: httpBody(enabledResponse), as: UTF8.self)
    XCTAssertTrue(body.contains("Clawd Native"))
    XCTAssertTrue(body.contains("&lt;mobile&gt;"))
  }

  func testRemoteSSHTunnelCommandMatchesReverseForwardingShape() {
    let profile = RemoteSSHProfile(
      id: "p1",
      name: "prod",
      host: "example.com",
      user: "alice",
      port: 2200,
      identityFile: "/Users/alice/.ssh/id_ed25519"
    )
    XCTAssertEqual(RemoteSSHRuntime.tunnelCommand(profile: profile, localPort: 23334), [
      "ssh",
      "-T",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=15",
      "-i",
      "/Users/alice/.ssh/id_ed25519",
      "-p",
      "2200",
      "-N",
      "-o",
      "ExitOnForwardFailure=yes",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=3",
      "-R",
      "127.0.0.1:23333:127.0.0.1:23334",
      "alice@example.com"
    ])
  }

  func testRemoteSSHScpArgsUseUppercasePortFlag() {
    let profile = RemoteSSHProfile(id: "p1", host: "example.com", user: "alice", port: 2200)
    XCTAssertEqual(RemoteSSHRuntime.buildScpArgs(profile: profile), [
      "-q",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=15",
      "-P",
      "2200"
    ])
  }

  func testRemoteSSHProbeCommandAcceptsNativeAndElectronServerHeaders() {
    let command = RemoteSSHRuntime.buildProbeCommand(remoteForwardPort: 23335)
    XCTAssertTrue(command.contains("23335"))
    XCTAssertTrue(command.contains("clawd-on-desk-native"))
    XCTAssertTrue(command.contains("clawd-on-desk"))
  }

  func testRemoteNodeProbeOutputParserRequiresAbsoluteSupportedNode() throws {
    let parsed = try XCTUnwrap(RemoteSSHRuntime.parseRemoteNodeProbeOutput("""
    CLAWD_REMOTE_NODE_BIN=/usr/local/bin/node
    CLAWD_REMOTE_NODE_VERSION=v20.11.1
    CLAWD_REMOTE_NODE_SOURCE=path
    """))
    XCTAssertEqual(parsed.nodeBin, "/usr/local/bin/node")
    XCTAssertEqual(parsed.version, "v20.11.1")
    XCTAssertEqual(parsed.source, "path")
    XCTAssertNil(RemoteSSHRuntime.parseRemoteNodeProbeOutput("""
    CLAWD_REMOTE_NODE_BIN=node
    CLAWD_REMOTE_NODE_VERSION=v20.11.1
    CLAWD_REMOTE_NODE_SOURCE=path
    """))
    XCTAssertNil(RemoteSSHRuntime.parseRemoteNodeProbeOutput("""
    CLAWD_REMOTE_NODE_BIN=/usr/bin/node
    CLAWD_REMOTE_NODE_VERSION=v12.22.0
    CLAWD_REMOTE_NODE_SOURCE=path
    """))
  }

  func testRemoteSSHProfileDecodesLegacyNameAndValidatesFields() throws {
    let data = Data(#"{"id":"p1","name":"legacy","host":"example.com"}"#.utf8)
    let profile = try JSONDecoder().decode(RemoteSSHProfile.self, from: data)
    XCTAssertEqual(profile.label, "legacy")
    XCTAssertEqual(profile.name, "legacy")
    XCTAssertEqual(profile.effectivePort, 22)
    if case .failure(let error) = RemoteSSHProfileValidator.validate(profile) {
      XCTFail("legacy profile should validate: \(error.message)")
    }

    let badHost = RemoteSSHProfile(id: "bad", label: "Bad", host: "-bad.example.com")
    if case .success = RemoteSSHProfileValidator.validate(badHost) {
      XCTFail("invalid host should fail validation")
    }

    let badPort = RemoteSSHProfile(id: "bad-port", label: "Bad", host: "example.com", remoteForwardPort: 12345)
    if case .success = RemoteSSHProfileValidator.validate(badPort) {
      XCTFail("invalid remote forward port should fail validation")
    }
  }

  func testRemoteSSHDeployManifestContainsSharedHookFiles() {
    XCTAssertTrue(RemoteSSHRuntime.hookFiles.contains("clawd-hook.js"))
    XCTAssertTrue(RemoteSSHRuntime.hookFiles.contains("codex-remote-monitor.js"))
    XCTAssertTrue(RemoteSSHRuntime.hookFiles.contains("copilot-install.js"))
  }

  func testNativeDebugPathOverridesDoNotUseHomeClawdFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-paths-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let prefsURL = root.appendingPathComponent("prefs.json")
    let runtimeURL = root.appendingPathComponent("runtime.json")
    XCTAssertEqual(
      PreferencesStore.defaultURL(environment: ["CLAWD_NATIVE_PREFS_PATH": prefsURL.path]),
      prefsURL
    )
    XCTAssertEqual(
      LocalHTTPServer.runtimeConfigURL(environment: ["CLAWD_NATIVE_RUNTIME_PATH": runtimeURL.path]),
      runtimeURL
    )
    try Data(#"{"port":23335}"#.utf8).write(to: runtimeURL)
    XCTAssertEqual(
      NativeHookRuntime.runtimePort(homeDirectory: root, environment: ["CLAWD_NATIVE_RUNTIME_PATH": runtimeURL.path]),
      23335
    )
  }

  func testLocalHTTPServerSkipsOccupiedPortBeforeWritingRuntime() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-server-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var occupiedServer: LocalHTTPServer?
    var occupiedPort: Int?
    for candidate in 26000..<26100 {
      let server = LocalHTTPServer(
        engine: StateEngine(),
        preferences: { Preferences() },
        permissions: PermissionCoordinator(),
        runtimeConfigURL: root.appendingPathComponent("occupied-\(candidate).json")
      )
      if let port = try? server.start(ports: [candidate]) {
        occupiedServer = server
        occupiedPort = port
        break
      }
    }
    guard let occupiedServer, let occupiedPort else {
      XCTFail("expected a free local port for server smoke test")
      return
    }
    defer { occupiedServer.stop() }

    let runtimeURL = root.appendingPathComponent("runtime.json")
    let fallbackPorts = Array(occupiedPort...(occupiedPort + 10))
    let server = LocalHTTPServer(
      engine: StateEngine(),
      preferences: { Preferences() },
      permissions: PermissionCoordinator(),
      runtimeConfigURL: runtimeURL
    )
    defer { server.stop() }
    let actualPort = try server.start(ports: fallbackPorts)
    XCTAssertNotEqual(actualPort, occupiedPort)
    let runtimeData = try Data(contentsOf: runtimeURL)
    let runtime = try XCTUnwrap(JSONSerialization.jsonObject(with: runtimeData) as? [String: Any])
    XCTAssertEqual(runtime["app"] as? String, LocalHTTPServer.serverId)
    XCTAssertEqual(runtime["port"] as? Int, actualPort)
  }

  func testDiagnosticsFlagsMissingAgentRuntimeDependencies() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clawd-native-diagnostics-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("hooks", isDirectory: true), withIntermediateDirectories: true)

    let missingReport = Diagnostics.localReport(
      serverPort: 23333,
      preferencesURL: root.appendingPathComponent("prefs.json"),
      projectRoot: root
    )
    let missing = try XCTUnwrap(missingReport.first { $0.id == "agent-runtime" })
    XCTAssertEqual(missing.status, "warning")
    XCTAssertTrue(missing.message.contains("agents/kimi-cli.js"))

    let agentsDir = root.appendingPathComponent("agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    try Data("module.exports = {};".utf8).write(to: agentsDir.appendingPathComponent("kimi-cli.js"))

    let readyReport = Diagnostics.localReport(
      serverPort: 23333,
      preferencesURL: root.appendingPathComponent("prefs.json"),
      projectRoot: root
    )
    let ready = try XCTUnwrap(readyReport.first { $0.id == "agent-runtime" })
    XCTAssertEqual(ready.status, "ok")
  }

  func testUpdaterAheadBehindParser() {
    XCTAssertEqual(UpdaterRuntime.parseAheadBehind("ahead 0\tbehind 3")?.behind, 3)
    XCTAssertEqual(UpdaterRuntime.parseAheadBehind("ahead 2\tbehind 0")?.ahead, 2)
    XCTAssertNil(UpdaterRuntime.parseAheadBehind("bad"))
  }

  func testUpdateBubbleLayoutDefaultsToTopRight() {
    let frame = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: false,
      bubbleSize: CGSize(width: 340, height: 180),
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 900, y: 120, width: 180, height: 180)
    )
    XCTAssertEqual(frame.origin.x, 852)
    XCTAssertEqual(frame.origin.y, 612)
  }

  func testUpdateBubbleLayoutReservesPermissionStackHeight() {
    let frame = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: false,
      bubbleSize: CGSize(width: 340, height: 180),
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: nil,
      reservedHeight: 260
    )
    XCTAssertEqual(frame.origin.x, 852)
    XCTAssertEqual(frame.origin.y, 352)
  }

  func testUpdateBubbleLayoutFollowsPetAndClampsToWorkArea() {
    let below = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: true,
      bubbleSize: CGSize(width: 340, height: 180),
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 900, y: 300, width: 180, height: 180)
    )
    XCTAssertEqual(below.origin.y, 114)
    XCTAssertEqual(below.origin.x, 820)

    let side = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: true,
      bubbleSize: CGSize(width: 340, height: 260),
      workArea: CGRect(x: 0, y: 0, width: 700, height: 500),
      petFrame: CGRect(x: 260, y: 110, width: 180, height: 180)
    )
    XCTAssertGreaterThanOrEqual(side.origin.x, 0)
    XCTAssertGreaterThanOrEqual(side.origin.y, 8)
    XCTAssertLessThanOrEqual(side.maxX, 700)
    XCTAssertLessThanOrEqual(side.maxY, 492)
  }

  func testUpdateBubbleLayoutFollowsPetBelowReservedHudAndStack() {
    let frame = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: true,
      bubbleSize: CGSize(width: 340, height: 180),
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 900, y: 600, width: 180, height: 180),
      reservedHeight: 140,
      hudReservedOffset: 48
    )
    XCTAssertEqual(frame.origin.x, 820)
    XCTAssertEqual(frame.origin.y, 226)

    let above = UpdateBubbleLayout.computeBounds(
      bubbleFollowPet: true,
      bubbleSize: CGSize(width: 340, height: 180),
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 420, y: 300, width: 180, height: 180),
      reservedHeight: 320,
      hudReservedOffset: 80
    )
    XCTAssertEqual(above.origin.x, 340)
    XCTAssertEqual(above.origin.y, 486)
  }

  func testPermissionBubbleStackLayoutUsesStableOrderAndPetFallbacks() {
    let corner = BubbleStackLayout.computeBounds(
      followPet: false,
      bubbleHeights: [200, 220],
      bubbleWidth: 420,
      margin: 8,
      gap: 10,
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 900, y: 300, width: 180, height: 180)
    )
    XCTAssertEqual(corner.map { Int($0.origin.y) }, [592, 362])
    XCTAssertEqual(corner.first?.origin.x, 772)

    let below = BubbleStackLayout.computeBounds(
      followPet: true,
      bubbleHeights: [200, 200],
      bubbleWidth: 420,
      margin: 8,
      gap: 10,
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 900, y: 600, width: 180, height: 180)
    )
    XCTAssertEqual(below.map { Int($0.origin.y) }, [390, 180])
    XCTAssertEqual(below.first?.origin.x, 780)

    let side = BubbleStackLayout.computeBounds(
      followPet: true,
      bubbleHeights: [200, 220],
      bubbleWidth: 420,
      margin: 8,
      gap: 10,
      workArea: CGRect(x: 0, y: 0, width: 1200, height: 800),
      petFrame: CGRect(x: 900, y: 300, width: 180, height: 180)
    )
    XCTAssertEqual(side.first?.origin.x, 470)
    XCTAssertGreaterThan(side[0].origin.y, side[1].origin.y)
  }

  func testMiniModeLayoutSnapsToElectronCompatibleEdges() throws {
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let miniSize = CGSize(width: 112, height: 112)

    let right = try XCTUnwrap(MiniModeLayout.snapResult(
      windowFrame: CGRect(x: 840, y: 300, width: 180, height: 180),
      workAreas: [workArea],
      miniSize: miniSize,
      offsetRatio: 0.486
    ))
    XCTAssertEqual(right.edge, .right)
    XCTAssertEqual(right.preMiniOrigin.x, 840)
    XCTAssertEqual(right.miniFrame.origin.x, 942.432, accuracy: 0.001)
    XCTAssertEqual(right.miniFrame.origin.y, 334, accuracy: 0.001)

    let left = try XCTUnwrap(MiniModeLayout.snapResult(
      windowFrame: CGRect(x: -20, y: 300, width: 180, height: 180),
      workAreas: [workArea],
      miniSize: miniSize,
      offsetRatio: 0.486
    ))
    XCTAssertEqual(left.edge, .left)
    XCTAssertEqual(left.preMiniOrigin.x, -20)
    XCTAssertEqual(left.miniFrame.origin.x, -54.432, accuracy: 0.001)
    XCTAssertEqual(left.miniFrame.origin.y, 334, accuracy: 0.001)
  }

  func testSessionHUDEligibilityHidesInMiniAndTransitionStates() {
    let now = Date()
    let visible = AgentSession(
      id: "visible",
      state: .working,
      event: "PreToolUse",
      updatedAt: now,
      startedAt: now,
      metadata: SessionMetadata(agentId: "codex")
    )
    let headless = AgentSession(
      id: "headless",
      state: .working,
      event: "PreToolUse",
      updatedAt: now,
      startedAt: now,
      metadata: SessionMetadata(agentId: "codex", headless: true)
    )
    let sleeping = AgentSession(
      id: "sleeping",
      state: .sleeping,
      event: "SessionEnd",
      updatedAt: now,
      startedAt: now,
      metadata: SessionMetadata(agentId: "codex")
    )
    let snapshot = StateSnapshot(currentState: .working, sessions: [headless, sleeping, visible], updatedAt: now)

    XCTAssertEqual(SessionHUDEligibility.visibleSessions(in: snapshot).map(\.id), ["visible"])
    XCTAssertTrue(SessionHUDEligibility.isBaseEligible(snapshot: snapshot, sessionHudEnabled: true))
    XCTAssertTrue(SessionHUDEligibility.shouldShow(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: true,
      clickRevealed: false
    ))
    XCTAssertTrue(SessionHUDEligibility.shouldShow(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: true
    ))
    XCTAssertFalse(SessionHUDEligibility.shouldShow(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: false
    ))
    XCTAssertFalse(SessionHUDEligibility.isBaseEligible(snapshot: nil, sessionHudEnabled: true))
    XCTAssertFalse(SessionHUDEligibility.isBaseEligible(snapshot: snapshot, sessionHudEnabled: false))
    XCTAssertFalse(SessionHUDEligibility.isBaseEligible(snapshot: snapshot, sessionHudEnabled: true, petHidden: true))
    XCTAssertFalse(SessionHUDEligibility.isBaseEligible(snapshot: snapshot, sessionHudEnabled: true, miniMode: true))
    XCTAssertFalse(SessionHUDEligibility.isBaseEligible(snapshot: snapshot, sessionHudEnabled: true, miniTransitioning: true))
    XCTAssertFalse(SessionHUDEligibility.shouldShow(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: true,
      clickRevealed: true,
      miniMode: true
    ))

    let hiddenOnly = StateSnapshot(currentState: .idle, sessions: [headless, sleeping], updatedAt: now)
    XCTAssertFalse(SessionHUDEligibility.isBaseEligible(snapshot: hiddenOnly, sessionHudEnabled: true))
  }

  func testSessionHUDAutoHideVisibilityTracksRevealHotZoneAndGrace() {
    let now = Date()
    let visible = AgentSession(
      id: "visible",
      state: .working,
      event: "PreToolUse",
      updatedAt: now,
      startedAt: now,
      metadata: SessionMetadata(agentId: "codex")
    )
    let snapshot = StateSnapshot(currentState: .working, sessions: [visible], updatedAt: now)

    var result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: false,
      inHotZone: true,
      now: 1.0,
      visibleHoldUntil: 0,
      hideGraceSeconds: 0.5
    )
    XCTAssertFalse(result.show)
    XCTAssertEqual(result.nextHoldUntil, 0)

    result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: true,
      inHotZone: true,
      now: 1.0,
      visibleHoldUntil: 0,
      hideGraceSeconds: 0.5
    )
    XCTAssertTrue(result.show)
    XCTAssertEqual(result.nextHoldUntil, 1.5, accuracy: 0.0001)

    result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: true,
      inHotZone: false,
      now: 1.2,
      visibleHoldUntil: 1.5,
      hideGraceSeconds: 0.5
    )
    XCTAssertTrue(result.show)
    XCTAssertEqual(result.nextHoldUntil, 1.5, accuracy: 0.0001)

    result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: true,
      inHotZone: false,
      now: 1.5,
      visibleHoldUntil: 1.5,
      hideGraceSeconds: 0.5
    )
    XCTAssertFalse(result.show)
    XCTAssertEqual(result.nextHoldUntil, 1.5, accuracy: 0.0001)

    result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: true,
      clickRevealed: false,
      inHotZone: false,
      now: 2.0,
      visibleHoldUntil: 0,
      hideGraceSeconds: 0.5
    )
    XCTAssertTrue(result.show)
    XCTAssertEqual(result.nextHoldUntil, 0)

    result = SessionHUDEligibility.evaluateAutoHideVisibility(
      snapshot: snapshot,
      sessionHudEnabled: true,
      sessionHudPinned: false,
      clickRevealed: true,
      inHotZone: true,
      now: 2.0,
      visibleHoldUntil: 0,
      hideGraceSeconds: 0.5,
      petHidden: true
    )
    XCTAssertFalse(result.show)
  }

  func testSessionHUDAutoHideHotZoneUnionsExpandedPetAndHudFrames() {
    let zone = SessionHUDEligibility.makeAutoHideHotZone(
      petHitFrame: CGRect(x: 0, y: 0, width: 80, height: 80),
      hudFrame: CGRect(x: 0, y: 100, width: 240, height: 28),
      padding: 24
    )

    XCTAssertEqual(zone.rects.count, 2)
    XCTAssertTrue(SessionHUDEligibility.pointInHotZone(CGPoint(x: 40, y: 40), hotZone: zone))
    XCTAssertTrue(SessionHUDEligibility.pointInHotZone(CGPoint(x: 100, y: 110), hotZone: zone))
    XCTAssertTrue(SessionHUDEligibility.pointInHotZone(CGPoint(x: 40, y: 90), hotZone: zone))
    XCTAssertFalse(SessionHUDEligibility.pointInHotZone(CGPoint(x: 500, y: 500), hotZone: zone))
    XCTAssertFalse(SessionHUDEligibility.pointInHotZone(
      CGPoint(x: 0, y: 0),
      hotZone: SessionHUDEligibility.makeAutoHideHotZone(petHitFrame: nil, hudFrame: nil)
    ))
  }

  func testMiniModeLayoutIgnoresNonEdgeAndClampsY() throws {
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 500)
    XCTAssertNil(MiniModeLayout.snapResult(
      windowFrame: CGRect(x: 300, y: 160, width: 180, height: 180),
      workAreas: [workArea],
      miniSize: CGSize(width: 112, height: 112),
      offsetRatio: 0.486
    ))

    let top = try XCTUnwrap(MiniModeLayout.snapResult(
      windowFrame: CGRect(x: 840, y: 390, width: 180, height: 180),
      workAreas: [workArea],
      miniSize: CGSize(width: 112, height: 112),
      offsetRatio: 0.486
    ))
    XCTAssertEqual(top.edge, .right)
    XCTAssertEqual(top.miniFrame.maxY, 480, accuracy: 0.001)
  }

  func testMiniModeLayoutPeekMovesInwardAndRestores() {
    let rightFrame = CGRect(x: 942.432, y: 334, width: 112, height: 112)
    let rightPeek = MiniModeLayout.peekFrame(miniFrame: rightFrame, edge: .right, peeking: true)
    XCTAssertEqual(rightPeek.origin.x, 917.432, accuracy: 0.001)
    XCTAssertEqual(
      MiniModeLayout.peekFrame(miniFrame: rightPeek, edge: .right, peeking: false).origin.x,
      rightFrame.origin.x,
      accuracy: 0.001
    )

    let leftFrame = CGRect(x: -54.432, y: 334, width: 112, height: 112)
    let leftPeek = MiniModeLayout.peekFrame(miniFrame: leftFrame, edge: .left, peeking: true)
    XCTAssertEqual(leftPeek.origin.x, -29.432, accuracy: 0.001)
    XCTAssertEqual(
      MiniModeLayout.peekFrame(miniFrame: leftPeek, edge: .left, peeking: false).origin.x,
      leftFrame.origin.x,
      accuracy: 0.001
    )
  }

  func testMiniModeLayoutMenuEntryCrabwalkTargetsMatchElectronFormula() {
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let rightFrame = CGRect(x: 620, y: 240, width: 180, height: 180)
    XCTAssertEqual(MiniModeLayout.menuEntryEdge(windowFrame: rightFrame, workArea: workArea), .right)
    let rightTarget = MiniModeLayout.crabwalkFrame(
      windowFrame: rightFrame,
      workArea: workArea,
      edge: .right,
      adjacentSeam: false
    )
    XCTAssertEqual(rightTarget.origin.x, 865)
    XCTAssertEqual(MiniModeLayout.crabwalkDurationMs(from: rightFrame, to: rightTarget), 2042)

    let leftFrame = CGRect(x: 180, y: 240, width: 180, height: 180)
    XCTAssertEqual(MiniModeLayout.menuEntryEdge(windowFrame: leftFrame, workArea: workArea), .left)
    let leftTarget = MiniModeLayout.crabwalkFrame(
      windowFrame: leftFrame,
      workArea: workArea,
      edge: .left,
      adjacentSeam: false
    )
    XCTAssertEqual(leftTarget.origin.x, -45)

    let adjacentRight = MiniModeLayout.crabwalkFrame(
      windowFrame: rightFrame,
      workArea: workArea,
      edge: .right,
      adjacentSeam: true
    )
    XCTAssertEqual(adjacentRight.origin.x, 820)
  }

  func testMiniModeLayoutMenuJumpTargetsOffscreenOrContainedMini() {
    let displays = [
      MiniModeLayout.DisplayGeometry(
        bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
        workArea: CGRect(x: 0, y: 0, width: 1000, height: 760)
      ),
      MiniModeLayout.DisplayGeometry(
        bounds: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        workArea: CGRect(x: 1000, y: 0, width: 1000, height: 760)
      )
    ]
    let crabwalkFrame = CGRect(x: 865, y: 240, width: 180, height: 180)
    let miniFrame = CGRect(x: 942.432, y: 274, width: 112, height: 112)

    let rightJump = MiniModeLayout.menuJumpFrame(
      crabwalkFrame: crabwalkFrame,
      miniFrame: miniFrame,
      edge: .right,
      displays: displays,
      adjacentSeam: false
    )
    XCTAssertEqual(rightJump.origin.x, 2000)
    XCTAssertEqual(rightJump.origin.y, 240)
    XCTAssertEqual(rightJump.size, crabwalkFrame.size)

    let leftJump = MiniModeLayout.menuJumpFrame(
      crabwalkFrame: CGRect(x: -45, y: 240, width: 180, height: 180),
      miniFrame: CGRect(x: -54.432, y: 274, width: 112, height: 112),
      edge: .left,
      displays: displays,
      adjacentSeam: false
    )
    XCTAssertEqual(leftJump.origin.x, -180)

    let adjacentJump = MiniModeLayout.menuJumpFrame(
      crabwalkFrame: crabwalkFrame,
      miniFrame: miniFrame,
      edge: .right,
      displays: displays,
      adjacentSeam: true
    )
    XCTAssertEqual(adjacentJump.origin.x, miniFrame.origin.x)
    XCTAssertEqual(adjacentJump.size, crabwalkFrame.size)
  }

  func testMiniModeLayoutExitFrameAvoidsImmediateResnap() {
    let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let normalSize = CGSize(width: 180, height: 180)

    let right = MiniModeLayout.exitFrame(
      preMiniOrigin: CGPoint(x: 850, y: 260),
      workArea: workArea,
      normalSize: normalSize
    )
    XCTAssertEqual(right.origin.x, 765)

    let left = MiniModeLayout.exitFrame(
      preMiniOrigin: CGPoint(x: -20, y: 260),
      workArea: workArea,
      normalSize: normalSize
    )
    XCTAssertEqual(left.origin.x, 85)

    let middle = MiniModeLayout.exitFrame(
      preMiniOrigin: CGPoint(x: 420, y: 760),
      workArea: workArea,
      normalSize: normalSize
    )
    XCTAssertEqual(middle.origin.x, 420)
    XCTAssertEqual(middle.origin.y, 612)
  }

  func testMiniModeLayoutDetectsInternalSeamAndComputesClip() throws {
    let displays = [
      MiniModeLayout.DisplayGeometry(
        bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
        workArea: CGRect(x: 0, y: 0, width: 1000, height: 760)
      ),
      MiniModeLayout.DisplayGeometry(
        bounds: CGRect(x: 1000, y: 0, width: 1000, height: 800),
        workArea: CGRect(x: 1000, y: 0, width: 1000, height: 760)
      )
    ]
    let boundary = try XCTUnwrap(MiniModeLayout.seamBoundary(
      workArea: displays[0].workArea,
      yMid: 390,
      edge: .right,
      displays: displays
    ))
    XCTAssertEqual(boundary, 1000)

    let frame = CGRect(x: 942.432, y: 334, width: 112, height: 112)
    let clip = try XCTUnwrap(MiniModeLayout.clip(miniFrame: frame, edge: .right, seamBoundary: boundary))
    XCTAssertEqual(clip.edge, .right)
    XCTAssertEqual(clip.fraction, 0.514, accuracy: 0.001)

    let peekFrame = MiniModeLayout.peekFrame(miniFrame: frame, edge: .right, peeking: true)
    let peekClip = try XCTUnwrap(MiniModeLayout.clip(miniFrame: peekFrame, edge: .right, seamBoundary: boundary))
    XCTAssertEqual(peekClip.fraction, 0.737, accuracy: 0.001)
  }

  func testMiniModeLayoutDetectsLeftInternalSeamAndIgnoresOuterEdge() throws {
    let displays = [
      MiniModeLayout.DisplayGeometry(
        bounds: CGRect(x: -1000, y: 0, width: 1000, height: 800),
        workArea: CGRect(x: -1000, y: 0, width: 1000, height: 760)
      ),
      MiniModeLayout.DisplayGeometry(
        bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
        workArea: CGRect(x: 0, y: 0, width: 1000, height: 760)
      )
    ]
    let boundary = try XCTUnwrap(MiniModeLayout.seamBoundary(
      workArea: displays[1].workArea,
      yMid: 390,
      edge: .left,
      displays: displays
    ))
    XCTAssertEqual(boundary, 0)

    let frame = CGRect(x: -54.432, y: 334, width: 112, height: 112)
    let clip = try XCTUnwrap(MiniModeLayout.clip(miniFrame: frame, edge: .left, seamBoundary: boundary))
    XCTAssertEqual(clip.edge, .left)
    XCTAssertEqual(clip.fraction, 0.486, accuracy: 0.001)

    XCTAssertNil(MiniModeLayout.seamBoundary(
      workArea: displays[0].workArea,
      yMid: 390,
      edge: .left,
      displays: displays
    ))
  }

  func testThemeAssetGeometryMapsAppKitMediaFrameAndHitBoxToObjectScale() throws {
    var manifest = ThemeManifest(name: "test", states: ["idle": ["idle.svg"]])
    manifest.viewBox = ThemeManifest.ViewBox(x: -15, y: -25, width: 45, height: 45)
    manifest.objectScale = ThemeManifest.ObjectScale(
      widthRatio: 1.9,
      heightRatio: 1.3,
      imgWidthRatio: nil,
      offsetX: -0.45,
      offsetY: -0.25,
      imgOffsetX: nil,
      objBottom: nil,
      imgBottom: nil,
      fileScales: nil,
      fileOffsets: nil
    )
    let asset = ThemeAsset(
      themeId: "test",
      state: .idle,
      fileName: "idle.svg",
      url: URL(fileURLWithPath: "/tmp/idle.svg"),
      readAccessURL: URL(fileURLWithPath: "/tmp/idle.svg"),
      manifest: manifest
    )
    let bounds = CGRect(x: 0, y: 0, width: 180, height: 180)
    let frame = ThemeAssetGeometry.mediaFrame(for: asset, in: bounds)
    XCTAssertEqual(frame.origin.x, -81, accuracy: 0.001)
    XCTAssertEqual(frame.origin.y, -9, accuracy: 0.001)
    XCTAssertEqual(frame.width, 342, accuracy: 0.001)
    XCTAssertEqual(frame.height, 234, accuracy: 0.001)

    let hitBox = ThemeManifest.HitBox(x: -1, y: 5, w: 17, h: 12)
    let hitRect = try XCTUnwrap(ThemeAssetGeometry.hitRect(for: asset, hitBox: hitBox, in: bounds))
    XCTAssertEqual(hitRect.origin.x, 19.4, accuracy: 0.001)
    XCTAssertEqual(hitRect.origin.y, 0.6, accuracy: 0.001)
    XCTAssertEqual(hitRect.width, 141.2, accuracy: 0.001)
    XCTAssertEqual(hitRect.height, 74.4, accuracy: 0.001)
  }

  func testThemeAssetGeometryUsesNormalizedLayoutForManifestContentBox() throws {
    let runtime = ThemeRuntime(projectRoot: repoRoot())
    let asset = try XCTUnwrap(runtime.resolveAsset(
      themeId: "clawd",
      snapshot: StateSnapshot(currentState: .idle, sessions: [], updatedAt: Date())
    ))
    let frame = ThemeAssetGeometry.mediaFrame(for: asset, in: CGRect(x: 0, y: 0, width: 180, height: 180))
    XCTAssertEqual(frame.origin.x, -27.45, accuracy: 0.01)
    XCTAssertEqual(frame.origin.y, -6.66, accuracy: 0.01)
    XCTAssertEqual(frame.width, 234.9, accuracy: 0.01)
    XCTAssertEqual(frame.height, 234.9, accuracy: 0.01)
  }

  func testThemeAssetGeometryComputesElectronStyleEyeOffset() throws {
    var manifest = ThemeManifest(name: "test", states: ["idle": ["idle.svg"]])
    manifest.viewBox = ThemeManifest.ViewBox(x: 0, y: 0, width: 100, height: 100)
    manifest.eyeTracking = ThemeManifest.EyeTracking(
      enabled: true,
      states: ["idle"],
      eyeRatioX: 0.5,
      eyeRatioY: 0.5,
      maxOffset: 20,
      bodyScale: nil,
      shadowStretch: nil,
      shadowShift: nil,
      ids: nil,
      trackingLayers: nil
    )
    manifest.objectScale = ThemeManifest.ObjectScale(
      widthRatio: 1,
      heightRatio: 1,
      imgWidthRatio: nil,
      offsetX: 0,
      offsetY: 0,
      imgOffsetX: nil,
      objBottom: 0,
      imgBottom: nil,
      fileScales: nil,
      fileOffsets: nil
    )
    let asset = ThemeAsset(
      themeId: "test",
      state: .idle,
      fileName: "idle.svg",
      url: URL(fileURLWithPath: "/tmp/idle.svg"),
      readAccessURL: URL(fileURLWithPath: "/tmp/idle.svg"),
      manifest: manifest
    )

    let offset = try XCTUnwrap(ThemeAssetGeometry.eyeOffset(
      for: asset,
      windowFrame: CGRect(x: 10, y: 20, width: 100, height: 100),
      viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      cursorScreenPoint: CGPoint(x: 90, y: 70)
    ))
    XCTAssertEqual(offset.dx, 2, accuracy: 0.001)
    XCTAssertEqual(offset.dy, 0, accuracy: 0.001)

    let clamped = try XCTUnwrap(ThemeAssetGeometry.eyeOffset(
      for: asset,
      windowFrame: CGRect(x: 10, y: 20, width: 100, height: 100),
      viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      cursorScreenPoint: CGPoint(x: 10_000, y: 70)
    ))
    XCTAssertEqual(clamped.dx, 17, accuracy: 0.001)
  }

  func testThemeAssetGeometryPointerPayloadMapsScreenPointToSVGViewBox() throws {
    var manifest = ThemeManifest(name: "test", states: ["idle": ["idle.svg"]])
    manifest.viewBox = ThemeManifest.ViewBox(x: -12, y: -12, width: 48, height: 48)
    manifest.trustedRuntime = ThemeManifest.TrustedRuntime(scriptedSvgFiles: ["idle.svg"], scriptedSvgCycleMs: nil)
    manifest.objectScale = ThemeManifest.ObjectScale(
      widthRatio: 1,
      heightRatio: 1,
      imgWidthRatio: nil,
      offsetX: 0,
      offsetY: 0,
      imgOffsetX: nil,
      objBottom: 0,
      imgBottom: nil,
      fileScales: nil,
      fileOffsets: nil
    )
    let asset = ThemeAsset(
      themeId: "test",
      state: .idle,
      fileName: "idle.svg",
      url: URL(fileURLWithPath: "/tmp/idle.svg"),
      readAccessURL: URL(fileURLWithPath: "/tmp/idle.svg"),
      manifest: manifest
    )

    let payload = try XCTUnwrap(ThemeAssetGeometry.pointerPayload(
      for: asset,
      windowFrame: CGRect(x: 10, y: 20, width: 100, height: 100),
      viewBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      cursorScreenPoint: CGPoint(x: 60, y: 70)
    ))
    XCTAssertEqual(payload.x, 12, accuracy: 0.001)
    XCTAssertEqual(payload.y, 12, accuracy: 0.001)
    XCTAssertTrue(payload.inside)
  }

  func testThemeAssetGeometryUsesMiniViewBoxForMiniHitBox() throws {
    var manifest = ThemeManifest(name: "test", states: ["mini-idle": ["mini.svg"]])
    manifest.viewBox = ThemeManifest.ViewBox(x: -15, y: -25, width: 45, height: 45)
    manifest.miniMode = ThemeManifest.MiniMode(
      supported: true,
      offsetRatio: 0.486,
      viewBox: ThemeManifest.ViewBox(x: 0, y: 0, width: 48, height: 48),
      states: nil,
      timings: nil,
      glyphFlips: nil
    )
    manifest.objectScale = ThemeManifest.ObjectScale(
      widthRatio: 1,
      heightRatio: 1,
      imgWidthRatio: nil,
      offsetX: 0,
      offsetY: 0,
      imgOffsetX: nil,
      objBottom: 0,
      imgBottom: nil,
      fileScales: nil,
      fileOffsets: nil
    )
    let asset = ThemeAsset(
      themeId: "test",
      state: .miniIdle,
      fileName: "mini.svg",
      url: URL(fileURLWithPath: "/tmp/mini.svg"),
      readAccessURL: URL(fileURLWithPath: "/tmp/mini.svg"),
      manifest: manifest
    )
    let hitBox = ThemeManifest.HitBox(x: 12, y: 12, w: 24, h: 24)
    let hitRect = try XCTUnwrap(ThemeAssetGeometry.hitRect(
      for: asset,
      hitBox: hitBox,
      in: CGRect(x: 0, y: 0, width: 96, height: 96),
      padding: 0
    ))
    XCTAssertEqual(hitRect, CGRect(x: 24, y: 24, width: 48, height: 48))
  }

  func testThemeAssetGeometryAppKitEyeOffsetMirrorsCSSFallbackDirection() {
    let offset = ThemeAssetGeometry.appKitFallbackEyeOffset(dx: 3, dy: -2)
    XCTAssertEqual(offset.width, 0.75, accuracy: 0.001)
    XCTAssertEqual(offset.height, 0.5, accuracy: 0.001)

    let invalid = ThemeAssetGeometry.appKitFallbackEyeOffset(dx: .nan, dy: .infinity, scale: .nan)
    XCTAssertEqual(invalid, .zero)
  }

  func testTerminalFocusAppleScriptContainsPid() {
    XCTAssertTrue(TerminalFocusManager.appleScript(pid: 1234).contains("unix id is 1234"))
  }

  func testTelegramApprovalTextContainsPermissionSummary() {
    let text = TelegramApprovalRuntime.approvalText(permission: PermissionRequest(agentId: "codex", sessionId: "s1", toolName: "Bash", toolInput: .object(["command": .string("ls")])))
    XCTAssertTrue(text.contains("codex"))
    XCTAssertTrue(text.contains("Bash"))
    XCTAssertTrue(text.contains("s1"))
  }

  func testTelegramCallbackRoundTripsPermissionDecision() throws {
    let id = UUID()
    let data = TelegramApprovalRuntime.callbackData(permissionId: id, action: .deny)
    let parsed = try XCTUnwrap(TelegramApprovalRuntime.parseCallbackData(data))
    XCTAssertEqual(parsed.permissionId, id)
    XCTAssertEqual(parsed.action, .deny)
    XCTAssertEqual(parsed.action.decision, .deny(message: "Denied from Telegram"))
  }

  func testTelegramSendMessagePayloadIncludesInlineKeyboard() throws {
    let id = UUID()
    let payload = TelegramApprovalRuntime.sendMessagePayload(
      permissionId: id,
      permission: PermissionRequest(agentId: "claude-code", sessionId: "s", toolName: "Edit"),
      config: TelegramApprovalConfig(enabled: true, chatId: "123")
    )
    XCTAssertEqual(payload["chat_id"] as? String, "123")
    let markup = try XCTUnwrap(payload["reply_markup"] as? [String: Any])
    let keyboard = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
    XCTAssertEqual(keyboard.first?.count, 3)
  }

  func testMobilePreviewEscapesSessionTitle() {
    let snapshot = StateSnapshot(currentState: .notification, sessions: [
      AgentSession(
        id: "s1",
        state: .notification,
        event: nil,
        updatedAt: Date(),
        startedAt: Date(),
        metadata: SessionMetadata(agentId: "codex", sessionTitle: "<script>")
      )
    ], updatedAt: Date())
    let html = MobilePreviewRuntime.html(snapshot: snapshot, preferences: Preferences())
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertFalse(html.contains("<script>"))
  }

  func testPreferencesDecodeNewSchemaWithDefaultsAndRuntimeAutoApprove() throws {
    let data = Data(#"{"theme":"calico","autoApproveAllPermissions":true}"#.utf8)
    let prefs = try JSONDecoder().decode(Preferences.self, from: data).validated()
    XCTAssertEqual(prefs.theme, "calico")
    XCTAssertFalse(prefs.autoApproveAllPermissions)
    XCTAssertEqual(prefs.shortcuts["togglePet"], "CommandOrControl+Shift+Alt+C")
    XCTAssertEqual(prefs.hardwareBuddy.namePrefix, "Clawstick")
    XCTAssertEqual(prefs.notificationBubbleAutoCloseSeconds, 6)

    let encoded = try JSONEncoder().encode(Preferences(autoApproveAllPermissions: true))
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    XCTAssertNil(json?["autoApproveAllPermissions"])
  }

  func testPreferencesClampNumericRuntimeSettings() {
    let prefs = Preferences(
      notificationBubbleAutoCloseSeconds: -10,
      permissionBubbleAutoCloseSeconds: 999,
      updateBubbleAutoCloseSeconds: 999,
      soundVolume: 3,
      flashIntervalMs: 50,
      flashDurationMs: 100_000
    ).validated()
    XCTAssertEqual(prefs.notificationBubbleAutoCloseSeconds, 0)
    XCTAssertEqual(prefs.permissionBubbleAutoCloseSeconds, 600)
    XCTAssertEqual(prefs.updateBubbleAutoCloseSeconds, 600)
    XCTAssertEqual(prefs.soundVolume, 1)
    XCTAssertEqual(prefs.flashIntervalMs, 200)
    XCTAssertEqual(prefs.flashDurationMs, 60_000)
  }

  func testPassiveNotificationPayloadRoundTrips() throws {
    let createdAt = Date(timeIntervalSince1970: 1_234)
    let request = PassiveNotificationRequest(
      kind: .codexPermission,
      agentId: "codex",
      sessionId: "codex:s1",
      title: "Codex Permission",
      message: "Review Bash in the Codex terminal.",
      detail: "npm test",
      createdAt: createdAt
    )
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(PassiveNotificationRequest.self, from: data)
    XCTAssertEqual(decoded, request)
  }

  func testShortcutDiagnosticsDetectsConflictsAndInvalidAccelerators() {
    let diagnostics = ShortcutDiagnostics.validate([
      "togglePet": "CommandOrControl+Shift+C",
      "permissionAllow": "CommandOrControl+Shift+C",
      "permissionDeny": "NoModifier"
    ])
    XCTAssertTrue(diagnostics.contains { $0.id == "shortcut-conflict:permissionAllow" && $0.status == "warning" })
    XCTAssertTrue(diagnostics.contains { $0.id == "shortcut:permissionDeny" && $0.status == "warning" })
  }

  private func startServer(_ server: LocalHTTPServer, ports: [Int]) throws -> Int {
    do {
      return try server.start(ports: ports)
    } catch {
      XCTFail("expected a free local port for server smoke test: \(error)")
      throw error
    }
  }

  private func tcpHTTPExchange(port: Int, parts: [Data]) throws -> Data {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    for (index, part) in parts.enumerated() {
      try writeAll(part, to: fd)
      if index < parts.count - 1 {
        Thread.sleep(forTimeInterval: 0.05)
      }
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count > 0 {
        response.append(buffer, count: count)
        if let expectedLength = httpResponseLength(response), response.count >= expectedLength {
          break
        }
      } else if count == 0 {
        break
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        if response.isEmpty {
          throw POSIXError(.ETIMEDOUT)
        }
        break
      } else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    return response
  }

  private func httpRequest(method: String, path: String, port: Int, body: String) -> Data {
    Data([
      "\(method) \(path) HTTP/1.1",
      "Host: 127.0.0.1:\(port)",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "Connection: close",
      "",
      body
    ].joined(separator: "\r\n").utf8)
  }

  private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
        if written > 0 {
          offset += written
        } else if errno == EINTR {
          continue
        } else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }
  }

  private func httpBody(_ response: Data) -> Data {
    let separator = Data([13, 10, 13, 10])
    guard let range = response.range(of: separator) else { return Data() }
    return response.subdata(in: range.upperBound..<response.endIndex)
  }

  private func httpResponseLength(_ response: Data) -> Int? {
    let separator = Data([13, 10, 13, 10])
    guard let range = response.range(of: separator),
          let header = String(data: response.subdata(in: response.startIndex..<range.lowerBound), encoding: .utf8)
    else { return nil }
    for line in header.components(separatedBy: "\r\n").dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].lowercased()
      if key == "content-length" {
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return range.upperBound + (Int(value) ?? 0)
      }
    }
    return nil
  }

  private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
