import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Behavioural tests for `PaneContextMenuModel` (M7.T1). The SwiftUI view
/// itself is a thin wrapper that forwards to this model; testing the
/// model directly avoids spinning up a view tree while still pinning the
/// AC contracts on the production code path the menu drives.
///
/// AC coverage:
/// - AC-V11-M-001 / UT-V11-M-001: unmuted pane reports `isMuted == false`.
/// - AC-V11-M-002 / UT-V11-M-002: toggle on unmuted writes `present: true`;
///   subsequent read on a muted pane reports `isMuted == true`; toggle on
///   muted writes `present: false`.
@MainActor
struct PaneContextMenuTests {
  // MARK: - Fixtures

  /// Builds a single-project / single-worktree / single-tab / single-pane
  /// catalog. Returns the assembled catalog and the pane id so tests can
  /// flip the pane's `labels` without re-deriving identities.
  private func makeCatalog(paneLabels: Set<String> = []) -> (Catalog, PaneID) {
    let paneID = PaneID()
    let pane = Pane(id: paneID, workingDirectory: "/tmp", labels: paneLabels)
    let tab = Tab(id: TabID(), name: "fixture", panes: [pane])
    let worktree = Worktree(
      id: WorktreeID(),
      name: "fixture",
      path: "/tmp",
      tabs: [tab]
    )
    let project = Project(
      id: ProjectID(),
      name: "fixture",
      rootPath: "/tmp",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])
    return (catalog, paneID)
  }

  /// Captures every `setLabel(paneID, label, present)` call so tests can
  /// assert on argument tuples without inspecting closure state.
  @MainActor
  private final class SetLabelRecorder {
    private(set) var calls: [(PaneID, String, Bool)] = []
    func record(_ paneID: PaneID, _ label: String, _ present: Bool) {
      calls.append((paneID, label, present))
    }
  }

  // MARK: - isMuted

  /// AC-V11-M-001: a freshly-spawned pane carries no labels, so the menu
  /// reports `isMuted == false` and (in the view layer) renders the
  /// `bell.slash` glyph instead of the checkmark.
  @Test
  func isMutedFalseWhenLabelAbsent() {
    let (catalog, paneID) = makeCatalog(paneLabels: [])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      paneID: paneID,
      snapshot: { catalog },
      setLabel: { paneID, label, present in
        recorder.record(paneID, label, present)
      }
    )

    #expect(model.isMuted == false)
    #expect(recorder.calls.isEmpty)
  }

  /// AC-V11-M-002 (read side): once `InboxLabels.muted` is present on the
  /// pane, the menu reports `isMuted == true` and the next render shows
  /// the checkmark.
  @Test
  func isMutedTrueWhenLabelPresent() {
    let (catalog, paneID) = makeCatalog(paneLabels: [InboxLabels.muted])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      paneID: paneID,
      snapshot: { catalog },
      setLabel: { paneID, label, present in
        recorder.record(paneID, label, present)
      }
    )

    #expect(model.isMuted == true)
    #expect(recorder.calls.isEmpty)
  }

  // MARK: - toggleMute

  /// AC-V11-M-002 (write side, unmuted → muted): toggling an unmuted pane
  /// invokes `setLabel(paneID, InboxLabels.muted, true)` exactly once.
  @Test
  func toggleOnUnmutedRequestsLabelPresent() {
    let (catalog, paneID) = makeCatalog(paneLabels: [])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      paneID: paneID,
      snapshot: { catalog },
      setLabel: { paneID, label, present in
        recorder.record(paneID, label, present)
      }
    )

    model.toggleMute()

    #expect(recorder.calls.count == 1)
    guard let call = recorder.calls.first else { return }
    #expect(call.0 == paneID)
    #expect(call.1 == InboxLabels.muted)
    #expect(call.2 == true)
  }

  /// AC-V11-M-002 (write side, muted → unmuted): toggling a muted pane
  /// invokes `setLabel(paneID, InboxLabels.muted, false)` exactly once.
  @Test
  func toggleOnMutedRequestsLabelAbsent() {
    let (catalog, paneID) = makeCatalog(paneLabels: [InboxLabels.muted])
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      paneID: paneID,
      snapshot: { catalog },
      setLabel: { paneID, label, present in
        recorder.record(paneID, label, present)
      }
    )

    model.toggleMute()

    #expect(recorder.calls.count == 1)
    guard let call = recorder.calls.first else { return }
    #expect(call.0 == paneID)
    #expect(call.1 == InboxLabels.muted)
    #expect(call.2 == false)
  }

  /// Reading and writing are independent — an unknown pane id snapshots
  /// as `nil` and reports `isMuted == false` (no crash, no spurious
  /// label write). Guards the menu against the rare case where the pane
  /// is removed from the catalog between menu-open and click.
  @Test
  func isMutedFalseWhenPaneMissing() {
    let (catalog, _) = makeCatalog(paneLabels: [InboxLabels.muted])
    let foreignID = PaneID()
    let recorder = SetLabelRecorder()
    let model = PaneContextMenuModel(
      paneID: foreignID,
      snapshot: { catalog },
      setLabel: { paneID, label, present in
        recorder.record(paneID, label, present)
      }
    )

    #expect(model.isMuted == false)
  }
}
