import CodansCore
import Foundation

/// Token ↔ activation bookkeeping for every live run, plus the "which run
/// owns this pane" map that admission and `codans workflow status` ask.
/// The registry knows nothing about delivery validation: it answers
/// "who is waiting on this pane / this token" and the engine and the
/// machine decide what to do with the answer.
///
/// A pane belongs to at most one run at a time. Membership is joined at
/// admission for `current` / `pick` panes and when a `launch` role's pane
/// arrives, and released as a whole when the run ends.
@MainActor
final class WorkflowActivationRegistry {
  struct Entry: Equatable, Sendable {
    let runID: UUID
    let ordinal: Int
    let token: String
    /// `nil` while a `launch` role's pane is still being created.
    var paneID: PaneID?
  }

  /// Open activations by run, then ordinal.
  private var activations: [UUID: [Int: Entry]] = [:]
  /// Every pane that currently takes part in a run.
  private var runByPane: [PaneID: UUID] = [:]

  // MARK: - Activations

  /// Registers a token. Re-opening the same ordinal replaces the entry,
  /// which is how a `launch` role's pane is attached once known.
  func open(runID: UUID, ordinal: Int, paneID: PaneID?, token: String) {
    activations[runID, default: [:]][ordinal] = Entry(runID: runID, ordinal: ordinal, token: token, paneID: paneID)
    if let paneID { join(paneID: paneID, runID: runID) }
  }

  /// Attaches the pane a launched role landed in to its open activation.
  func bind(runID: UUID, ordinal: Int, paneID: PaneID) {
    join(paneID: paneID, runID: runID)
    guard var entry = activations[runID]?[ordinal] else { return }
    entry.paneID = paneID
    activations[runID]?[ordinal] = entry
  }

  func revoke(runID: UUID, ordinal: Int) {
    activations[runID]?[ordinal] = nil
    if activations[runID]?.isEmpty == true {
      activations[runID] = nil
    }
  }

  /// The activation waiting on `paneID`, if any. A pane has one open
  /// activation at a time once finished ones are revoked; should two
  /// overlap, the newest (highest ordinal) is the one a delivery means.
  func activation(forPane paneID: PaneID) -> Entry? {
    guard let runID = runByPane[paneID] else { return nil }
    return activations[runID]?.values.filter { $0.paneID == paneID }.max { $0.ordinal < $1.ordinal }
  }

  func activation(forToken token: String) -> Entry? {
    for entries in activations.values {
      if let entry = entries.values.first(where: { $0.token == token }) { return entry }
    }
    return nil
  }

  // MARK: - Membership

  /// Reserves `panes` for `runID`. Admission has already refused panes
  /// another run holds, so an existing membership here is the same run.
  func join(paneID: PaneID, runID: UUID) {
    runByPane[paneID] = runID
  }

  func join(panes: some Sequence<PaneID>, runID: UUID) {
    for paneID in panes { join(paneID: paneID, runID: runID) }
  }

  /// Drops one pane from its run without ending the run: a closed
  /// `launch` role's pane, for instance.
  func leave(paneID: PaneID, runID: UUID) {
    guard runByPane[paneID] == runID else { return }
    runByPane[paneID] = nil
  }

  /// The run `paneID` currently takes part in.
  func runID(forPane paneID: PaneID) -> UUID? {
    runByPane[paneID]
  }

  func panes(in runID: UUID) -> [PaneID] {
    runByPane.filter { $0.value == runID }.map(\.key)
  }

  /// Forgets every activation and membership of a finished run.
  func release(runID: UUID) {
    activations[runID] = nil
    runByPane = runByPane.filter { $0.value != runID }
  }
}
