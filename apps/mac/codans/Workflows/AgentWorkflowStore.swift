import CodansCore
import CodansIPC
import CryptoKit
import Foundation
import Observation

/// The app is the only writer. A mutation becomes observable only after its snapshot commits.
@MainActor
@Observable
final class AgentWorkflowStore {
  nonisolated struct Record: Codable, Sendable {
    var schemaVersion = 1
    var run: AgentWorkflowRun
    var receiverPaneID: String?
    var packetDigest: String?
    var execution: AgentWorkflowExecution?
  }

  @ObservationIgnored var didChange: (@MainActor (UUID) -> Void)?

  private(set) var records: [UUID: Record] = [:]
  private(set) var issues: [String] = []
  private var fenced: Set<UUID> = []
  private let root: URL
  private let write: (Record, URL) throws -> Void
  private let now: () -> Date

  init(
    root: URL = Settings.defaultURL().deletingLastPathComponent().appendingPathComponent(
      "workflows/runs"),
    now: @escaping () -> Date = Date.init,
    write: @escaping (Record, URL) throws -> Void = { try AtomicFileStore.write($0, to: $1) }
  ) {
    self.root = root
    self.now = now
    self.write = write
    load()
  }

  static func live() -> AgentWorkflowStore {
    let environment = ProcessInfo.processInfo.environment
    if environment["XCTestBundlePath"] != nil || environment["XCTestConfigurationFilePath"] != nil {
      return AgentWorkflowStore(
        root: FileManager.default.temporaryDirectory
          .appendingPathComponent("workflow-test-host-\(UUID().uuidString)"))
    }
    return AgentWorkflowStore()
  }

  var runs: [AgentWorkflowRun] {
    records.values.map(\.run).sorted { $0.createdAt > $1.createdAt }
  }

  func create(id: UUID, template: AgentWorkflowTemplate, title: String, input: String) throws
    -> AgentWorkflowRun
  {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.utf8.count <= 512, input.utf8.count <= 65_536
    else {
      throw IPCError.invalidParams(message: "Invalid workflow title or input size", path: nil)
    }
    if let existing = records[id]?.run {
      guard existing.template == template, existing.title == title, existing.input == input else {
        throw IPCError.conflict(reason: "Command ID already used with different input")
      }
      return existing
    }
    guard !FileManager.default.fileExists(atPath: url(id).path) else {
      throw IPCError.conflict(reason: "An unreadable workflow already owns this ID")
    }
    let run = AgentWorkflowRun(id: id, template: template, title: title, input: input, now: now())
    try commit(Record(run: run))
    return run
  }

  func canDispatch(_ id: UUID) -> Bool {
    !fenced.contains(id) && records[id]?.run.status == .running
  }

  func status(_ id: UUID) throws -> AgentWorkflowRun { try record(id).run }

  func claim(_ id: UUID, stepID: String, paneID: String) throws -> AgentWorkflowAttempt {
    try checkFence(id)
    var value = try record(id)
    guard value.run.status == .running else { throw AgentWorkflowError.terminalRun }
    if let execution = value.execution {
      guard let dispatch = execution.dispatches[stepID] else {
        throw IPCError.conflict(reason: "This step has not been dispatched")
      }
      if dispatch.status == .launching {
        throw IPCError.conflict(reason: "Agent binding is pending; retry claim shortly")
      }
      guard dispatch.status == .submitted || (dispatch.status == .attention && dispatch.paneID != nil) else {
        throw IPCError.conflict(reason: "Dispatch needs attention; do not retry claim automatically")
      }
      guard dispatch.paneID == paneID else {
        throw IPCError.conflict(reason: "This assignment belongs to another pane")
      }
    }
    if stepID == "receive", value.packetDigest != nil,
      let expected = value.receiverPaneID, expected != paneID
    {
      throw IPCError.conflict(reason: "Only the handoff receiver can claim this step")
    }
    if let attempt = value.run.currentAttempt, attempt.stepID == stepID, attempt.paneID == paneID {
      return attempt
    }
    let attempt = try value.run.claim(stepID: stepID, paneID: paneID, now: now())
    if value.execution?.dispatches[stepID]?.status == .attention {
      value.execution?.dispatches[stepID]?.status = .submitted
      value.execution?.dispatches[stepID]?.message = nil
    }
    try commit(value)
    return attempt
  }

