import CodansCore
import Foundation

nonisolated enum PaneInputOrigin: Equatable, Sendable {
  case user
  case cli
  case commandQueue
  case recovery(operationID: UUID)

  var isRecovery: Bool {
    if case .recovery = self { return true }
    return false
  }
}

nonisolated enum SubmissionResult: Equatable, Sendable {
  case submitted
  case cancelledBeforeWrite
  case interruptedWithDraft
  case rejectedDraftPresent
  case targetChanged
}

/// Serializes submission stages without pretending that PTY writes are a
/// transaction. A cancelled paste remains visible until explicitly resolved.
@MainActor
final class PaneInputCoordinator {
  struct InputLease: Equatable, Sendable {
    let paneID: PaneID
    let id: UUID
    let revision: UInt64
  }

  enum ReservationResult {
    case reserved(InputLease)
    case rejected(SubmissionResult)
  }

  private struct Operation {
    let lease: InputLease
    var hasPasted = false
  }

  /// Native AppKit views cannot read the app's dependency values. AppState
  /// owns this coordinator; the responder path retains only a weak reference.
  static weak var shared: PaneInputCoordinator?

  var onExternalInput: (@MainActor (PaneID, UInt64) -> Void)?
  var onResidualDraftChanged: (@MainActor (PaneID, Bool) -> Void)?

  private let pauseBeforeSubmit: @MainActor () async throws -> Void
  private var revisions: [PaneID: UInt64] = [:]
  private var operations: [PaneID: Operation] = [:]
  private var residualDrafts: Set<PaneID> = []
  private var visibleResidualDrafts: Set<PaneID> = []

