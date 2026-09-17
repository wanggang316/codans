import Foundation

/// The atomic run snapshot is the sole source of truth, including all receipt bodies.
@MainActor final class WorkflowRunStoreV2 {
  let root: URL
  private let maximumSnapshotSize = 16 * 1024 * 1024

  init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func load() throws -> [WorkflowRunV2] {
    let runsDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
    guard FileManager.default.fileExists(atPath: runsDirectory.path) else { return [] }
    let directories = try FileManager.default.contentsOfDirectory(
      at: runsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    var runs: [WorkflowRunV2] = []
    for directory in directories {
      guard let id = UUID(uuidString: directory.lastPathComponent),
        try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      else { continue }
      let snapshot = directory.appendingPathComponent("run.json")
      guard FileManager.default.fileExists(atPath: snapshot.path) else { continue }
      do {
        let size = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumSnapshotSize else {
          throw WorkflowRuntimeErrorV2.invalid("Workflow record exceeds 16 MiB")
        }
        let run = try JSONDecoder().decode(WorkflowRunV2.self, from: Data(contentsOf: snapshot))
        guard run.id == id else {
          throw WorkflowRuntimeErrorV2.invalid("Run identity does not match its directory")
        }
        runs.append(run)
      } catch {
        throw WorkflowRuntimeErrorV2.invalid(
          "Cannot read workflow snapshot \(snapshot.path): \(error.localizedDescription)")
      }
    }
    return runs
  }

  func save(_ run: WorkflowRunV2) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(run)
    guard data.count <= maximumSnapshotSize else {
      throw WorkflowRuntimeErrorV2.invalid("Workflow record exceeds 16 MiB")
    }
    let directory = runDirectory(run.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Inputs, outputs, requests, submissions and events are committed together.
    // A crash during derived-file updates can only leave those files behind the
    // committed snapshot; startup rebuilds them without replaying external work.
    try data.write(to: directory.appendingPathComponent("run.json"), options: .atomic)
    _ = try inspectionDirectory(for: run)
  }

  private func runDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent("artifacts/\(id.uuidString)", isDirectory: true)
  }

  func inspectionDirectory(for run: WorkflowRunV2) throws -> URL {
    let directory = runDirectory(run.id)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try run.source.write(to: directory.appendingPathComponent("workflow.yaml"), atomically: true, encoding: .utf8)
    let lineEncoder = JSONEncoder()
    lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var events = Data()
    for event in run.events {
      events.append(try lineEncoder.encode(event))
      events.append(0x0a)
    }
    try events.write(to: directory.appendingPathComponent("events.jsonl"), options: .atomic)
    for node in run.nodes.values {
      for execution in node.executions ?? [] {
        let folder = directory.appendingPathComponent("nodes/\(execution.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(execution).write(to: folder.appendingPathComponent("execution.json"), options: .atomic)
        try encoder.encode(execution.inputs).write(to: folder.appendingPathComponent("inputs.json"), options: .atomic)
        try encoder.encode(execution.outputs).write(to: folder.appendingPathComponent("outputs.json"), options: .atomic)
        if let request = execution.request {
          try encoder.encode(request).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
          try request.prompt.write(
            to: folder.appendingPathComponent("instruction.md"), atomically: true, encoding: .utf8)
        }
        if !execution.submissions.isEmpty {
          let submissions = folder.appendingPathComponent("submissions", isDirectory: true)
          try FileManager.default.createDirectory(at: submissions, withIntermediateDirectories: true)
          for submission in execution.submissions {
            try encoder.encode(submission).write(
              to: submissions.appendingPathComponent("\(submission.id.uuidString).json"), options: .atomic)
          }
        }
      }
    }
    return directory
  }

}
