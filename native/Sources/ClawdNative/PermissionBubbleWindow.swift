import AppKit
import ClawdNativeCore

@MainActor
final class PermissionBubbleWindowController: NSWindowController, NSWindowDelegate {
  private static let bubbleWidth: CGFloat = 360
  private static let contentWidth: CGFloat = 336
  private var permission: PendingPermission?
  private let lang: String
  private var resolved = false
  private var autoCloseTimer: Timer?
  private static var visible: [PermissionBubbleWindowController] = []
  private static var lastPreferences: Preferences?
  private static weak var lastPetWindow: NSWindow?

  static func show(_ permission: PendingPermission, preferences: Preferences, petWindow: NSWindow?) {
    guard preferences.permissionBubblesEnabled, !preferences.hideBubbles else {
      permission.resolve(.noDecision)
      return
    }
    let controller = PermissionBubbleWindowController(permission: permission, preferences: preferences)
    visible.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    controller.armAutoClose(preferences: preferences)
    reposition(preferences: preferences, petWindow: petWindow)
  }

  static func applyPreferences(_ preferences: Preferences, petWindow: NSWindow?) {
    if !preferences.permissionBubblesEnabled || preferences.hideBubbles {
      dismissAllWithoutDecision()
      return
    }
    for controller in visible {
      controller.armAutoClose(preferences: preferences)
    }
    reposition(preferences: preferences, petWindow: petWindow)
  }

  static func reposition(preferences: Preferences, petWindow: NSWindow?) {
    lastPreferences = preferences
    lastPetWindow = petWindow
    FloatingBubbleStackCoordinator.reposition(preferences: preferences, petWindow: petWindow)
  }

  static func stackEntries() -> [FloatingBubbleStackEntry] {
    visible.map { controller in
      FloatingBubbleStackEntry(
        createdAt: controller.permission?.createdAt ?? Date.distantPast,
        height: controller.window?.frame.height ?? controller.estimatedHeight,
        setFrame: { frame in
          controller.window?.setFrame(frame, display: true)
        }
      )
    }
  }

  static func dismissAllWithoutDecision() {
    let controllers = visible
    for controller in controllers {
      controller.resolved = true
      controller.permission?.resolve(.noDecision)
      controller.close()
    }
  }

  static func dismiss(agentId: String) {
    let controllers = visible.filter { $0.permission?.request.agentId == agentId }
    for controller in controllers {
      controller.resolved = true
      controller.permission?.resolve(.noDecision)
      controller.close()
    }
  }