  init(
    pauseBeforeSubmit: @escaping @MainActor () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(150))
    }
  ) {
    self.pauseBeforeSubmit = pauseBeforeSubmit
  }

  func revision(for paneID: PaneID) -> UInt64 { revisions[paneID, default: 0] }

  func hasResidualDraft(in paneID: PaneID) -> Bool { residualDrafts.contains(paneID) }

  func canSubmitProgrammaticInput(in paneID: PaneID) -> Bool {
    !hasResidualDraft(in: paneID) && operations[paneID]?.hasPasted != true
  }

  /// Runs before native bytes or preedit are forwarded. Native editing always
  /// proceeds, even when an interrupted automatic paste may remain.
  func beforeNativeInput(in paneID: PaneID) {
    recordExternalInput(in: paneID)
  }

  @discardableResult
  func performExternalInput(
    in paneID: PaneID,
    origin: PaneInputOrigin,
    write: @MainActor () -> Void
  ) -> SubmissionResult {
    precondition(!origin.isRecovery, "Recovery writes require a lease")
    recordExternalInput(in: paneID)
    guard !hasResidualDraft(in: paneID) else { return .rejectedDraftPresent }
    write()
    return .submitted
  }

  /// External intent revokes older work synchronously, before an async task
  /// can yield and allow a previous delayed Return to slip through.
  func reserve(
    in paneID: PaneID,
    origin: PaneInputOrigin,
    validate: @MainActor () -> Bool = { true }
  ) -> ReservationResult {
    if !origin.isRecovery { recordExternalInput(in: paneID) }
    guard !hasResidualDraft(in: paneID) else { return .rejected(.rejectedDraftPresent) }
    guard operations[paneID] == nil, validate() else { return .rejected(.targetChanged) }
    let lease = InputLease(paneID: paneID, id: UUID(), revision: revision(for: paneID))
    operations[paneID] = Operation(lease: lease)
    return .reserved(lease)
  }

  func isValid(_ lease: InputLease) -> Bool {
    operations[lease.paneID]?.lease == lease && revision(for: lease.paneID) == lease.revision
  }

  func finish(_ lease: InputLease) {
    guard operations[lease.paneID]?.lease == lease else { return }
    operations.removeValue(forKey: lease.paneID)
  }

  func invalidate(in paneID: PaneID) {
    let operation = operations.removeValue(forKey: paneID)
    if operation?.hasPasted == true { setResidualDraft(true, in: paneID) }
  }

  /// An empty frame captured before the paste was rendered cannot prove that
  /// the draft is gone. Require visible content followed by an empty composer.
  func observePrompt(_ content: AgentPromptContent, in paneID: PaneID) {
    guard hasResidualDraft(in: paneID) else { return }
    switch content {
    case .occupied:
      visibleResidualDrafts.insert(paneID)
    case .empty:
      if visibleResidualDrafts.contains(paneID) { resolveResidualDraft(in: paneID) }
    case .unknown:
      break
    }
  }

  /// Explicit user resolution is allowed even when the terminal cannot prove
  /// a composer transition. Typing, focus, and a generic idle frame are not proof.
  func resolveResidualDraft(in paneID: PaneID) {
    setResidualDraft(false, in: paneID)
  }

  func removePane(_ paneID: PaneID) {
    operations.removeValue(forKey: paneID)
    revisions.removeValue(forKey: paneID)
    setResidualDraft(false, in: paneID)
  }

  func reconcileMembership(livePaneIDs: Set<PaneID>) {
    let knownPaneIDs = Set(revisions.keys)
      .union(operations.keys)
      .union(residualDrafts)
      .union(visibleResidualDrafts)
    for paneID in knownPaneIDs.subtracting(livePaneIDs) { removePane(paneID) }
  }

  func submitCommand(
    in paneID: PaneID,
    origin: PaneInputOrigin,
    validateBeforePaste: @MainActor () -> Bool = { true },
    validateBeforeSubmit: @MainActor () -> Bool = { true },
    willPaste: @MainActor () -> Bool = { true },
    waitBeforeSubmit: (@MainActor () async throws -> Void)? = nil,
    paste: @MainActor () -> Void,
    submit: @MainActor () -> Void
  ) async -> SubmissionResult {
    switch reserve(in: paneID, origin: origin, validate: validateBeforePaste) {
    case .reserved(let lease):
      return await submitCommand(
        lease,
        validateBeforePaste: validateBeforePaste,
        validateBeforeSubmit: validateBeforeSubmit,
        willPaste: willPaste,
        waitBeforeSubmit: waitBeforeSubmit,
        paste: paste,
        submit: submit
      )
    case .rejected(let result): return result
    }
  }

  func submitCommand(
    _ lease: InputLease,
    validateBeforePaste: @MainActor () -> Bool = { true },
    validateBeforeSubmit: @MainActor () -> Bool = { true },
    willPaste: @MainActor () -> Bool = { true },
    waitBeforeSubmit: (@MainActor () async throws -> Void)? = nil,
    paste: @MainActor () -> Void,
    submit: @MainActor () -> Void
  ) async -> SubmissionResult {
    guard !Task.isCancelled, isValid(lease) else {
      finish(lease)
      return .cancelledBeforeWrite
    }
    guard validateBeforePaste() else {
      finish(lease)
      return .targetChanged
    }
    // Validation and write share one MainActor turn. The process can still
    // change in the kernel: strong addressing requires a provider transport.
    guard willPaste(), isValid(lease), !Task.isCancelled else {
      finish(lease)
      return .cancelledBeforeWrite
    }
    operations[lease.paneID]?.hasPasted = true
    paste()
    do {
      if let waitBeforeSubmit {
        try await waitBeforeSubmit()
      } else {
        try await pauseBeforeSubmit()
      }
    } catch {
      return interruptAfterPaste(lease)
    }
    guard !Task.isCancelled, isValid(lease), validateBeforeSubmit() else {
      return interruptAfterPaste(lease)
    }
    submit()
    finish(lease)
    return .submitted
  }

  private func recordExternalInput(in paneID: PaneID) {
    let next = revision(for: paneID) &+ 1
    revisions[paneID] = next
    invalidate(in: paneID)
    onExternalInput?(paneID, next)
  }

  private func interruptAfterPaste(_ lease: InputLease) -> SubmissionResult {
    // A stale completion must not re-create a draft after teardown or after
    // the user has already resolved the marker created by invalidation.
    if operations[lease.paneID]?.lease == lease {
      invalidate(in: lease.paneID)
    }
    return .interruptedWithDraft
  }

  private func setResidualDraft(_ exists: Bool, in paneID: PaneID) {
    visibleResidualDrafts.remove(paneID)
    let changed: Bool
    if exists {
      changed = residualDrafts.insert(paneID).inserted
    } else {
      changed = residualDrafts.remove(paneID) != nil
    }
    if changed { onResidualDraftChanged?(paneID, exists) }
  }
}
