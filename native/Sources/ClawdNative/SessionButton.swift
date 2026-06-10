import AppKit
import ClawdNativeCore

@MainActor
final class SessionButton: NSButton {
  var session: AgentSession?
}