  init(permission: PendingPermission, preferences: Preferences) {
    self.permission = permission
    self.lang = preferences.lang
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.bubbleWidth, height: Self.estimatedHeight(for: permission.request)),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.level = .floating
    window.title = ""
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.hidesOnDeactivate = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentView = buildView(permission)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func windowWillClose(_ notification: Notification) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    if !resolved {
      permission?.resolve(.noDecision)
    }
    Self.visible.removeAll { $0 === self }
    if let preferences = Self.lastPreferences {
      Self.reposition(preferences: preferences, petWindow: Self.lastPetWindow)
    }
  }

  @objc private func allow() {
    resolved = true
    permission?.resolve(.allow)
    close()
  }

  @objc private func deny() {
    resolved = true
    permission?.resolve(.deny(message: "Denied in Clawd Native"))
    close()
  }

  @objc private func noDecision() {
    resolved = true
    permission?.resolve(.noDecision)
    close()
  }

  private func buildView(_ permission: PendingPermission) -> NSView {
    let summary = PermissionDisplaySummary(request: permission.request, lang: lang)
    let visual = NSVisualEffectView()
    visual.material = .popover
    visual.blendingMode = .behindWindow
    visual.state = .active
    visual.wantsLayer = true
    visual.layer?.cornerRadius = 12
    visual.layer?.masksToBounds = true
    visual.layer?.borderWidth = 1
    visual.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

    let root = NSStackView()
    root.orientation = .vertical
    root.spacing = 8
    root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
    root.translatesAutoresizingMaskIntoConstraints = false
    visual.addSubview(root)
    NSLayoutConstraint.activate([
      visual.widthAnchor.constraint(equalToConstant: Self.bubbleWidth),
      root.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
      root.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
      root.topAnchor.constraint(equalTo: visual.topAnchor),
      root.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
    ])

    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 8

    header.addArrangedSubview(pill(summary.agentLabel, color: NSColor(calibratedRed: 0.16, green: 0.39, blue: 0.95, alpha: 1)))

    let titleBlock = NSStackView()
    titleBlock.orientation = .vertical
    titleBlock.alignment = .leading
    titleBlock.spacing = 2
    titleBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let title = textLabel(localized("permissionRequest"), size: 13, weight: .semibold, color: .labelColor, lines: 1)
    titleBlock.addArrangedSubview(title)

    let subtitle = textLabel(summary.subtitle, size: 11, weight: .regular, color: .secondaryLabelColor, lines: 1)
    subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 270).isActive = true
    titleBlock.addArrangedSubview(subtitle)
    header.addArrangedSubview(titleBlock)
    root.addArrangedSubview(header)

    if let description = summary.description {
      let descriptionLabel = textLabel(description, size: 11.5, weight: .regular, color: .labelColor, lines: 3)
      descriptionLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
      root.addArrangedSubview(descriptionLabel)
    }

    if let command = summary.command {
      root.addArrangedSubview(codeBlock(title: localized("command"), body: command, height: 46))
    } else {
      root.addArrangedSubview(codeBlock(title: localized("rawInput"), body: summary.rawInput, height: 58, subtle: true))
    }

    if !permission.request.suggestions.isEmpty {
      let suggestions = NSStackView()
      suggestions.orientation = .vertical
      suggestions.spacing = 5
      for suggestion in permission.request.suggestions {
        let button = SuggestionButton()
        button.title = PermissionSuggestionFormatter.label(for: suggestion)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.alignment = .left
        button.suggestion = suggestion
        button.target = self
        button.action = #selector(applySuggestion(_:))
        suggestions.addArrangedSubview(button)
      }
      root.addArrangedSubview(suggestions)
    }

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 6
    buttons.addArrangedSubview(NSView())
    let terminal = actionButton(localized("useTerminal"), action: #selector(noDecision), width: 92)
    let deny = actionButton(localized("deny"), action: #selector(deny), width: 58)
    let allow = actionButton(localized("allow"), action: #selector(allow), width: 58)
    allow.keyEquivalent = "\r"
    buttons.addArrangedSubview(terminal)
    buttons.addArrangedSubview(deny)
    buttons.addArrangedSubview(allow)
    root.addArrangedSubview(buttons)

    return visual
  }

  private var estimatedHeight: CGFloat {
    guard let permission else { return 190 }
    return Self.estimatedHeight(for: permission.request)
  }

  private static func estimatedHeight(for request: PermissionRequest) -> CGFloat {
    let summary = PermissionDisplaySummary(request: request, lang: "en")
    let descriptionHeight: CGFloat = summary.description == nil ? 0 : 34
    let inputHeight: CGFloat = summary.command == nil ? 66 : 54
    let suggestionsHeight = CGFloat(request.suggestions.count) * 30
    return min(320, max(182, 98 + descriptionHeight + inputHeight + suggestionsHeight))
  }

  private func textLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, lines: Int) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = lines
    return label
  }

  private func pill(_ text: String, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 9, weight: .bold)
    label.textColor = .white
    label.alignment = .center
    label.wantsLayer = true
    label.layer?.backgroundColor = color.cgColor
    label.layer?.cornerRadius = 4
    label.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    label.heightAnchor.constraint(equalToConstant: 19).isActive = true
    return label
  }

  private func actionButton(_ title: String, action: Selector, width: CGFloat) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    button.widthAnchor.constraint(equalToConstant: width).isActive = true
    return button
  }

  private func codeBlock(title: String, body: String, height: CGFloat, subtle: Bool = false) -> NSView {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.cornerRadius = 7
    box.borderWidth = 1
    box.borderColor = NSColor.separatorColor.withAlphaComponent(subtle ? 0.35 : 0.55)
    box.fillColor = subtle
      ? NSColor.textBackgroundColor.withAlphaComponent(0.10)
      : NSColor.controlBackgroundColor.withAlphaComponent(0.26)
    box.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    box.heightAnchor.constraint(equalToConstant: height).isActive = true

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
      stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
      stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6)
    ])

    let heading = NSTextField(labelWithString: title)
    heading.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
    heading.textColor = .tertiaryLabelColor
    stack.addArrangedSubview(heading)

    let input = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth - 18, height: height - 24))
    input.string = body
    input.isEditable = false
    input.isSelectable = true
    input.drawsBackground = false
    input.font = NSFont.monospacedSystemFont(ofSize: subtle ? 9.5 : 10.5, weight: .regular)
    input.textColor = subtle ? .tertiaryLabelColor : .labelColor
    input.textContainerInset = NSSize(width: 0, height: 0)
    input.textContainer?.lineFragmentPadding = 0

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.documentView = input
    scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth - 18).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: height - 24).isActive = true
    stack.addArrangedSubview(scroll)
    return box
  }

  private func localized(_ key: String) -> String {
    let table = Self.localizedStrings[lang] ?? Self.localizedStrings["en"] ?? [:]
    return table[key] ?? Self.localizedStrings["en"]?[key] ?? key
  }

  private static let localizedStrings: [String: [String: String]] = [
    "en": [
      "permissionRequest": "Permission request",
      "command": "Command",
      "rawInput": "Raw input",
      "useTerminal": "Use Terminal",
      "deny": "Deny",
      "allow": "Allow"
    ],
    "zh": [
      "permissionRequest": "权限请求",
      "command": "命令",
      "rawInput": "原始输入",
      "useTerminal": "终端处理",
      "deny": "拒绝",
      "allow": "允许"
    ],
    "zh-TW": [
      "permissionRequest": "權限請求",
      "command": "命令",
      "rawInput": "原始輸入",
      "useTerminal": "終端處理",
      "deny": "拒絕",
      "allow": "允許"
    ],
    "ko": [
      "permissionRequest": "권한 요청",
      "command": "명령",
      "rawInput": "원본 입력",
      "useTerminal": "터미널 사용",
      "deny": "거부",
      "allow": "허용"
    ],
    "ja": [
      "permissionRequest": "権限リクエスト",
      "command": "コマンド",
      "rawInput": "元の入力",
      "useTerminal": "端末で処理",
      "deny": "拒否",
      "allow": "許可"
    ]
  ]

  private func armAutoClose(preferences: Preferences) {
    autoCloseTimer?.invalidate()
    autoCloseTimer = nil
    let seconds = preferences.permissionBubbleAutoCloseSeconds
    guard seconds > 0, let permission else { return }
    let elapsed = Date().timeIntervalSince(permission.createdAt)
    let remaining = TimeInterval(seconds) - max(elapsed, 0)
    guard remaining > 0 else {
      noDecision()
      return
    }
    autoCloseTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.noDecision()
      }
    }
  }

  @objc private func applySuggestion(_ sender: NSButton) {
    guard let suggestion = (sender as? SuggestionButton)?.suggestion else { return }
    resolved = true
    let updated = PermissionSuggestionFormatter.updatedPermission(from: suggestion)
    permission?.resolve(.allowWithUpdatedPermissions([updated]))
    close()
  }

}

