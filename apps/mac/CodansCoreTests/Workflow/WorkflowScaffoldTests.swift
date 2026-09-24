import Foundation
import Testing

@testable import CodansCore

struct WorkflowScaffoldTests {
  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-scaffold-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test
  func theBlankStarterParsesAndValidatesClean() throws {
    let yaml = WorkflowScaffold.document(name: "My \"Review\"", source: .blank)
    let parsed = WorkflowDocumentParser.parse(yaml: yaml, id: "my-review")
    let definition = try #require(parsed.definition)
    #expect(!parsed.diagnostics.hasErrors)
    #expect(!WorkflowValidator.validate(definition).hasErrors)
    #expect(definition.name == "My \"Review\"")
  }

  @Test
  func aCopyKeepsTheBodyAndTakesTheNewName() throws {
    let source = "# keep me\nname: Advisor\ndescription: d\nroles:\n  a:\n    source: current\nsteps:\n  - notify: hi\n"
    let yaml = WorkflowScaffold.document(name: "Second Opinion", source: .copy(yaml: source))
    #expect(yaml == source.replacingOccurrences(of: "name: Advisor", with: "name: \"Second Opinion\""))
  }

  @Test
  func aCopyWithoutANameGetsOneFirst() {
    let yaml = WorkflowScaffold.document(name: "X", source: .copy(yaml: "steps: []\n"))
    #expect(yaml.hasPrefix("name: \"X\"\nsteps: []"))
  }

  @Test
  func createWritesTheFileWhereDiscoveryFindsIt() throws {
    let directory = try Self.temporaryDirectory().appendingPathComponent("workflows", isDirectory: true)
    let url = try WorkflowScaffold.create(id: "my-flow", name: "My Flow", source: .blank, in: directory)
    #expect(url.lastPathComponent == "my-flow.workflow.yaml")
    let entries = WorkflowDiscovery.scan(directory: directory, scope: .user)
    #expect(entries.map(\.id) == ["my-flow"])
    #expect(entries.first?.isValid == true)
  }

  @Test
  func createNeverOverwritesAndRejectsBadIDs() throws {
    let directory = try Self.temporaryDirectory()
    try WorkflowScaffold.create(id: "dup", name: "One", source: .blank, in: directory)
    #expect(throws: WorkflowScaffold.Failure.self) {
      try WorkflowScaffold.create(id: "dup", name: "Two", source: .blank, in: directory)
    }
    #expect(throws: WorkflowScaffold.Failure.invalidID("Bad Id")) {
      try WorkflowScaffold.create(id: "Bad Id", name: "Bad", source: .blank, in: directory)
    }
  }

  @Test
  func suggestedIDsAreKebabCase() {
    #expect(WorkflowScaffold.suggestedID(forName: "My Review Loop!") == "my-review-loop")
    #expect(WorkflowScaffold.suggestedID(forName: "  2nd  opinion ") == "2nd-opinion")
    #expect(WorkflowScaffold.suggestedID(forName: "评审") == nil)
  }
}
