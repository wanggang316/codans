import Foundation
import Testing

@testable import CodansCore

struct WorkflowSettingsTests {
  @Test
  func absentSubtreeDecodesToDefaultAndDefaultIsOmittedOnEncode() throws {
    let json = Data(#"{"version": 3}"#.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: json)
    #expect(settings.workflows == .default)
    #expect(settings.workflows.isEnabled)

    let encoded = try JSONEncoder().encode(settings)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["workflows"] == nil)
  }

  @Test
  func bindingsTrustAndDisabledRoundTrip() throws {
    var workflows = WorkflowSettings()
    workflows.isEnabled = false
    workflows.disabled = ["advisor"]
    let profile = UUID()
    workflows.remember(
      WorkflowBindingMemory(
        scope: .user, workflowID: "review-loop", role: "reviewer", requirementsDigest: "abc", profileID: profile))
    workflows.remember(
      WorkflowBindingMemory(
        scope: .user, workflowID: "review-loop", role: "reviewer", requirementsDigest: "def", profileID: profile))
    let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
    workflows.trust(path: "/repo/.codans/workflows/ci.workflow.yaml", sha256: "0011", at: grantedAt)
    workflows.trust(path: "/repo/.codans/workflows/ci.workflow.yaml", sha256: "2233", at: grantedAt)

    // One memory per (scope, workflow, role) and one grant per path.
    #expect(workflows.bindings.count == 1)
    #expect(
      workflows.binding(scope: .user, workflowID: "review-loop", role: "reviewer", digest: "def")?.profileID == profile)
    #expect(workflows.binding(scope: .user, workflowID: "review-loop", role: "reviewer", digest: "abc") == nil)
    #expect(workflows.trusted.count == 1)
    #expect(workflows.isTrusted(path: "/repo/.codans/workflows/ci.workflow.yaml", sha256: "2233"))
    #expect(!workflows.isTrusted(path: "/repo/.codans/workflows/ci.workflow.yaml", sha256: "0011"))

    let settings = Settings(workflows: workflows)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Settings.self, from: try encoder.encode(settings))
    #expect(decoded.workflows == workflows)
    #expect(decoded.workflows.isDisabled("advisor"))
  }
}
