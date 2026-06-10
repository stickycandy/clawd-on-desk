import Foundation

public struct RemoteSSHStatus: Codable, Equatable, Sendable {
  public var profileId: String
  public var state: String
  public var message: String
  public var localPort: Int?
  public var hint: String?

  public init(profileId: String, state: String, message: String, localPort: Int? = nil, hint: String? = nil) {
    self.profileId = profileId
    self.state = state
    self.message = message
    self.localPort = localPort
    self.hint = hint
  }
}

public struct RemoteSSHCommandResult: Codable, Equatable, Sendable {
  public var code: Int32
  public var stdout: String
  public var stderr: String

  public var ok: Bool { code == 0 }

  public init(code: Int32, stdout: String = "", stderr: String = "") {
    self.code = code
    self.stdout = stdout
    self.stderr = stderr
  }
}

public struct RemoteSSHNodeProbeResult: Codable, Equatable, Sendable {
  public var nodeBin: String
  public var version: String
  public var source: String

  public init(nodeBin: String, version: String, source: String) {
    self.nodeBin = nodeBin
    self.version = version
    self.source = source
  }
}

public struct RemoteSSHDeployResult: Codable, Equatable, Sendable {
  public var ok: Bool
  public var step: String
  public var message: String
  public var remoteNode: RemoteSSHNodeProbeResult?
  public var warnings: [String]

  public init(ok: Bool, step: String, message: String, remoteNode: RemoteSSHNodeProbeResult? = nil, warnings: [String] = []) {
    self.ok = ok
    self.step = step
    self.message = message
    self.remoteNode = remoteNode
    self.warnings = warnings
  }
}

public enum RemoteSSHClassifier {
  public static func classifyStderr(_ stderr: String) -> (kind: String, reason: String, hint: String?) {
    if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ("unknown", "unknown", nil)
    }
    if stderr.range(of: "Permission denied", options: .caseInsensitive) != nil {
      return ("permanent", "auth_denied", "remoteSshErrAuthDenied")
    }
    if stderr.range(of: "Host key verification failed", options: .caseInsensitive) != nil {
      return ("permanent", "host_key", "remoteSshErrHostKey")
    }
    if stderr.range(of: "remote port forwarding failed", options: .caseInsensitive) != nil {
      return ("permanent", "forward_failed", "remoteSshErrForwardFailed")
    }
    if stderr.range(of: "Bad configuration option", options: .caseInsensitive) != nil {
      return ("permanent", "bad_config", "remoteSshErrBadConfig")
    }
    if stderr.range(of: "no such identity", options: .caseInsensitive) != nil ||
      stderr.range(of: "cannot read identity", options: .caseInsensitive) != nil ||
      stderr.range(of: "Identity file", options: .caseInsensitive) != nil {
      return ("permanent", "identity_missing", "remoteSshErrIdentityMissing")
    }
    if stderr.range(of: "Could not resolve hostname", options: .caseInsensitive) != nil {
      return ("permanent", "dns", "remoteSshErrDns")
    }
    if stderr.range(of: "Connection timed out", options: .caseInsensitive) != nil ||
      stderr.range(of: "Connection refused", options: .caseInsensitive) != nil ||
      stderr.range(of: "Connection reset", options: .caseInsensitive) != nil {
      return ("transient", "net_timeout", "remoteSshErrNetTimeout")
    }
    if stderr.range(of: "Network is unreachable", options: .caseInsensitive) != nil {
      return ("transient", "net_unreachable", "remoteSshErrNetUnreachable")
    }
    if stderr.range(of: "Operation timed out", options: .caseInsensitive) != nil {
      return ("transient", "op_timeout", "remoteSshErrNetTimeout")
    }
    if stderr.range(of: "Broken pipe", options: .caseInsensitive) != nil {
      return ("transient", "broken_pipe", "remoteSshErrBrokenPipe")
    }
    return ("unknown", "unknown", nil)
  }

  public static func classifyProbeExit(_ code: Int32) -> (kind: String, reason: String, hint: String?) {
    switch code {
    case 0:
      return ("ok", "ok", nil)
    case 1:
      return ("permanent", "probe_local_unhealthy", "remoteSshProbeLocalUnhealthy")
    case 2:
      return ("permanent", "probe_unresponsive", "remoteSshProbeUnresponsive")
    case 3:
      return ("permanent", "probe_port_hijack", "remoteSshProbePortHijack")
    case 4:
      return ("transient", "probe_http_timeout", "remoteSshProbeHttpTimeout")
    case 126:
      return ("permanent", "probe_node_not_exec", "remoteSshProbeNodeNotExec")
    case 127:
      return ("permanent", "probe_node_missing", "remoteSshProbeNodeMissing")
    case 130, 137, 143, 255:
      return ("transient", "probe_signal", "remoteSshProbeSignal")
    default:
      return ("transient", "probe_unknown", "remoteSshProbeSignal")
    }
  }
}

