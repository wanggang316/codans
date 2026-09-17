import CodansIPC
import Foundation
import Testing

@testable import Codans

@MainActor
struct WorkflowDefinitionV2Tests {
  private var fixtures: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/WorkflowDefinitions")
  }

  private func source(_ name: String) throws -> String {
    try String(
      contentsOf: fixtures.appendingPathComponent("\(name).codansworkflow/workflow.yaml"),
      encoding: .utf8)
  }

  @Test func fiveProductionDefinitionsParse() throws {
    var nodeCount = 0
    for name in ["advisor", "committee", "decision-only", "handoff", "handoff-from-briefing"] {
      let definition = try WorkflowDefinitionParserV2.parse(source(name))
      nodeCount += definition.nodes.count
      #expect(definition.nodeIDs.count == definition.nodes.count)
      #expect(Set(definition.nodeIDs).count == definition.nodes.count)
    }
    #expect(nodeCount == 19)
  }

  @Test func invalidDefinitionsFailBeforeExecution() throws {
    let advisor = try source("advisor")
    let handoff = try source("handoff")
    let invalid = [
      advisor + "\nworkspace: required\n",
      advisor + "\nname: Duplicate\n",
      advisor.replacingOccurrences(of: "source: pick", with: "source: unknown"),
      advisor.replacingOccurrences(of: "codans/agent.request@v1", with: "codans/unknown@v1"),
      advisor.replacingOccurrences(of: "needs: [advice]", with: "needs: [decision]"),
      advisor.replacingOccurrences(of: "needs: [advice]", with: "needs: []"),
      advisor.replacingOccurrences(of: "inputs.question", with: "inputs.missing"),
      advisor.replacingOccurrences(of: "outputs.result", with: "outputs.missing"),
      handoff.replacingOccurrences(of: "    - launch_receiver\n", with: ""),
      handoff.replacingOccurrences(
        of: "minLength: 1", with: "minLength: 1\n            unknownKeyword: true"),
    ]
    for text in invalid {
      #expect(throws: (any Error).self) { try WorkflowDefinitionParserV2.parse(text) }
    }
  }

  @Test func deliveryContractRequiresHeadingsAndStrictJSON() throws {
    let advisor = try WorkflowDefinitionParserV2.parse(source("advisor"))
    let markdown = try #require(advisor.nodes["advice"]?.expect)
    try WorkflowDefinitionParserV2.validateResult(
      .string("## Findings\nEvidence\n## Recommendation\nAdopt"), expect: markdown)
    #expect(throws: (any Error).self) {
      try WorkflowDefinitionParserV2.validateResult(
        .string("Recommendation only"), expect: markdown)
    }
    let handoff = try WorkflowDefinitionParserV2.parse(source("handoff"))
    let receipt = try #require(handoff.nodes["receive"]?.expect)
    let valid: JSONValue = .object([
      "packetId": .string("packet"), "packetDigest": .string("digest"),
      "understanding": .string("Task"), "nextAction": .string("Review"), "blockers": .array([]),
    ])
    try WorkflowDefinitionParserV2.validateResult(valid, expect: receipt)
    #expect(throws: (any Error).self) {
      try WorkflowDefinitionParserV2.validateResult(.object([:]), expect: receipt)
    }
  }

  @Test func duplicateIdentityBlocksBothSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-conflict-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = WorkflowCatalogV2(root: root)
    let original = try catalog.create(name: "Original")
    let imported = try catalog.importDefinition(from: original.url)
    #expect(imported.definition == nil)
    #expect(imported.error != nil)
    #expect(catalog.entries.first(where: { $0.id == original.id })?.definition == nil)
    #expect(catalog.entries.first(where: { $0.id == original.id })?.source == original.source)
  }

  @Test func catalogCreatesDuplicatesAndRetainsInvalidFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-definitions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = WorkflowCatalogV2(root: root)
    let entry = try catalog.create(name: "A quoted \"workflow\"")
    #expect(entry.definition?.roles.isEmpty == true)
    let copy = try catalog.duplicate(entry)
    #expect(copy.definition?.id != entry.definition?.id)
    #expect(copy.definition?.nodes == entry.definition?.nodes)
    #expect(throws: (any Error).self) { try catalog.save(entry, source: "invalid: true") }
    try Data("invalid: true".utf8).write(to: entry.url)
    catalog.reload()
    #expect(catalog.entries.first(where: { $0.id == entry.id })?.error != nil)
    #expect(catalog.entries.first(where: { $0.id == entry.id })?.source == "invalid: true")
  }

  @Test func profileReferencesAreOnlyAcceptedForLaunchRoles() throws {
    let handoff = try source("handoff")
    let configured = handoff.replacingOccurrences(of: "source: launch", with: "source: launch\n    profile: Receiver")
    let parsed = try WorkflowDefinitionParserV2.parse(configured)
    #expect(parsed.roles.values.contains { $0.profile == "Receiver" })
    let empty = handoff.replacingOccurrences(of: "source: launch", with: "source: launch\n    profile: ''")
    #expect(throws: (any Error).self) { try WorkflowDefinitionParserV2.parse(empty) }
    let current = handoff.replacingOccurrences(of: "source: current", with: "source: current\n    profile: Receiver")
    #expect(current != handoff)
    #expect(throws: (any Error).self) { try WorkflowDefinitionParserV2.parse(current) }
  }

}
