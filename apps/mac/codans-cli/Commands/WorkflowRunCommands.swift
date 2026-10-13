import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct WorkflowStatus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show a run, or — without arguments — the run the calling pane takes part in.",
    discussion: """
      With a run id: state, current step, attention (when the run waits for
      the user), the delivery being waited for with its completion command,
      and every delivery so far. Without one, the calling pane is looked up
      among the active runs' participants, so an agent can ask "what is
      expected of me" without knowing the run id.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run id (full UUID). Omit to look up the calling pane's run.")
  var runID: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let parsedRunID = try runID.map(WorkflowRunID.parse)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: IPC.WorkflowStatusResponse = try await client.call(
        .workflowStatus,
        params: IPC.WorkflowStatusRequest(
          runID: parsedRunID,
          callerPaneID: parsedRunID == nil ? WorkflowCallerContext.paneID() : nil)
      )
      try Renderer.emit(WorkflowStatusRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct WorkflowDeliver: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "deliver",
    abstract: "Deliver the output a step expects from the calling agent.",
    discussion: """
      The body comes from stdin (`-`, usually a heredoc) or --file. The step is
      found through the calling pane and the activation token the workflow
      handed the agent ($CODANS_WORKFLOW_TOKEN, or --token); outside a pane,
      name the step with --run and --step. A body that misses a required
      section or verdict is recorded as provisional and the run waits for the
      user, unless the step is strict — then it is refused. --force delivers
      it anyway.

        codans workflow deliver --verdict clean - <<'EOF'
        ## Findings
        None.
        EOF
        codans workflow deliver --file review.md
      """
  )

  /// Bodies above this are refused before the request is built; the frame
  /// limit on the socket is the same size and would fail less helpfully.
  static let maxBodyBytes = 16 * 1024 * 1024

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "'-' to read the body from stdin.")
  var body: String?
  @Option(name: .long, help: "Read the body from a file instead of stdin.")
  var file: String?
  @Option(name: .long, help: "Verdict slug, required when the step declares verdicts.")
  var verdict: String?
  @Option(name: .long, help: "Activation token (default: $CODANS_WORKFLOW_TOKEN).")
  var token: String?
  @Option(name: .customLong("run"), help: "Run id, for a delivery made outside the agent's pane (with --step).")
  var runID: String?
  @Option(name: .customLong("step"), help: "Step id, with --run.")
  var stepID: String?
  @Flag(name: .long, help: "Deliver even if the body fails the step's checks.")
  var force: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let explicitRun = try Self.explicitTarget(runID: runID, stepID: stepID)
      let text = try Self.readBody(positional: body, file: file)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: IPC.WorkflowDeliverResponse = try await client.call(
        .workflowDeliver,
        params: IPC.WorkflowDeliverRequest(
          callerPaneID: WorkflowCallerContext.paneID(),
          token: token ?? WorkflowCallerContext.token(),
          runID: explicitRun?.runID,
          stepID: explicitRun?.stepID,
          body: text,
          verdict: verdict,
          force: force
        )
      )
      try Renderer.emit(WorkflowDeliverRenderable(response: response), mode: globals.renderMode)
    }
  }

  static func explicitTarget(runID: String?, stepID: String?) throws -> (runID: UUID, stepID: String)? {
    switch (runID, stepID) {
    case (nil, nil):
      return nil
    case (let run?, let step?):
      return (try WorkflowRunID.parse(run), step)
    default:
      throw CLIError(code: .userError, message: "--run and --step must be given together")
    }
  }

  static func readBody(positional: String?, file: String?) throws -> String {
    let text: String
    switch (positional, file) {
    case ("-"?, nil):
      text = try StandardInput.readString()
    case (nil, let path?):
      text = try Self.readFile(path)
    case (nil, nil):
      throw CLIError(code: .userError, message: "pass '-' to read the body from stdin, or --file <path>")
    case (_?, _?):
      throw CLIError(code: .userError, message: "'-' and --file are mutually exclusive")
    case (let other?, nil):
      throw CLIError(code: .userError, message: "unexpected argument \"\(other)\"; the body is read from '-' or --file")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CLIError(code: .userError, message: "the delivery body is empty", errorCode: .emptyInput)
    }
    guard text.utf8.count <= maxBodyBytes else {
      throw CLIError(
        code: .userError,
        message: "the delivery body exceeds \(maxBodyBytes / 1024 / 1024) MiB",
        errorCode: .outputTooLarge,
        details: ["bytes": String(text.utf8.count)])
    }
    return text
  }

  private static func readFile(_ path: String) throws -> String {
    let absolute = PathResolver.absolute(path)
    guard let data = FileManager.default.contents(atPath: absolute) else {
      throw CLIError(
        code: .notFound, message: "file not found: \(absolute)", details: ["kind": "file", "id": absolute])
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw CLIError(code: .userError, message: "\(absolute) is not valid UTF-8")
    }
    return text
  }
}

/// The user actions a run in `needs_attention` accepts. The server's
/// `attention.actions` is authoritative for which apply right now; this
/// only rejects a spelling no run could ever accept.
enum WorkflowResolveAction: String, ExpressibleByArgument, CaseIterable {
  case accept
  case acceptWithVerdict = "accept-with-verdict"
  case askAgain = "ask-again"
  case keepWaiting = "keep-waiting"
  case skip
  case cancel
  case relaunch
  case retry
  case focusPane = "focus-pane"
}

struct WorkflowResolve: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resolve",
    abstract: "Answer a run that needs attention with the same actions the app offers.",
    discussion: """
      Actions: accept, accept-with-verdict (with --verdict), ask-again,
      keep-waiting, skip, cancel, relaunch, retry, focus-pane. Which ones the
      run accepts right now is what `status` lists under attention. Skipping
      a step whose delivery a later step needs ends the run as skipped.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run id (full UUID).")
  var runID: String
  @Argument(help: ArgumentHelp("One of: " + WorkflowResolveAction.allCases.map(\.rawValue).joined(separator: ", ")))
  var action: WorkflowResolveAction
  @Option(name: .long, help: "Verdict slug for accept-with-verdict.")
  var verdict: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let parsedRunID = try WorkflowRunID.parse(runID)
      if action == .acceptWithVerdict, verdict == nil {
        throw CLIError(code: .userError, message: "accept-with-verdict needs --verdict <slug>")
      }
      if action != .acceptWithVerdict, verdict != nil {
        throw CLIError(code: .userError, message: "--verdict only applies to accept-with-verdict")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: IPC.WorkflowStatusResponse = try await client.call(
        .workflowResolve,
        params: IPC.WorkflowResolveRequest(runID: parsedRunID, action: action.rawValue, verdict: verdict)
      )
      try Renderer.emit(WorkflowStatusRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct WorkflowCancel: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cancel",
    abstract: "End a run: revoke its tokens and mark the active step failed.",
    discussion: """
      Nothing else is undone — panes stay open, agents keep working, files
      written so far remain. A `run:` step in flight is terminated.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run id (full UUID).")
  var runID: String

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let parsedRunID = try WorkflowRunID.parse(runID)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: IPC.WorkflowStatusResponse = try await client.call(
        .workflowCancel, params: IPC.WorkflowCancelRequest(runID: parsedRunID))
      try Renderer.emit(WorkflowStatusRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct WorkflowRuns: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runs",
    abstract: "List a worktree's runs, newest first.",
    discussion: """
      Inside a pane the worktree is the pane's own; elsewhere pass --worktree.
      Text output shortens run ids to eight characters; --json carries the
      full id.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Worktree id, name, branch, path, or a pane/tab reference inside it.")
  var worktree: String?
  @Option(name: .long, help: "Maximum number of runs to list.")
  var limit: Int?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      if let limit, limit < 1 {
        throw CLIError(code: .userError, message: "--limit must be at least 1")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      var worktreeID: WorktreeID?
      if let worktree {
        worktreeID = try await WorkflowSourceResolver.worktree(worktree, client: client)
      }
      let response: IPC.WorkflowRunListResponse = try await client.call(
        .workflowListRuns,
        params: IPC.WorkflowListRunsRequest(
          worktreeID: worktreeID,
          paneID: worktreeID == nil ? WorkflowCallerContext.paneID() : nil,
          limit: limit)
      )
      try Renderer.emit(WorkflowRunListRenderable(response: response), mode: globals.renderMode)
    }
  }
}
