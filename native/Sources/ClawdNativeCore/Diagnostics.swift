import Foundation

public struct DiagnosticItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var status: String
  public var message: String

  public init(id: String, status: String, message: String) {
    self.id = id
    self.status = status
    self.message = message
  }
}

public enum Diagnostics {
  public static func localReport(
    serverPort: Int?,
    preferencesURL: URL,
    projectRoot: URL,
    remoteSSHStatuses: [RemoteSSHStatus] = []
  ) -> [DiagnosticItem] {
    var items: [DiagnosticItem] = []
    if let serverPort {
      items.append(.init(id: "local-server", status: "ok", message: "Listening on 127.0.0.1:\(serverPort)"))
    } else {
      items.append(.init(id: "local-server", status: "error", message: "Local hook server is not running"))
    }
    items.append(.init(
      id: "preferences",
      status: FileManager.default.fileExists(atPath: preferencesURL.path) ? "ok" : "warning",
      message: preferencesURL.path
    ))
    let themes = projectRoot.appendingPathComponent("themes", isDirectory: true)
    items.append(.init(
      id: "themes",
      status: FileManager.default.fileExists(atPath: themes.path) ? "ok" : "warning",
      message: themes.path
    ))
    if remoteSSHStatuses.isEmpty {
      items.append(.init(id: "remote-ssh", status: "idle", message: "No active Remote SSH tunnel"))
    } else {
      for status in remoteSSHStatuses {
        items.append(.init(
          id: "remote-ssh:\(status.profileId)",
          status: status.state,
          message: status.message
        ))
      }
    }
    return items
  }
}
