import CodansCore
import Foundation
import Observation
import Yams

@MainActor @Observable
final class WorkflowCatalogV2 {
  struct Entry: Identifiable {
    var id: String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    var name: String
    var source: String
    var url: URL
    var isBuiltin: Bool
    var definition: WorkflowDefinitionV2?
    var error: String?
  }

  private(set) var entries: [Entry] = []
  private(set) var issues: [String] = []
  let root: URL

  init(root: URL? = nil) {
    self.root =
      (root
      ?? Settings.defaultURL().deletingLastPathComponent().appendingPathComponent(
        "workflows/definitions", isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL
    reload()
  }

  func reload() {
    entries = []
    issues = []
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent(
      "WorkflowDefinitions", isDirectory: true),
      FileManager.default.fileExists(atPath: bundled.path)
    {
      discover(bundled, builtin: true)
    } else {
      issues.append("Built-in workflow definitions are missing from the application bundle.")
    }
    if FileManager.default.fileExists(atPath: root.path) {
      discover(root, builtin: false)
    }
    let identities = Dictionary(
      grouping: entries.filter { $0.definition != nil }, by: { $0.definition!.id })
    for (identity, matches) in identities where matches.count > 1 {
      let message =
        "Duplicate workflow identity: \(identity). Change the ID or remove the duplicate before running."
      issues.append(message)
      let paths = Set(matches.map(\.id))
      for index in entries.indices where paths.contains(entries[index].id) {
        entries[index].error = message
        entries[index].definition = nil
      }
    }
    entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func create(name: String) throws -> Entry {
    let identity = "user.\(UUID().uuidString.lowercased())"
    let escapedName = String(
      data: try JSONEncoder().encode(name.isEmpty ? "New Workflow" : name), encoding: .utf8)!
    let source = """
      schema: codans.workflow/v1
      id: \(identity)
      name: \(escapedName)
      inputs:
        proposal:
          type: string
          required: true
      nodes:
        decision:
          title: Review the proposal
          uses: codans/human.decide@v1
          with:
            question:
              value: Should this proposal be adopted?
            options:
              value: [adopt, request_changes, reject]
            evidence:
              ref: inputs.proposal
      outputs:
        decision:
          ref: nodes.decision.outputs.decision
        reason:
          ref: nodes.decision.outputs.reason
      """
    return try writeNew(source)
  }

  func save(_ entry: Entry, source: String) throws {
    guard !entry.isBuiltin,
      entry.url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    else {
      throw WorkflowDefinitionErrorV2(message: "Duplicate this definition before editing it.")
    }
    _ = try WorkflowDefinitionParserV2.parse(source)
    try Data(source.utf8).write(to: entry.url, options: .atomic)
    reload()
  }

  func duplicate(_ entry: Entry) throws -> Entry {
    var definition = try WorkflowDefinitionParserV2.parse(entry.source)
    definition.id = "user.\(UUID().uuidString.lowercased())"
    definition.name += " Copy"
    return try writeNew(YAMLEncoder().encode(definition))
  }

  func importDefinition(from url: URL) throws -> Entry {
    let sourceURL =
      url.hasDirectoryPath || url.pathExtension == "codansworkflow"
      ? url.appendingPathComponent("workflow.yaml") : url
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    return try writeNew(source)
  }

  private func writeNew(_ source: String) throws -> Entry {
    _ = try WorkflowDefinitionParserV2.parse(source)
    let directory = root.appendingPathComponent(
      "\(UUID().uuidString).codansworkflow", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("workflow.yaml")
    try Data(source.utf8).write(to: url, options: .atomic)
    reload()
    guard
      let entry = entries.first(where: {
        $0.id == url.resolvingSymlinksInPath().standardizedFileURL.path
      })
    else {
      throw WorkflowDefinitionErrorV2(message: "Saved definition was not found during discovery.")
    }
    return entry
  }

  private func discover(_ directory: URL, builtin: Bool) {
    do {
      let children = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      for child in children {
        let url: URL
        if child.pathExtension == "codansworkflow" {
          url = child.appendingPathComponent("workflow.yaml")
        } else if ["yaml", "yml"].contains(child.pathExtension) {
          url = child
        } else {
          continue
        }
        var entry = Entry(
          name: child.deletingPathExtension().lastPathComponent, source: "",
          url: url.resolvingSymlinksInPath().standardizedFileURL,
          isBuiltin: builtin)
        do {
          entry.source = try String(contentsOf: url, encoding: .utf8)
          let definition = try WorkflowDefinitionParserV2.parse(entry.source)
          entry.name = definition.name
          entry.definition = definition
        } catch { entry.error = error.localizedDescription }
        entries.append(entry)
      }
    } catch { issues.append("\(directory.path): \(error.localizedDescription)") }
  }
}