public enum RemoteSSHShellQuote {
  public static func posix(_ value: String) -> String {
    if value.isEmpty { return "''" }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public final class RemoteSSHRuntime: @unchecked Sendable {
  public static let hookFiles = [
    "server-config.js",
    "json-utils.js",
    "shared-process.js",
    "context-usage.js",
    "clawd-hook.js",
    "install.js",
    "codex-hook.js",
    "codex-assistant-output.js",
    "codex-install.js",
    "codex-install-utils.js",
    "codex-remote-monitor.js",
    "codex-session-index.js",
    "codex-subagent-fields.js",
    "copilot-hook.js",
    "copilot-install.js"
  ]

  private let lock = NSLock()
  private var processes: [String: Process] = [:]
  private var stoppedProfileIds = Set<String>()
  private var statuses: [String: RemoteSSHStatus] = [:]
  private var statusCallbacks: [UUID: @Sendable (RemoteSSHStatus) -> Void] = [:]

  public init() {}

  public func onStatusChange(_ callback: @escaping @Sendable (RemoteSSHStatus) -> Void) -> UUID {
    let id = UUID()
    lock.lock()
    statusCallbacks[id] = callback
    lock.unlock()
    return id
  }

  public func removeStatusObserver(_ id: UUID) {
    lock.lock()
    statusCallbacks.removeValue(forKey: id)
    lock.unlock()
  }

  public func listStatuses() -> [RemoteSSHStatus] {
    lock.lock()
    defer { lock.unlock() }
    return Array(statuses.values)
  }

  public func status(profileId: String) -> RemoteSSHStatus {
    lock.lock()
    defer { lock.unlock() }
    return statuses[profileId] ?? RemoteSSHStatus(profileId: profileId, state: "idle", message: "Not connected")
  }

  public static func buildSshArgs(profile: RemoteSSHProfile, extraOpts: [String] = [], interactive: Bool = false) -> [String] {
    var args = interactive ? [] : ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    if let identityFile = profile.identityFile, !identityFile.isEmpty {
      args.append(contentsOf: ["-i", identityFile])
    }
    if profile.effectivePort != 22 {
      args.append(contentsOf: ["-p", String(profile.effectivePort)])
    }
    args.append(contentsOf: extraOpts)
    args.append(profile.effectiveHost)
    return args
  }

  public static func buildScpArgs(profile: RemoteSSHProfile, extraOpts: [String] = []) -> [String] {
    var args = ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
    if let identityFile = profile.identityFile, !identityFile.isEmpty {
      args.append(contentsOf: ["-i", identityFile])
    }
    if profile.effectivePort != 22 {
      args.append(contentsOf: ["-P", String(profile.effectivePort)])
    }
    args.append(contentsOf: extraOpts)
    return args
  }

  public static func tunnelCommand(profile: RemoteSSHProfile, localPort: Int) -> [String] {
    ["ssh"] + buildSshArgs(
      profile: profile,
      extraOpts: [
        "-N",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-R", "127.0.0.1:\(profile.remoteForwardPort):127.0.0.1:\(localPort)"
      ]
    )
  }

  public static func deployCommand(profile: RemoteSSHProfile) -> [String] {
    ["bash", "scripts/remote-deploy.sh", profile.effectiveHost]
  }

  public static func buildProbeCommand(remoteForwardPort: Int, nodeBin: String = "node") -> String {
    let url = "http://127.0.0.1:\(remoteForwardPort)/state"
    let js = """
    const r=require('http').get(\(json(url)),res=>{const m=res.headers['x-clawd-server']==='clawd-on-desk-native'||res.headers['x-clawd-server']==='clawd-on-desk';if(!m)process.exit(3);process.exit(res.statusCode===200?0:1);});r.on('error',()=>process.exit(2));r.setTimeout(2000,()=>{r.destroy();process.exit(4);});
    """
    if nodeBin == "node" {
      return "node -e \(json(js))"
    }
    return "\(RemoteSSHShellQuote.posix(nodeBin)) -e \(RemoteSSHShellQuote.posix(js))"
  }

  public static func buildRemoteNodeProbeCommand(nodeBin: String? = nil, source: String = "cache") -> String {
    let script = """
    node_version_supported(){ v="$1"; major="${v#v}"; major="${major%%.*}"; case "$major" in ''|*[!0-9]*) return 1 ;; esac; [ "$major" -ge 14 ]; }
    emit_node(){ p="$1"; src="$2"; [ -z "$p" ] && return 1; case "$p" in /*) ;; *) return 1 ;; esac; [ ! -x "$p" ] && return 1; v="$("$p" --version 2>/dev/null)" || return 1; node_version_supported "$v" || return 1; printf 'CLAWD_REMOTE_NODE_BIN=%s\\n' "$p"; printf 'CLAWD_REMOTE_NODE_VERSION=%s\\n' "$v"; printf 'CLAWD_REMOTE_NODE_SOURCE=%s\\n' "$src"; exit 0; }
    if [ "$#" -gt 0 ]; then emit_node "$1" "${2:-cache}"; exit 127; fi
    p="$(command -v node 2>/dev/null || true)"; emit_node "$p" "path"
    for p in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node "$HOME"/.volta/bin/node "$HOME"/.local/bin/node "$HOME"/.nvm/current/bin/node "$HOME"/.nvm/versions/node/*/bin/node "$HOME"/.fnm/node-versions/*/installation/bin/node "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node "$HOME"/.asdf/installs/nodejs/*/bin/node "$HOME"/.asdf/shims/node "$HOME"/.mise/shims/node "$HOME"/.local/share/mise/shims/node; do emit_node "$p" "candidate"; done
    exit 127
    """
    var command = "sh -c \(RemoteSSHShellQuote.posix(script))"
    if let nodeBin, RemoteSSHProfileValidator.isValidRemoteNodeBin(nodeBin) {
      command += " -- \(RemoteSSHShellQuote.posix(nodeBin)) \(RemoteSSHShellQuote.posix(source))"
    }
    return command
  }

  public static func parseRemoteNodeProbeOutput(_ stdout: String) -> RemoteSSHNodeProbeResult? {
    var bin: String?
    var version: String?
    var source: String?
    for line in stdout.split(whereSeparator: \.isNewline).map(String.init) {
      if line.hasPrefix("CLAWD_REMOTE_NODE_BIN=") {
        bin = String(line.dropFirst("CLAWD_REMOTE_NODE_BIN=".count))
      } else if line.hasPrefix("CLAWD_REMOTE_NODE_VERSION=") {
        version = String(line.dropFirst("CLAWD_REMOTE_NODE_VERSION=".count))
      } else if line.hasPrefix("CLAWD_REMOTE_NODE_SOURCE=") {
        source = String(line.dropFirst("CLAWD_REMOTE_NODE_SOURCE=".count))
      }
    }
    guard let bin, let version, let source,
          RemoteSSHProfileValidator.isValidRemoteNodeBin(bin),
          RemoteSSHProfileValidator.isSupportedRemoteNodeVersion(version)
    else { return nil }
    return RemoteSSHNodeProbeResult(nodeBin: bin, version: version, source: source)
  }

  @discardableResult
  public func connect(profile: RemoteSSHProfile, localPort: Int) -> RemoteSSHStatus {
    guard case .success = RemoteSSHProfileValidator.validate(profile) else {
      let status = RemoteSSHStatus(profileId: profile.id, state: "error", message: "Invalid Remote SSH profile")
      setStatus(status)
      return status
    }
    lock.lock()
    if processes[profile.id]?.isRunning == true {
      let existing = statuses[profile.id] ?? RemoteSSHStatus(profileId: profile.id, state: "running", message: "Tunnel already running", localPort: localPort)
      lock.unlock()
      return existing
    }
    stoppedProfileIds.remove(profile.id)
    lock.unlock()

    let command = Self.tunnelCommand(profile: profile, localPort: localPort)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.standardOutput = Pipe()
    let stderr = Pipe()
    process.standardError = stderr
    process.terminationHandler = { [weak self, weak process] terminated in
      guard let self, let process, process === terminated else { return }
      self.handleTunnelExit(profileId: profile.id, localPort: localPort, process: process, stderr: stderr)
    }
    do {
      setStatus(RemoteSSHStatus(profileId: profile.id, state: "connecting", message: command.joined(separator: " "), localPort: localPort))
      try process.run()
      lock.lock()
      processes[profile.id] = process
      lock.unlock()
      setStatus(RemoteSSHStatus(profileId: profile.id, state: "running", message: "Tunnel running", localPort: localPort))
      return status(profileId: profile.id)
    } catch {
      let status = RemoteSSHStatus(profileId: profile.id, state: "error", message: error.localizedDescription, localPort: localPort)
      setStatus(status)
      return status
    }
  }

  @discardableResult
  public func startTunnel(profile: RemoteSSHProfile, localPort: Int) -> RemoteSSHStatus {
    connect(profile: profile, localPort: localPort)
  }

  public func disconnect(profileId: String) -> RemoteSSHStatus {
    lock.lock()
    let process = processes.removeValue(forKey: profileId)
    stoppedProfileIds.insert(profileId)
    lock.unlock()
    if let process, process.isRunning {
      process.terminate()
    }
    let status = RemoteSSHStatus(profileId: profileId, state: "stopped", message: "Tunnel stopped")
    setStatus(status)
    return status
  }

  public func stopTunnel(profileId: String) -> RemoteSSHStatus {
    disconnect(profileId: profileId)
  }

  public func probe(profile: RemoteSSHProfile, nodeBin: String? = nil) -> RemoteSSHStatus {
    let command = Self.buildProbeCommand(remoteForwardPort: profile.remoteForwardPort, nodeBin: nodeBin ?? profile.detectedRemoteNodeBin ?? "node")
    let result = run("ssh", Self.buildSshArgs(profile: profile) + [command], timeout: 8)
    let classified = RemoteSSHClassifier.classifyProbeExit(result.code)
    let status: RemoteSSHStatus
    if classified.kind == "ok" {
      status = RemoteSSHStatus(profileId: profile.id, state: "healthy", message: "Remote tunnel probe succeeded")
    } else {
      status = RemoteSSHStatus(
        profileId: profile.id,
        state: classified.kind == "permanent" ? "error" : "warning",
        message: result.stderr.isEmpty ? "Probe failed: \(classified.reason)" : result.stderr,
        hint: classified.hint
      )
    }
    setStatus(status)
    return status
  }

  public func resolveRemoteNode(profile: RemoteSSHProfile, verifyCached: Bool = false) -> RemoteSSHNodeProbeResult? {
    if !verifyCached,
       let bin = profile.detectedRemoteNodeBin,
       let version = profile.detectedRemoteNodeVersion,
       RemoteSSHProfileValidator.isValidRemoteNodeBin(bin),
       RemoteSSHProfileValidator.isSupportedRemoteNodeVersion(version) {
      return RemoteSSHNodeProbeResult(nodeBin: bin, version: version, source: profile.detectedRemoteNodeSource ?? "profile")
    }
    if verifyCached,
       let bin = profile.detectedRemoteNodeBin,
       let version = profile.detectedRemoteNodeVersion,
       RemoteSSHProfileValidator.isValidRemoteNodeBin(bin),
       RemoteSSHProfileValidator.isSupportedRemoteNodeVersion(version) {
      let command = Self.buildRemoteNodeProbeCommand(nodeBin: bin, source: profile.detectedRemoteNodeSource ?? "profile")
      let result = run("ssh", Self.buildSshArgs(profile: profile) + [command], timeout: 60)
      if result.ok, let parsed = Self.parseRemoteNodeProbeOutput(result.stdout) {
        return parsed
      }
    }
    let command = Self.buildRemoteNodeProbeCommand()
    let result = run("ssh", Self.buildSshArgs(profile: profile) + [command], timeout: 60)
    guard result.ok, let parsed = Self.parseRemoteNodeProbeOutput(result.stdout) else { return nil }
    return parsed
  }

  public func deploy(profile: RemoteSSHProfile, projectRoot: URL) -> RemoteSSHDeployResult {
    let hooksDir = projectRoot.appendingPathComponent("hooks", isDirectory: true)
    let missing = Self.hookFiles
      .map { hooksDir.appendingPathComponent($0) }
      .filter { !FileManager.default.fileExists(atPath: $0.path) }
    guard missing.isEmpty else {
      return RemoteSSHDeployResult(ok: false, step: "verify", message: "Missing hook files: \(missing.map(\.lastPathComponent).joined(separator: ", "))")
    }

    let mkdir = run("ssh", Self.buildSshArgs(profile: profile) + ["mkdir -p ~/.claude/hooks"])
    guard mkdir.ok else { return failedDeploy("mkdir", mkdir) }

    guard let node = resolveRemoteNode(profile: profile, verifyCached: true) else {
      return RemoteSSHDeployResult(ok: false, step: "check-node", message: "Remote Node.js v14+ not found")
    }

    let localFiles = Self.hookFiles.map { hooksDir.appendingPathComponent($0).path }
    let scpArgs = Self.buildScpArgs(profile: profile) + localFiles + ["\(profile.effectiveHost):~/.claude/hooks/"]
    let scp = run("scp", scpArgs, timeout: 120)
    guard scp.ok else { return failedDeploy("scp", scp) }

    if let hostPrefix = profile.hostPrefix, !hostPrefix.isEmpty {
      let result = run("ssh", Self.buildSshArgs(profile: profile) + ["cat > ~/.claude/hooks/clawd-host-prefix"], stdin: hostPrefix)
      guard result.ok else { return failedDeploy("host-prefix", result) }
    }

    var warnings: [String] = []
    for (step, script) in [
      ("install-claude", "install.js"),
      ("install-codex", "codex-install.js"),
      ("install-copilot", "copilot-install.js")
    ] {
      let result = run("ssh", Self.buildSshArgs(profile: profile) + [buildRemoteHookNodeCommand(nodeBin: node.nodeBin, script: script, args: ["--remote"])])
      if !result.ok {
        warnings.append("\(step): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
      }
    }
    return RemoteSSHDeployResult(ok: true, step: "done", message: "Remote hooks deployed", remoteNode: node, warnings: warnings)
  }

  public func startCodexMonitor(profile: RemoteSSHProfile) -> RemoteSSHCommandResult {
    guard let node = resolveRemoteNode(profile: profile, verifyCached: true) else {
      return RemoteSSHCommandResult(code: 127, stderr: "Remote Node.js v14+ not found")
    }
    let cleanCommand = "[ -f ~/.clawd-codex-monitor.pid ] && kill $(cat ~/.clawd-codex-monitor.pid) 2>/dev/null; rm -f ~/.clawd-codex-monitor.pid; true"
    _ = run("ssh", Self.buildSshArgs(profile: profile) + [cleanCommand], timeout: 20)
    let monitorCommand = buildRemoteHookNodeCommand(
      nodeBin: node.nodeBin,
      script: "codex-remote-monitor.js",
      args: ["--port", String(profile.remoteForwardPort)]
    )
    let startCommand = "nohup \(monitorCommand) > /dev/null 2>&1 & echo $! > ~/.clawd-codex-monitor.pid"
    return run("ssh", Self.buildSshArgs(profile: profile) + [startCommand], timeout: 20)
  }

  public func stopCodexMonitor(profile: RemoteSSHProfile) -> RemoteSSHCommandResult {
    let command = "[ -f ~/.clawd-codex-monitor.pid ] && kill $(cat ~/.clawd-codex-monitor.pid) 2>/dev/null; rm -f ~/.clawd-codex-monitor.pid"
    return run("ssh", Self.buildSshArgs(profile: profile) + [command], timeout: 20)
  }

  public func openInteractiveTerminalCommand(profile: RemoteSSHProfile) -> String {
    (["ssh"] + Self.buildSshArgs(profile: profile, extraOpts: ["-o", "BatchMode=no"], interactive: true))
      .map(RemoteSSHShellQuote.posix)
      .joined(separator: " ")
  }

  public func stopAll() {
    lock.lock()
    let running = processes
    processes.removeAll()
    lock.unlock()
    for process in running.values where process.isRunning {
      process.terminate()
    }
  }

  private func buildRemoteHookNodeCommand(nodeBin: String, script: String, args: [String]) -> String {
    let safeScript = script.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) == nil ? "install.js" : script
    let executable = RemoteSSHShellQuote.posix(nodeBin)
    let hookPath = "\"$HOME/.claude/hooks/\(safeScript)\""
    let tail = args.map(RemoteSSHShellQuote.posix).joined(separator: " ")
    return ([executable, hookPath, tail].filter { !$0.isEmpty }).joined(separator: " ")
  }

  private func failedDeploy(_ step: String, _ result: RemoteSSHCommandResult) -> RemoteSSHDeployResult {
    RemoteSSHDeployResult(ok: false, step: step, message: result.stderr.isEmpty ? result.stdout : result.stderr)
  }

  private func setStatus(_ status: RemoteSSHStatus) {
    let callbacks: [@Sendable (RemoteSSHStatus) -> Void]
    lock.lock()
    statuses[status.profileId] = status
    callbacks = Array(statusCallbacks.values)
    lock.unlock()
    callbacks.forEach { $0(status) }
  }

  private func handleTunnelExit(profileId: String, localPort: Int, process: Process, stderr: Pipe) {
    lock.lock()
    let current = processes[profileId]
    let stale = current !== process
    if !stale {
      processes.removeValue(forKey: profileId)
    }
    let wasStopped = stoppedProfileIds.remove(profileId) != nil
    lock.unlock()
    if stale || wasStopped {
      return
    }
    let stderrText = read(stderr)
    let classified = RemoteSSHClassifier.classifyStderr(stderrText)
    let message = stderrText.isEmpty ? "SSH tunnel exited" : stderrText
    let status = RemoteSSHStatus(
      profileId: profileId,
      state: classified.kind == "permanent" ? "error" : "warning",
      message: message,
      localPort: localPort,
      hint: classified.hint
    )
    setStatus(status)
  }

  private func run(_ command: String, _ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 60) -> RemoteSSHCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    if stdin != nil {
      process.standardInput = Pipe()
    }
    do {
      try process.run()
      if let stdin, let input = process.standardInput as? Pipe {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
      }
      let deadline = Date().addingTimeInterval(timeout)
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      if process.isRunning {
        process.terminate()
        return RemoteSSHCommandResult(code: -1, stdout: read(stdout), stderr: "Command timed out")
      }
      return RemoteSSHCommandResult(code: process.terminationStatus, stdout: read(stdout), stderr: read(stderr))
    } catch {
      return RemoteSSHCommandResult(code: -1, stderr: error.localizedDescription)
    }
  }

  private func read(_ pipe: Pipe) -> String {
    String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func json(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
    let array = String(decoding: data ?? Data("[\"\"]".utf8), as: UTF8.self)
    return String(array.dropFirst().dropLast())
  }
}
