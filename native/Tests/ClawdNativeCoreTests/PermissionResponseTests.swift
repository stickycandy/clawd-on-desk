import XCTest
@testable import ClawdNativeCore

final class PermissionResponseTests: XCTestCase {
  func testAllowResponseUsesHookSpecificOutputEnvelope() throws {
    let data = try XCTUnwrap(PermissionResponseBuilder.body(for: .allow))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let output = try XCTUnwrap(json?["hookSpecificOutput"] as? [String: Any])
    XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
    let decision = try XCTUnwrap(output["decision"] as? [String: Any])
    XCTAssertEqual(decision["behavior"] as? String, "allow")
    XCTAssertNil(decision["updatedInput"])
    XCTAssertNil(decision["updatedPermissions"])
    XCTAssertNil(decision["interrupt"])
  }

  func testNoDecisionHasNoBody() {
    XCTAssertNil(PermissionResponseBuilder.body(for: .noDecision))
  }

  func testSuggestionResponseCarriesUpdatedPermissions() throws {
    let suggestion: JSONValue = .object([
      "type": .string("setMode"),
      "mode": .string("acceptEdits")
    ])
    let updated = PermissionSuggestionFormatter.updatedPermission(from: suggestion)
    let data = try XCTUnwrap(PermissionResponseBuilder.body(for: .allowWithUpdatedPermissions([updated])))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let output = try XCTUnwrap(json?["hookSpecificOutput"] as? [String: Any])
    let decision = try XCTUnwrap(output["decision"] as? [String: Any])
    XCTAssertEqual(decision["behavior"] as? String, "allow")
    let permissions = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
    XCTAssertEqual(permissions.first?["type"] as? String, "setMode")
    XCTAssertEqual(permissions.first?["mode"] as? String, "acceptEdits")
  }

  func testCodexResponseOmitsUnsupportedPermissionFields() throws {
    let updated = PermissionSuggestionFormatter.updatedPermission(from: .object([
      "type": .string("setMode"),
      "mode": .string("acceptEdits")
    ]))
    let data = try XCTUnwrap(PermissionResponseBuilder.body(for: .allowWithUpdatedPermissions([updated]), agentId: "codex"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let output = try XCTUnwrap(json?["hookSpecificOutput"] as? [String: Any])
    let decision = try XCTUnwrap(output["decision"] as? [String: Any])
    XCTAssertEqual(decision["behavior"] as? String, "allow")
    XCTAssertNil(decision["updatedInput"])
    XCTAssertNil(decision["updatedPermissions"])
    XCTAssertNil(decision["interrupt"])
  }

  func testQwenResponseOmitsUnsupportedPermissionFields() throws {
    let updated = PermissionSuggestionFormatter.updatedPermission(from: .object([
      "type": .string("setMode"),
      "mode": .string("default")
    ]))
    let data = try XCTUnwrap(PermissionResponseBuilder.body(for: .allowWithUpdatedPermissions([updated]), agentId: "qwen-code"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let output = try XCTUnwrap(json?["hookSpecificOutput"] as? [String: Any])
    let decision = try XCTUnwrap(output["decision"] as? [String: Any])
    XCTAssertEqual(decision["behavior"] as? String, "allow")
    XCTAssertNil(decision["updatedInput"])
    XCTAssertNil(decision["updatedPermissions"])
    XCTAssertNil(decision["interrupt"])
  }

  func testCopilotResponseUsesSimpleDecisionShape() throws {
    let data = try XCTUnwrap(PermissionResponseBuilder.body(for: .deny(message: "no"), agentId: "copilot-cli"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(json?["behavior"] as? String, "deny")
    XCTAssertEqual(json?["message"] as? String, "no")
    XCTAssertNil(json?["hookSpecificOutput"])
  }

  func testHermesResponseUsesHermesDecisionShape() throws {
    let data = try XCTUnwrap(PermissionResponseBuilder.body(for: .allow, agentId: "hermes"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(json?["decision"] as? String, "allow")
    XCTAssertNil(json?["hookSpecificOutput"])
  }

  func testOpencodeBridgeReplyMapping() {
    XCTAssertEqual(PermissionResponseBuilder.opencodeBridgeReply(for: .allow), "accept")
    XCTAssertEqual(PermissionResponseBuilder.opencodeBridgeReply(for: .deny(message: nil)), "reject")
    XCTAssertNil(PermissionResponseBuilder.opencodeBridgeReply(for: .noDecision))
  }
}
