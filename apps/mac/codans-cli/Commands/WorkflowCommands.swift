import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct WorkflowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workflow",
    abstract: "Create workflows and explicitly claim and deliver their assignments.",
    subcommands: [
      WorkflowCreate.self, WorkflowList.self, WorkflowStatus.self,
      WorkflowClaim.self, WorkflowDeliver.self, WorkflowCancel.self,
    ]
  )
}

struct WorkflowCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a workflow run.")
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Workflow template identifier.") var template: String
  @Option(name: .long, help: "Run title.") var title: String
  @Option(name: .long, help: "Task input; '-' reads stdin.") var input: String
  @Option(name: .long, help: "Stable command UUID for an idempotent create retry.") var commandID: String?

  func run() async throws {
    await CommandRunner.run {
      let id = try commandID.map { try WorkflowCLI.uuid($0, name: "command-id") } ?? UUID()
      let request = IPC.WorkflowCreateRequest(
        commandID: id, template: template, title: title, input: try WorkflowCLI.content(input))
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: JSONValue = try await client.call(
        .workflowCreate, params: request, timeout: globals.rpcTimeout)
      try WorkflowCLI.emit(response, globals: globals)
    }
  }
}

struct WorkflowList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list", abstract: "List workflow runs.")
  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let response: JSONValue = try await client.call(
        .workflowList, params: EmptyParams(), timeout: globals.rpcTimeout)
      try WorkflowCLI.emit(response, globals: globals)
    }
  }
}

struct WorkflowStatus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status", abstract: "Inspect a workflow run.")
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run UUID.") var runID: String

  func run() async throws {
    await CommandRunner.run {
      try await WorkflowCLI.runRequest(.workflowStatus, runID: runID, globals: globals)
    }
  }
}

struct WorkflowClaim: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "claim", abstract: "Claim a ready assignment.")
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run UUID.") var runID: String
  @Option(name: .long, help: "Step identifier.") var step: String
  @Option(name: .long, help: "Pane UUID, handle, label, or 'current'.") var pane: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let id = try WorkflowCLI.uuid(runID, name: "run")
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneID = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let response: JSONValue = try await client.call(
        .workflowClaim,
        params: IPC.WorkflowClaimRequest(runID: id, stepID: step, paneID: paneID.uuidString),
        timeout: globals.rpcTimeout)
      try WorkflowCLI.emit(response, globals: globals)
    }
  }
}

struct WorkflowDeliver: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "deliver", abstract: "Deliver an assignment result.")
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run UUID.") var runID: String
  @Option(name: .long, help: "Claimed attempt UUID.") var attempt: String
  @Option(name: .long, help: "Stable delivery UUID; reuse it when retrying the same submission.") var deliveryID: String
  @Option(name: .long, help: "Pane UUID, handle, label, or 'current'.") var pane: String = "current"
  @Option(name: .long, help: "Result content; '-' reads stdin.") var content: String

  func run() async throws {
    await CommandRunner.run {
      let id = try WorkflowCLI.uuid(runID, name: "run")
      let attemptID = try WorkflowCLI.uuid(attempt, name: "attempt")
      let submissionID = try WorkflowCLI.uuid(deliveryID, name: "delivery-id")
      let body = try WorkflowCLI.content(content)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneID = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let response: JSONValue = try await client.call(
        .workflowDeliver,
        params: IPC.WorkflowDeliverRequest(
          runID: id, attemptID: attemptID, deliveryID: submissionID, paneID: paneID.uuidString, content: body),
        timeout: globals.rpcTimeout)
      try WorkflowCLI.emit(response, globals: globals)
    }
  }
}

struct WorkflowCancel: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel workflow scheduling.")
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Run UUID.") var runID: String

  func run() async throws {
    await CommandRunner.run {
      try await WorkflowCLI.runRequest(.workflowCancel, runID: runID, globals: globals)
    }
  }
}

private enum WorkflowCLI {
  static func uuid(_ value: String, name: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
      throw CLIError(code: .userError, message: "\(name) must be a UUID")
    }
    return id
  }

  static func content(_ value: String) throws -> String {
    value == "-" ? try StandardInput.readString() : value
  }

  static func runRequest(_ method: IPC.Method, runID: String, globals: GlobalOptions) async throws {
    let request = IPC.WorkflowRunRequest(runID: try uuid(runID, name: "run"))
    let client = CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let response: JSONValue = try await client.call(method, params: request, timeout: globals.rpcTimeout)
    try emit(response, globals: globals)
  }

  static func emit<T: Encodable>(_ response: T, globals: GlobalOptions) throws {
    let encoder = JSONEncoder()
    let value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(response))
    try Renderer.emit(JSONValueRenderable(value), mode: globals.renderMode)
  }
}