  func deliver(
    _ id: UUID, attemptID: UUID, deliveryID: UUID, paneID: String, content: String
  ) throws -> AgentWorkflowRun {
    try checkFence(id)
    guard content.utf8.count <= 32_768 else {
      throw IPCError.invalidParams(message: "Delivery exceeds 32 KiB", path: ["content"])
    }
    var value = try record(id)
    let previous = value.run
    if value.run.attempts.first(where: { $0.id == attemptID })?.stepID == "receive",
      let digest = value.packetDigest
    {
      guard let data = content.data(using: .utf8),
        let receipt = try? JSONDecoder().decode(HandoffReceipt.self, from: data),
        receipt.packetDigest == digest,
        !receipt.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw IPCError.invalidParams(
          message: "Receipt requires matching packetDigest and nextAction", path: nil)
      }
    }
    try value.run.deliver(
      attemptID: attemptID, deliveryID: deliveryID, paneID: paneID, content: content, now: now())
    if value.run == previous { return value.run }
    if value.run.attempts.first(where: { $0.id == attemptID })?.stepID == "packet" {
      value.packetDigest = Self.digest(content)
      value.run.record(type: "packet.saved", message: "SHA256: \(Self.digest(content))", now: now())
    }
    try commit(value)
    return value.run
  }

  func cancel(_ id: UUID) throws -> AgentWorkflowRun {
    var value = try record(id)
    guard value.run.status == .running else { return value.run }
    fenced.insert(id)
    value.run.cancel(now: now())
    try commit(value)
    return value.run
  }

  func recordEvent(_ id: UUID, type: String, message: String) throws {
    try checkFence(id)
    var value = try record(id)
    value.run.record(type: type, message: message, now: now())
    try commit(value)
  }

  func installPacket(_ id: UUID, content: String, sourcePaneID: String) throws -> String {
    guard content.utf8.count <= 32_768 else {
      throw IPCError.invalidParams(message: "Handoff packet exceeds 32 KiB", path: nil)
    }
    let attempt = try claim(id, stepID: "packet", paneID: sourcePaneID)
    let digest = Self.digest(content)
    var value = try record(id)
    value.packetDigest = digest
    if value.run.template == .handoff { value.receiverPaneID = "pending-launch" }
    try value.run.deliver(
      attemptID: attempt.id, deliveryID: UUID(), paneID: sourcePaneID, content: content, now: now())
    value.run.record(type: "packet.saved", message: "SHA256: \(digest)", now: now())
    _ = try value.run.claim(stepID: "export", paneID: sourcePaneID, now: now())
    try commit(value)
    return digest
  }

  func finishExport(_ id: UUID, sourcePaneID: String) throws {
    guard let attempt = try record(id).run.currentAttempt,
      attempt.stepID == "export", attempt.paneID == sourcePaneID
    else { throw IPCError.conflict(reason: "No matching handoff export is active") }
    _ = try deliver(
      id, attemptID: attempt.id, deliveryID: UUID(), paneID: sourcePaneID,
      content: "Compatibility handoff files saved.")
  }

  func bindReceiver(_ id: UUID, paneID: String) throws {
    try checkFence(id)
    var value = try record(id)
    guard value.run.status == .running,
      value.run.steps.first(where: { $0.id == "receive" })?.status == .pending,
      value.receiverPaneID == nil || value.receiverPaneID == "pending-launch"
        || value.receiverPaneID == paneID
    else {
      throw IPCError.conflict(reason: "Receiver binding is already fixed or the run has ended")
    }
    value.receiverPaneID = paneID
    value.run.record(
      type: "receiver.launched", message: "Waiting for receipt from \(paneID)", now: now())
    try commit(value)
  }

  func configureExecution(_ id: UUID, configuration: AgentWorkflowExecution) throws {
    try checkFence(id)
    var value = try record(id)
    if let existing = value.execution {
      guard existing.projectID == configuration.projectID,
        existing.worktreeID == configuration.worktreeID, existing.primary == configuration.primary,
        existing.secondary == configuration.secondary
      else { throw IPCError.conflict(reason: "Workflow launch settings are already fixed") }
      return
    }
    guard value.run.status == .running, value.run.attempts.isEmpty else {
      throw IPCError.conflict(reason: "Only a new workflow can be configured for automatic execution")
    }
    value.execution = configuration
    value.run.record(type: "execution.configured", message: "Agents and workspace selected", now: now())
    try commit(value)
  }

  func beginDispatch(_ id: UUID, stepID: String) throws -> Bool {
    try checkFence(id)
    var value = try record(id)
    guard value.run.status == .running, var execution = value.execution else { return false }
    guard execution.dispatches[stepID] == nil else { return false }
    guard
      !execution.dispatches.keys.contains(where: { dispatched in
        value.run.steps.first(where: { $0.id == dispatched })?.status != .accepted
      })
    else { return false }
    guard value.run.readySteps.contains(where: { $0.id == stepID }) else { return false }
    execution.dispatches[stepID] = AgentWorkflowDispatch(status: .launching, startedAt: now())
    value.execution = execution
    value.run.record(type: "dispatch.intent", message: "Preparing agent for \(stepID)", now: now())
    try commit(value)
    return true
  }

  func bindDispatch(_ id: UUID, stepID: String, paneID: String) throws {
    try checkFence(id)
    guard !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentWorkflowError.invalidPane
    }
    var value = try record(id)
    guard value.run.status == .running, var execution = value.execution,
      var dispatch = execution.dispatches[stepID], dispatch.status == .launching
    else { throw IPCError.conflict(reason: "Dispatch was cancelled or is no longer pending") }
    dispatch.status = .submitted
    dispatch.paneID = paneID
    execution.dispatches[stepID] = dispatch
    value.execution = execution
    value.run.record(type: "dispatch.bound", message: "\(stepID) assigned to pane \(paneID)", now: now())
    try commit(value)
  }

  func dispatchIssue(_ id: UUID, stepID: String, message: String) throws {
    try checkFence(id)
    var value = try record(id)
    guard value.run.status == .running, var execution = value.execution,
      var dispatch = execution.dispatches[stepID]
    else { return }
    dispatch.status = .attention
    dispatch.message = message
    execution.dispatches[stepID] = dispatch
    value.execution = execution
    value.run.record(type: "dispatch.unknown", message: message, now: now())
    try commit(value)
  }

  func decide(_ id: UUID, content: String) throws {
    try checkFence(id)
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      content.utf8.count <= 32_768
    else { throw IPCError.invalidParams(message: "Provide a decision and its reason", path: nil) }
    var value = try record(id)
    guard value.run.template == .advisor else {
      throw IPCError.conflict(reason: "This workflow does not have an advice decision")
    }
    let attempt = try value.run.claim(stepID: "disposition", paneID: "user", now: now())
    try value.run.deliver(
      attemptID: attempt.id, deliveryID: UUID(), paneID: "user", content: content, now: now())
    value.run.record(type: "decision.recorded", message: "User recorded how to use the advice", now: now())
    try commit(value)
  }

  /// Records a user-provided result without impersonating an agent's delivery provenance.
  func recordResult(id: UUID, stepID: String, content: String) throws {
    try checkFence(id)
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      content.utf8.count <= 32_768
    else { throw IPCError.invalidParams(message: "Provide a result of at most 32 KiB", path: nil) }
    var value = try record(id)
    guard value.run.status == .running else { throw AgentWorkflowError.terminalRun }
    guard value.run.template == .committee || (value.run.template == .advisor && stepID == "advice") else {
      throw IPCError.conflict(reason: "This step does not allow a manually recorded result")
    }
    let attempt: AgentWorkflowAttempt
    if let active = value.run.currentAttempt {
      guard active.stepID == stepID else { throw AgentWorkflowError.runBusy }
      attempt = active
    } else {
      let pane = value.execution?.dispatches[stepID]?.paneID ?? "user"
      attempt = try value.run.claim(stepID: stepID, paneID: pane, now: now())
    }
    try value.run.deliver(
      attemptID: attempt.id, deliveryID: UUID(), paneID: attempt.paneID, content: content, now: now())
    value.run.record(
      type: "human.result.recorded", message: "User supplied the result for \(stepID)", now: now())
    try commit(value)
  }

  private static func digest(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func record(_ id: UUID) throws -> Record {
    guard let value = records[id] else {
      throw IPCError.notFound(kind: "workflow", id: id.uuidString)
    }
    return value
  }

  private func checkFence(_ id: UUID) throws {
    guard !fenced.contains(id) else {
      throw IPCError.conflict(reason: "Workflow dispatch is stopped; inspect its persisted status")
    }
  }

  private func url(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }

  private func commit(_ value: Record) throws {
    guard try JSONEncoder().encode(value).count <= 262_144 else {
      throw IPCError.conflict(reason: "Workflow history exceeds 256 KiB; start a separate run")
    }
    do {
      try write(value, url(value.run.id))
      records[value.run.id] = value
      didChange?(value.run.id)
    } catch {
      fenced.insert(value.run.id)
      issues.append("\(value.run.id): storage unavailable: \(error)")
      throw error
    }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    do {
      for file in try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      where file.pathExtension == "json" {
        do {
          let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 262_144 else { throw IPCError.conflict(reason: "Oversized snapshot") }
          guard var value = try AtomicFileStore.read(Record.self, at: file),
            value.schemaVersion == 1,
            file.deletingPathExtension().lastPathComponent == value.run.id.uuidString
          else { throw IPCError.conflict(reason: "Invalid workflow snapshot") }
          if value.run.status == .running {
            value.run.interrupt(now: now())
            fenced.insert(value.run.id)
            try write(value, file)
          }
          records[value.run.id] = value
        } catch { issues.append("\(file.lastPathComponent): \(error)") }
      }
    } catch { issues.append("Workflow storage unavailable: \(error)") }
  }

  private struct HandoffReceipt: Decodable {
    let packetDigest: String
    let nextAction: String
  }
}