private struct PermissionDisplaySummary {
  var agentLabel: String
  var subtitle: String
  var description: String?
  var command: String?
  var rawInput: String

  init(request: PermissionRequest, lang: String) {
    let agentName = Self.displayName(request.agentId)
    let toolName = Self.displayName(request.toolName)
    self.agentLabel = String(request.agentId.uppercased().prefix(8))
    self.subtitle = Self.subtitle(agentName: agentName, toolName: toolName, lang: lang)
    self.command = Self.commandText(from: request.toolInput)
    self.description = Self.descriptionText(from: request)
    self.rawInput = Self.prettyInput(request.toolInput)
  }

  private static func subtitle(agentName: String, toolName: String, lang: String) -> String {
    switch lang {
    case "zh":
      return "\(agentName) 请求使用 \(toolName)"
    case "zh-TW":
      return "\(agentName) 請求使用 \(toolName)"
    case "ko":
      return "\(agentName)이(가) \(toolName)을(를) 사용하려고 합니다"
    case "ja":
      return "\(agentName) が \(toolName) を使用しようとしています"
    default:
      return "\(agentName) wants to use \(toolName)"
    }
  }

  private static func displayName(_ value: String) -> String {
    value
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { part in
        guard let first = part.first else { return "" }
        return first.uppercased() + part.dropFirst()
      }
      .joined(separator: " ")
  }

  private static func descriptionText(from request: PermissionRequest) -> String? {
    if let text = request.toolInputDescription?.trimmedNonEmpty {
      return text
    }
    guard let object = request.toolInput.objectValue else { return nil }
    for key in ["description", "reason", "message", "prompt"] {
      if let value = object[key]?.stringValue?.trimmedNonEmpty {
        return value
      }
    }
    return nil
  }

  private static func commandText(from value: JSONValue) -> String? {
    guard let object = value.objectValue else {
      return value.stringValue?.trimmedNonEmpty
    }
    for key in ["command", "cmd", "bash", "powershell", "script"] {
      if let command = shellCommand(from: object[key])?.trimmedNonEmpty {
        return command
      }
    }
    return nil
  }

  private static func shellCommand(from value: JSONValue?) -> String? {
    guard let value else { return nil }
    if let string = value.stringValue {
      return string
    }
    if case .array(let values) = value {
      let tokens = values.compactMap { item -> String? in
        if let string = item.stringValue { return shellToken(string) }
        return item.shortDescription.trimmedNonEmpty
      }
      return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }
    return value.shortDescription
  }

  private static func shellToken(_ value: String) -> String {
    guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return value }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func prettyInput(_ value: JSONValue) -> String {
    switch value {
    case .object, .array:
      guard JSONSerialization.isValidJSONObject(value.anyValue),
            let data = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
      else {
        return value.shortDescription
      }
      return text
    case .string, .number, .bool, .null:
      return value.shortDescription
    }
  }
}

private extension String {
  var trimmedNonEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

private extension JSONValue {
  var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

@MainActor
private final class SuggestionButton: NSButton {
  var suggestion: JSONValue?
}
