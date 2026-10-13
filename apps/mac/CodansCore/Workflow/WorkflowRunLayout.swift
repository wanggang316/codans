import Foundation

/// The on-disk shape of a workflow run, spelled once for the store that
/// writes it, the machine that renders pointer lines into it, and the
/// prompts that quote it.
///
/// ```
/// <worktree>/.codans/workflow-runs/
///   index.json
///   <run-id>/
///     run.json
///     log.md
///     definition.workflow.yaml
///     instructions/<step>.<ordinal>.md
///     deliveries/<name>.<ordinal>.md
///     deliveries/<name>.md
///     steps/<id>.<ordinal>.stdout.log
///     steps/<id>.<ordinal>.stderr.log
/// ```
public nonisolated enum WorkflowRunLayout {
  public static let stateDirectoryName = HandoffLayout.stateDirectoryName
  public static let runsDirectoryName = "workflow-runs"
  public static let indexFileName = "index.json"
  public static let recordFileName = "run.json"
  public static let logFileName = "log.md"
  public static let definitionFileName = "definition.workflow.yaml"
  public static let instructionsDirectoryName = "instructions"
  public static let deliveriesDirectoryName = "deliveries"
  public static let stepsDirectoryName = "steps"

  // MARK: - URLs

  public static func runsDirectory(worktreeRoot: URL) -> URL {
    worktreeRoot
      .appending(path: stateDirectoryName, directoryHint: .isDirectory)
      .appending(path: runsDirectoryName, directoryHint: .isDirectory)
  }

  public static func indexURL(worktreeRoot: URL) -> URL {
    runsDirectory(worktreeRoot: worktreeRoot).appending(path: indexFileName)
  }

  public static func runDirectory(worktreeRoot: URL, runID: UUID) -> URL {
    runsDirectory(worktreeRoot: worktreeRoot).appending(path: runID.uuidString, directoryHint: .isDirectory)
  }

  public static func recordURL(runDirectory: URL) -> URL {
    runDirectory.appending(path: recordFileName)
  }

  public static func logURL(runDirectory: URL) -> URL {
    runDirectory.appending(path: logFileName)
  }

  public static func definitionURL(runDirectory: URL) -> URL {
    runDirectory.appending(path: definitionFileName)
  }

  public static func instructionsDirectory(runDirectory: URL) -> URL {
    runDirectory.appending(path: instructionsDirectoryName, directoryHint: .isDirectory)
  }

  public static func deliveriesDirectory(runDirectory: URL) -> URL {
    runDirectory.appending(path: deliveriesDirectoryName, directoryHint: .isDirectory)
  }

  public static func stepsDirectory(runDirectory: URL) -> URL {
    runDirectory.appending(path: stepsDirectoryName, directoryHint: .isDirectory)
  }

  public static func instructionURL(runDirectory: URL, stepID: String, ordinal: Int) -> URL {
    instructionsDirectory(runDirectory: runDirectory).appending(
      path: instructionFileName(stepID: stepID, ordinal: ordinal))
  }

  public static func deliveryURL(runDirectory: URL, name: String, ordinal: Int) -> URL {
    deliveriesDirectory(runDirectory: runDirectory).appending(path: deliveryFileName(name: name, ordinal: ordinal))
  }

  public static func latestDeliveryURL(runDirectory: URL, name: String) -> URL {
    deliveriesDirectory(runDirectory: runDirectory).appending(path: latestDeliveryFileName(name: name))
  }

  public static func stdoutURL(runDirectory: URL, stepID: String, ordinal: Int) -> URL {
    stepsDirectory(runDirectory: runDirectory).appending(path: "\(stepID).\(ordinal).stdout.log")
  }

  public static func stderrURL(runDirectory: URL, stepID: String, ordinal: Int) -> URL {
    stepsDirectory(runDirectory: runDirectory).appending(path: "\(stepID).\(ordinal).stderr.log")
  }

  // MARK: - File names

  public static func instructionFileName(stepID: String, ordinal: Int) -> String {
    "\(stepID).\(ordinal).md"
  }

  public static func deliveryFileName(name: String, ordinal: Int) -> String {
    "\(name).\(ordinal).md"
  }

  public static func latestDeliveryFileName(name: String) -> String {
    "\(name).md"
  }

  // MARK: - Path strings

  /// Absolute path of an instruction file, from the run directory path
  /// the configuration carries. The machine renders pointer lines with
  /// it before the file exists.
  public static func instructionPath(runDirectory: String, stepID: String, ordinal: Int) -> String {
    joined(runDirectory, instructionsDirectoryName, instructionFileName(stepID: stepID, ordinal: ordinal))
  }

  public static func deliveryPath(runDirectory: String, name: String, ordinal: Int) -> String {
    joined(runDirectory, deliveriesDirectoryName, deliveryFileName(name: name, ordinal: ordinal))
  }

  public static func latestDeliveryPath(runDirectory: String, name: String) -> String {
    joined(runDirectory, deliveriesDirectoryName, latestDeliveryFileName(name: name))
  }

  /// `.codans/workflow-runs` — as an agent sees it from the worktree root.
  public static var worktreeRelativeRunsDirectory: String {
    "\(stateDirectoryName)/\(runsDirectoryName)"
  }

  /// `.codans/workflow-runs/<run-id>`.
  public static func worktreeRelativeRunDirectory(runID: UUID) -> String {
    "\(worktreeRelativeRunsDirectory)/\(runID.uuidString)"
  }

  private static func joined(_ components: String...) -> String {
    components.enumerated().map { index, component in
      index == 0 ? component.trimmingTrailingSlashes() : component
    }.joined(separator: "/")
  }
}

extension String {
  fileprivate func trimmingTrailingSlashes() -> String {
    var trimmed = Substring(self)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
  }
}
