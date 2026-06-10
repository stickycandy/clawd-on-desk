import Foundation

public enum MobilePreviewRuntime {
  public static func html(snapshot: StateSnapshot, preferences: Preferences) -> String {
    let rows = snapshot.sessions.map { session in
      """
      <tr>
        <td>\(escape(session.metadata.agentId))</td>
        <td>\(escape(session.state.rawValue))</td>
        <td>\(escape(session.badge))</td>
        <td>\(escape(session.metadata.sessionTitle ?? session.id))</td>
      </tr>
      """
    }.joined(separator: "\n")

    return """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Clawd Native Preview</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 18px; color: #182026; background: #f7f8f4; }
        h1 { font-size: 20px; margin: 0 0 12px; }
        .state { display: inline-block; padding: 6px 10px; border-radius: 8px; background: #263238; color: white; margin-bottom: 14px; }
        table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; }
        td, th { padding: 8px; border-bottom: 1px solid #e2e4df; text-align: left; font-size: 13px; }
      </style>
    </head>
    <body>
      <h1>Clawd Native</h1>
      <div class="state">\(escape(snapshot.currentState.rawValue)) / theme \(escape(preferences.theme))</div>
      <table>
        <thead><tr><th>Agent</th><th>State</th><th>Badge</th><th>Session</th></tr></thead>
        <tbody>\(rows)</tbody>
      </table>
    </body>
    </html>
    """
  }

  private static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
