import Foundation
import ClawdNativeCore

@main
struct ClawdNativeHookMain {
  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { exit(0) }
    let agentId = args[0]
    let event = args[1]
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let runtime = NativeHookRuntime(agentId: agentId, event: event)

    switch runtime.route(stdin: input) {
    case .none:
      exit(0)
    case .state(let body):
      post(path: "/state", body: body, timeout: 0.2) { _ in }
      exit(0)
    case .permission(let body):
      let response = post(path: "/permission", body: body, timeout: permissionTimeout(agentId: agentId))
      if let response, !response.isEmpty {
        FileHandle.standardOutput.write(response)
        FileHandle.standardOutput.write(Data("\n".utf8))
      } else if agentId == "codex" || agentId == "qwen-code" {
        FileHandle.standardOutput.write(Data("{}\n".utf8))
      }
      exit(0)
    }
  }

  private static func permissionTimeout(agentId: String) -> TimeInterval {
    switch agentId {
    case "copilot-cli":
      return 540
    case "codex", "qwen-code":
      return 590
    default:
      return 600
    }
  }

  @discardableResult
  private static func post(path: String, body: JSONValue, timeout: TimeInterval, completion: ((Data?) -> Void)? = nil) -> Data? {
    let payload = NativeHookRuntime.encode(body)
    let ports = candidatePorts()
    for port in ports {
      guard let response = post(port: port, path: path, payload: payload, timeout: timeout) else { continue }
      completion?(response)
      return response
    }
    completion?(nil)
    return nil
  }

  private static func post(port: Int, path: String, payload: Data, timeout: TimeInterval) -> Data? {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload
    let semaphore = DispatchSemaphore(value: 0)
    let output = ResponseBox()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: config)
    let task = session.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
      output.set(data)
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 0.5)
    session.invalidateAndCancel()
    return output.get()
  }

  private static func candidatePorts() -> [Int] {
    var ports: [Int] = []
    if let runtimePort = NativeHookRuntime.runtimePort() {
      ports.append(runtimePort)
    }
    for port in 23333...23337 where !ports.contains(port) {
      ports.append(port)
    }
    return ports
  }
}

private final class ResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?

  func set(_ data: Data?) {
    lock.lock()
    self.data = data
    lock.unlock()
  }

  func get() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
